"""Deterministic serial task queue, verification gates and recoverable acceptance."""

import json
from pathlib import Path
import time

from .context import (SUMMARY_START, SUMMARY_END, level, make_packet, selected_checks)
from .process import error_excerpt, run
from .repository import (apply_patch, changed_paths, contents, diff, fingerprint, git, manifest, require_clean)
from .storage import State, atomic_json, atomic_text, checkpoint, digest


class Engine:
    def __init__(self, root, directory, config, tasks, provider, lock_fd=None):
        self.root, self.directory = root.resolve(), directory.resolve()
        self.config, self.tasks, self.provider, self.lock_fd = config, tasks, provider, lock_fd
        self.state = State(directory / "state.json", config, tasks)
        self.started = time.monotonic()

    def save(self):
        self.state.save()
        # Projection of durable call records: restart cannot double-count a JSONL append.
        metrics = []
        for tid, record in self.state.data["tasks"].items():
            for call in record["calls"]:
                metrics.append(json.dumps({**call, "task_id": tid, "task_status": record["status"],
                                          "review_cycles": record["counts"].get("reviewer", 0)}, ensure_ascii=False))
        atomic_text(self.directory / "metrics.jsonl", "\n".join(metrics) + ("\n" if metrics else ""))

    def budget(self, role):
        key = {"developer": "max_developer_attempts", "reviewer": "max_review_cycles", "qa": "max_qa_cycles"}[role]
        return self.config["retry"][key]

    def stop(self, record, status, reason):
        record.update(status=status, reason=reason)
        self.save()

    def execute(self, resume=False):
        attempted_this_run = 0
        if not self.state.data.get("initialized"):
            require_clean(self.root)
            self.state.data["initialized"] = True
            self.state.data["initial_head"] = git(self.root, "rev-parse", "HEAD").decode().strip()
            self.save()
        for task in self.ordered_tasks():
            record = self.state.data["tasks"][task["id"]]
            if record["status"] in ("COMPLETED", "BLOCKED"):
                continue
            if attempted_this_run >= self.config["max_tasks_per_run"] or time.monotonic() - self.started >= self.config["max_run_seconds"]:
                break
            if any(self.state.data["tasks"][dep]["status"] != "COMPLETED" for dep in task["depends_on"]):
                continue
            attempted_this_run += 1
            if record["status"] in ("RUNNING", "WAITING"):
                if not resume:
                    self.stop(record, "WAITING", "Interrupted/waiting task: explicit --resume required")
                    continue
                if record.get("inflight"):
                    # Unknown outcome never becomes PASS and never silently repeats a patch.
                    record["inflight"] = None
                    record["sessions"] = {}
                    record["checks"] = {}
                    record["phase"] = "developer"
                    for call in record["calls"]:
                        if call["status"] == "STARTED":
                            call["status"] = "INTERRUPTED_UNKNOWN_OUTCOME"
                record["status"] = "PENDING"
            if record.get("phase") == "publish":
                self.publish(task, record)
                if record["status"] != "COMPLETED":
                    break
                continue
            if "baseline" not in record and (self.root / f"docs/validation/automation/tasks/{task['id']}.md").exists():
                self.stop(record, "BLOCKED", "Task ID already has a durable report; inspect before repeating")
                continue
            if "baseline" not in record:
                # Blocked work may remain in the shared tree. Only continue when safe.
                if changed_paths(self.root):
                    self.stop(record, "WAITING", "Uncommitted changes from another task; preserve and resolve first")
                    continue
                record.update(baseline=contents(self.root, task["write_files"]),
                              baseline_manifest=manifest(self.root),
                              base_head=git(self.root, "rev-parse", "HEAD").decode().strip(),
                              fingerprint=fingerprint(self.root))
                if not task["write_files"]:
                    record.update(phase="checks", summary={
                        "summary": "Read-only task: controller runs checks before independent Review/QA.",
                        "decisions": ["No Developer call needed: no files may be changed."], "findings": []})
                self.save()
            if git(self.root, "rev-parse", "HEAD").decode().strip() != record["base_head"]:
                self.stop(record, "BLOCKED", "HEAD changed outside this task")
                continue
            if fingerprint(self.root) != record["fingerprint"]:
                # A crash during apply is distinguishable from an unrelated edit by its durable intent.
                pending = record.get("pending_patch")
                if pending and self.recover_patch(task, record, pending):
                    pass
                else:
                    self.stop(record, "BLOCKED", "Files changed outside the checkpoint; inspect before a new run")
                    continue
            try:
                if record.get("pending_patch"):
                    apply_patch(self.root, record["pending_patch"], task["write_files"])
                    record.update(pending_patch=None, fingerprint=fingerprint(self.root), phase="checks", checks={})
                    record["changed_files"] = changed_paths(self.root)
                    self.save()
                self.run_task(task, record)
            except (KeyboardInterrupt, InterruptedError):
                self.stop(record, "WAITING", "Interrupted; child group stopped; resume explicitly")
                raise
            except (OSError, ValueError, RuntimeError) as error:
                self.stop(record, "BLOCKED", str(error))
            if record["status"] != "COMPLETED" and record["phase"] == "publish":
                break
        self.save()
        return {tid: rec["status"] for tid, rec in self.state.data["tasks"].items()}

    def ordered_tasks(self):
        ordered, seen = [], set()
        by_id = {task["id"]: task for task in self.tasks}
        def add(task):
            if task["id"] in seen:
                return
            for dependency in task["depends_on"]:
                add(by_id[dependency])
            ordered.append(task)
            seen.add(task["id"])
        for task in self.tasks:
            add(task)
        return ordered

    def recover_patch(self, task, record, pending):
        # Reverse-check a saved patch without changing files. No repeat application.
        try:
            git(self.root, "apply", "--reverse", "--check", input_bytes=pending.encode())
        except RuntimeError:
            return False
        current = manifest(self.root)
        allowed = set(task["write_files"])
        baseline = record["baseline_manifest"]
        if any(current.get(p) != baseline.get(p) for p in current.keys() | baseline.keys() if p not in allowed):
            return False
        record.update(pending_patch=None, fingerprint=fingerprint(self.root), phase="checks", checks={})
        record["changed_files"] = changed_paths(self.root)
        self.save()
        return True

    def run_task(self, task, record):
        record["status"] = "RUNNING"
        self.save()
        while record["status"] == "RUNNING":
            if time.monotonic() - self.started >= self.config["max_run_seconds"]:
                self.stop(record, "WAITING", "Run time budget exhausted")
                return
            phase = record["phase"]
            if phase == "checks":
                if self.checks(task, record, qa=False):
                    record["phase"] = "reviewer"
                elif record["status"] == "RUNNING":
                    record["phase"] = "developer"
                self.save()
                continue
            if phase == "qa_checks":
                if self.checks(task, record, qa=True):
                    record["phase"] = "qa"
                elif record["status"] == "RUNNING":
                    record["phase"] = "developer"
                self.save()
                continue
            if phase == "publish":
                self.publish(task, record)
                return
            reply = self.agent(task, record, phase)
            if reply is None:
                continue
            if reply["status"] == "PASS" and reply["findings"]:
                self.stop(record, "WAITING", "Conflicting agent reply: PASS with unresolved findings. Inspect answer; no repair triggered.")
                return
            if phase != "developer" and reply["patch"]:
                self.stop(record, "BLOCKED", "Read-only reviewer/QA returned a patch")
                return
            if reply["status"] == "BLOCKED":
                self.stop(record, "BLOCKED", "; ".join(reply["findings"]) or reply["summary"])
                return
            if phase == "developer":
                record["summary"] = {k: reply[k] for k in ("summary", "decisions", "findings")}
                if reply["status"] != "PASS":
                    self.failure(task, record, reply["findings"] or [reply["summary"]])
                    continue
                patch = reply["patch"]
                record["pending_patch"] = patch
                self.save()
                try:
                    apply_patch(self.root, patch, task["write_files"])
                except (ValueError, RuntimeError) as error:
                    record["pending_patch"] = None
                    self.failure(task, record, [str(error)])
                    continue
                record.update(pending_patch=None, fingerprint=fingerprint(self.root), phase="checks")
                record["changed_files"] = changed_paths(self.root)
                self.save()
            elif self.accepts(task, record, reply, phase):
                record[phase + "_result"] = reply
                record["phase"] = "qa_checks" if phase == "reviewer" else "publish"
                if self.config["sessions"].get("rotate_after_phase", True):
                    self.compact(task, record, phase, "major phase complete")
                self.save()
            else:
                if not task["write_files"]:
                    self.stop(record, "BLOCKED", "; ".join(reply["findings"]) or "Read-only acceptance failed; no writable files for repair")
                    return
                self.failure(task, record, reply["findings"] or ["Incomplete criteria/evidence; cannot accept"])
                record["phase"] = "developer"
                self.save()

    def failure(self, task, record, errors):
        self.state.failure(task["id"], record["fingerprint"], errors, self.config["retry"]["max_same_failure"])
        self.save()

    def accepts(self, task, record, reply, role):
        if reply["status"] != "PASS" or reply["findings"]:
            return False
        criteria = {criterion["id"]: criterion for criterion in reply["criteria"]}
        if len(criteria) != len(reply["criteria"]) or set(criteria) != {c["id"] for c in task["acceptance_criteria"]}:
            return False
        for criterion in task["acceptance_criteria"]:
            report = criteria[criterion["id"]]
            required = criterion["checks"]
            # Review precedes UI execution but still assesses all criteria. QA must see every check.
            if role == "reviewer":
                required = [name for name in required if self.config["checks"][name]["stage"] != "qa"]
            if report["status"] != "PASS" or not set(required) <= set(report["evidence"]):
                return False
            for name in required:
                check = record["checks"].get(name, {})
                if check.get("status") != "PASS" or check.get("fingerprint") != record["fingerprint"]:
                    return False
        return True

    def checks(self, task, record, qa):
        for name in selected_checks(self.config, task):
            specification = self.config["checks"][name]
            if (specification["stage"] == "qa") != qa:
                continue
            identity = digest({"fingerprint": record["fingerprint"], "spec": specification})
            old = record["checks"].get(name, {})
            if old.get("identity") == identity and old.get("status") == "PASS":
                continue
            seq = record.get("check_sequence", 0) + 1
            record["check_sequence"] = seq
            directory = self.directory / task["id"] / f"check-{seq}-{name}"
            check_run_id = "q-" + digest(str(directory))[:24]
            argv = [x.replace("{check_run_id}", check_run_id) for x in specification["argv"]]
            record["inflight"] = {"kind": "check", "name": name, "directory": str(directory)}
            self.save()
            result = run(argv, self.root, directory, specification["timeout"], lock_fd=self.lock_fd)
            record["inflight"] = None
            if fingerprint(self.root) != record["fingerprint"]:
                self.stop(record, "BLOCKED", "Check modified repository files; verification is stale")
                return False
            summary = {"name": name, "argv": argv, "status": result["status"], "exit_code": result["exit_code"],
                       "mode": specification["mode"], "identity": identity, "fingerprint": record["fingerprint"],
                       "elapsed_seconds": result["elapsed_seconds"], "stdout": result["stdout"], "stderr": result["stderr"]}
            if "{check_run_id}" in " ".join(specification["argv"]):
                evidence = self.root / "docs/validation/automation/runs" / check_run_id
                summary["evidence_directory"] = str(evidence)
                try:
                    actual = json.loads((evidence / "summary.json").read_text())
                    if actual.get("status") != "PASS":
                        summary["status"] = "FAIL"
                except (OSError, ValueError):
                    summary["status"] = "FAIL"
            if summary["status"] != "PASS":
                summary["error"] = result.get("error") or error_excerpt(
                    [Path(result["stdout"]), Path(result["stderr"])], self.config["context"]["error_chars"]) or "Check failed"
            record["checks"][name] = summary
            summary["owner"] = "qa" if qa else self.config["verification"]["owner"]
            self.save()
            if summary["status"] != "PASS":
                if not task["write_files"]:
                    self.stop(record, "BLOCKED", f"Read-only task cannot repair failed check {name}: {summary['error']}")
                    return False
                self.failure(task, record, [f"{name}: {summary['error']}"])
                return False
        return True

    def compact(self, task, record, role, reason):
        record["sessions"].pop(role, None)
        item = {"role": role, "reason": reason, "sequence": len(record["compactions"]) + 1,
                "method": "deterministic_checkpoint_new_session", "model_calls": 0}
        record["compactions"].append(item)
        atomic_json(self.directory / task["id"] / f"checkpoint-{item['sequence']}.json", checkpoint(task, record))
        self.save()

    def agent(self, task, record, role):
        if not self.state.reserve(task["id"], role, self.budget(role)):
            self.save()
            return None
        route = self.config["roles"][role][level(task)]
        model_index = record.setdefault("model_indices", {}).get(role, 0)
        model = route["models"][model_index]
        previous = record["sessions"].get(role)
        policy = self.config["sessions"]
        current = contents(self.root, task["write_files"])
        full_diff = diff(record["baseline"], current)
        base = record.get("review_baseline") if role == "reviewer" and level(task) != "high" else None
        review_diff = diff(base, current) if base is not None else full_diff
        task_dir = self.directory / task["id"]
        task_dir.mkdir(parents=True, exist_ok=True)
        atomic_text(task_dir / "task.patch", full_diff)
        atomic_text(task_dir / "review.patch", review_diff)
        deps = [{"task_id": tid, "decisions": self.state.data["tasks"][tid]["summary"].get("decisions", [])}
                for tid in task["depends_on"]]
        prompt = make_packet(self.root, self.config, task, record, role, review_diff,
                             task_dir / "review.patch", deps)
        prompt += f"\nFull task diff: {task_dir / 'task.patch'}\n"
        estimate = (len(prompt.encode()) + 3) // 4
        reason = None
        if previous:
            if previous["model"] != model or policy["policy"] == "fresh":
                reason = "model/policy changed"
            elif previous["turns"] >= policy["max_turns"]:
                reason = "turn threshold / irrelevant history"
            elif previous["estimated_tokens"] + estimate >= policy["max_estimated_tokens"]:
                reason = "estimated context threshold"
            elif previous.get("last_input_tokens", 0) >= policy["max_input_tokens"]:
                reason = "reported input threshold"
        if reason:
            self.compact(task, record, role, reason)
            previous = None
        seq = len(record["calls"]) + 1
        call_dir = task_dir / f"call-{seq}-{role}"
        call = {"id": f"{task['id']}:{seq}", "agent": role, "model": model, "provider": route["provider"],
                "status": "STARTED", "retry": record["counts"][role] - 1,
                "prompt_bytes": len(prompt.encode()), "estimated_prompt_tokens": estimate,
                "estimate_method": "UTF-8 bytes / 4; heuristic, not measured context",
                "input_tokens": None, "output_tokens": None, "cached_input_tokens": None,
                "usage_source": "unknown", "quota": None, "elapsed_seconds": None,
                "usage_scope": "CLI-reported counters; per-turn/session scope not guaranteed",
                "resumed_session": previous["id"] if previous else None}
        record["calls"].append(call)
        record["inflight"] = {"kind": "agent", "role": role, "directory": str(call_dir)}
        self.save()
        result = self.provider.invoke(self.root, call_dir, task, record["fingerprint"], prompt, model,
                                      route.get("reasoning_effort", "medium"),
                                      session=previous["id"] if previous else None,
                                      ephemeral=policy["policy"] == "fresh")
        record["inflight"] = None
        usage = result.get("usage", {})
        call.update(status=result["status"], elapsed_seconds=result.get("elapsed_seconds"),
                    quota=result.get("quota"), **{k: usage.get(k) for k in ("input_tokens", "output_tokens", "cached_input_tokens")})
        call["usage_source"] = "cli_reported" if any(usage.get(k) is not None for k in ("input_tokens", "output_tokens", "cached_input_tokens")) else "unknown"
        if fingerprint(self.root) != record["fingerprint"]:
            self.stop(record, "BLOCKED", "Read-only agent or external process modified files")
            return None
        if result["status"] != "PASS":
            category = result.get("category", "cli_error")
            call["error_category"] = category
            record["feedback"] = [result.get("error", "CLI error")]
            self.compact(task, record, role, category)
            if category in ("limit", "unavailable") and model_index + 1 < len(route["models"]):
                record["model_indices"][role] = model_index + 1
                self.save()
                return None
            if category == "session_lost" and previous:
                self.save()  # One fresh attempt, still charged to the same persisted budget.
                return None
            self.stop(record, "WAITING", f"CLI {category}: {result.get('error', '')}; explicit resume required")
            return None
        sid = result.get("session_id")
        if sid:
            record["sessions"][role] = {"id": sid, "model": model,
                                       "turns": (previous["turns"] if previous else 0) + 1,
                                       "estimated_tokens": (previous["estimated_tokens"] if previous else 0) + estimate,
                                       "last_input_tokens": usage.get("input_tokens") or 0}
        if role == "reviewer":
            record["review_baseline"] = current
        self.save()
        return result["reply"]

    def publish(self, task, record):
        """Idempotent finalization. Git failures never turn into COMPLETED."""
        try:
            if not record.get("publication"):
                if fingerprint(self.root) != record["fingerprint"]:
                    raise ValueError("Files changed after QA")
                if not record.get("qa_result") or not self.accepts(task, record, record["qa_result"], "qa"):
                    raise ValueError("Missing verified QA acceptance")
                allowed = set(task["write_files"])
                if not set(changed_paths(self.root)) <= allowed:
                    raise ValueError("Unrelated changes before publication")
                report_path = f"docs/validation/automation/tasks/{task['id']}.md"
                if (self.root / report_path).exists():
                    raise ValueError("Task report already exists; never repeat a completed task ID")
                report = self.report(task, record)
                handoff = self.root / "docs/handoff_status.md"
                text = handoff.read_text()
                if text.count(SUMMARY_START) != 1 or text.count(SUMMARY_END) != 1:
                    raise ValueError("Handoff summary markers missing")
                start, end = text.index(SUMMARY_START) + len(SUMMARY_START), text.index(SUMMARY_END)
                brief = (f"\n## Task Summary\n\n{task['id']}: проверки и Review/QA пройдены; публикация фиксируется в state.\n"
                         f"Отчёт: [{task['id']}](validation/automation/tasks/{task['id']}.md).\n"
                         "Продуктовые checkbox не менялись автоматически. Следующий шаг — следующая независимая задача manifest.\n")
                publication = {"files": sorted(allowed | {report_path, "docs/handoff_status.md"}),
                               "report_path": report_path, "report": report, "handoff": text[:start] + brief + text[end:],
                               "previous_handoff": text, "before_manifest": manifest(self.root),
                               "base_head": record["base_head"], "commit": None, "prepared": False}
                record["publication"] = publication
                self.save()
            publication = record["publication"]
            if not publication["prepared"]:
                # Each write has a durable intent. Repeating it after a crash is idempotent.
                owned = {publication["report_path"], "docs/handoff_status.md"}
                actual = manifest(self.root)
                before = publication["before_manifest"]
                if any(actual.get(p) != before.get(p) for p in actual.keys() | before.keys() if p not in owned):
                    raise ValueError("Files changed while preparing publication")
                handoff = self.root / "docs/handoff_status.md"
                report = self.root / publication["report_path"]
                if handoff.read_text() not in (publication["previous_handoff"], publication["handoff"]):
                    raise ValueError("Handoff changed outside publication")
                if report.exists() and report.read_text() != publication["report"]:
                    raise ValueError("Report changed outside publication")
                atomic_text(self.root / publication["report_path"], publication["report"])
                atomic_text(self.root / "docs/handoff_status.md", publication["handoff"])
                publication.update(prepared=True, tree=fingerprint(self.root))
                self.save()
            settings = self.config["publish"]
            if not settings["enabled"]:
                self.stop(record, "WAITING", "Verified; commit/push disabled. Publication remains pending.")
                return
            head = git(self.root, "rev-parse", "HEAD").decode().strip()
            if publication["commit"] is None:
                message = f"orchestrator: accept {task['id']} [{self.state.data['identity'][:12]}]"
                if head != publication["base_head"]:
                    parent = git(self.root, "rev-parse", "HEAD^").decode().strip()
                    subject = git(self.root, "log", "-1", "--format=%s").decode().strip()
                    if parent != publication["base_head"] or subject != message:
                        raise ValueError("Unexpected HEAD while recovering publication")
                    if fingerprint(self.root) != publication["tree"]:
                        raise ValueError("Committed files differ from verified publication")
                else:
                    if fingerprint(self.root) != publication["tree"]:
                        raise ValueError("Files changed during publication")
                    if git(self.root, "diff", "--cached", "--name-only").strip():
                        staged = set(git(self.root, "diff", "--cached", "--name-only").decode().splitlines())
                        if not staged <= set(publication["files"]):
                            raise ValueError("Unrelated staged files")
                    branch = git(self.root, "branch", "--show-current").decode().strip()
                    if branch != settings["branch"]:
                        raise ValueError("Publication branch differs from configured branch")
                    paths = [p for p in publication["files"] if (self.root / p).exists() or p in changed_paths(self.root)]
                    git(self.root, "add", "--", *paths)
                    git(self.root, "diff", "--cached", "--check")
                    git(self.root, "commit", "-m", message)
                    head = git(self.root, "rev-parse", "HEAD").decode().strip()
                publication["commit"] = head
                self.save()
            if head != publication["commit"] or git(self.root, "status", "--porcelain").strip():
                raise ValueError("Repository changed before push")
            git(self.root, "push", settings["remote"], f"HEAD:refs/heads/{settings['branch']}")
            record.update(status="COMPLETED", reason="Verified and published", phase="done")
            self.save()
        except (KeyboardInterrupt, InterruptedError):
            raise
        except (OSError, ValueError, RuntimeError) as error:
            self.stop(record, "WAITING", f"Publication failed: {error}")

    def report(self, task, record):
        checks = "\n".join(f"- {name}: {value['status']}, {value['mode']}, exit {value['exit_code']}; log `{value['stdout']}`"
                           for name, value in record["checks"].items())
        return (f"# {task['id']}\n\n{task['description']}\n\n{record['summary'].get('summary', '')}\n\n"
                f"Изменённые файлы: {', '.join(record.get('changed_files', [])) or 'нет'}.\n\n"
                f"Проверки:\n\n{checks}\n\nReview и QA подтвердили критерии manifest; "
                "это не автоматическое закрытие полной продуктовой задачи.\n\n"
                f"Решения: {json.dumps(record['summary'].get('decisions', []), ensure_ascii=False)}.\n\n"
                f"Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `{self.directory}`.\n"
                "Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.\n")
