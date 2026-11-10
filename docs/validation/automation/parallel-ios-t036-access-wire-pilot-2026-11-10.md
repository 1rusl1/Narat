# A — один T036 DTO/transport пилот, 10 ноября 2026

**COMPLETED и снова STOP.** Принят/отправлен только в `origin/codex/plants-ios`: `e04103f41518f524d82fca9e099edf14a6a931c6`. Один task, один run; Developer / Reviewer / QA = 1 / 1 / 1; repair/re-review/retry/timeout **0**. T036/T163 целиком не закрыты; выполнено 15 из 151 задач. CI/T006 и main promotion отложены.

Реализованы отдельный canonical `AnalysisAccessWireDTO` и `PlantsAPIClient.fetchAnalysisAccess(context:expectedGuest:)`: owner/kind, один общий monthly, nullable unknown, camelCase modes, точные timestamps, captured bound lease/token и fail-closed ответы/ошибки/A→B→A. Write только APIModels/PlantsAPIClient/CollectionWireTests; существующий код сохранён. Repository/UI/billing/installation mutations/live GET не включены.

## Время

| Событие | UTC |
| --- | --- |
| Первое инструментальное наблюдение получения задания | 2026-11-10T20:00:17Z |
| Перенос/config/gates-preflight готовы, prep завершена | 2026-11-10T20:07:38.566Z |
| Старт реального run | 2026-11-10T20:07:38.582Z |
| Конец run и веточной публикации | 2026-11-10T20:23:14.158Z |

Подготовка **441.566с** (~7 мин 22 с), включая два merge, ручное разрешение конфликтов handoff/T006, config, manifest, preflight и commit/push. Первое время с точностью инструмента до секунды. Runtime по monotonic **935.649с** (~15 мин 36 с), отдельный от prep. Модельные вызовы **813.634с**, checks **114.201с**, остальное **7.814с** (controller/I/O/Gitpublication; не модельное время). Позднее документирование/отправка этого отчёта не включены в runtime.

## Все модельные вызовы

| № | Role | Model / reasoning | Elapsed,s | Status | Retry | Error category | Prompt | Session |
| --- | --- | --- | ---: | --- | ---: | --- | --- | --- |
| 1 | developer | gpt-6.1-sol / medium | 630.584 | PASS | 0 | — | full | `01a1c712-c95a-7a53-a868-ebbea9e703cb` |
| 2 | reviewer | gpt-6-astra / high | 81.336 | PASS | 0 | — | full | `01a1c71d-cb80-7d53-9419-cbce5d56c5d8` |
| 3 | qa | gpt-6-astra / high | 101.714 | PASS | 0 | — | full | `01a1c71f-6d95-74d0-93e7-d8e521c53342` |

Developer effort по complexity=medium, отдельные Astra high Review/QA по risk=high. Все prompts fresh/full; reuse/repair/timeoutescalation в этом пилоте не потребовались. Сохранены 2 deterministic checkpoints по завершению фаз Review/QA, без дополнительных модельных вызовов; ротации по ambiguous input counters не было. Ноль повторов — наблюдение, не доказательство эффекта reuse. Raw CLI token counters неоднозначны: не суммируются и не переводятся в проценты квоты.

## Фактически выполненные проверки

| Check | Mode | Elapsed,s | Status / exit |
| --- | --- | ---: | --- |
| diff-check | local | 0.024 | PASS / 0 |
| ios-tests | local | 89.339 | PASS / 0 |
| simulator-smoke | local | 24.838 | PASS / 0 |

**191/191 тест**: 184 прежних + 7 новых, 188 XCTest source methods реально выполнены + 3 SwiftTesting; 0 failed/skipped/expectedFailures; build/welcome и Simulator. Review/QA сверили все 7 canonical fixtures и проверили captured auth / nullable status / timestamps / errors / cancel / ABA; QA просмотрела Simulator evidence. Ни одного повторного check. Только local/mock fixtures, не live Auth/Supabase/GET/provider/StoreKit. SQL/Deno/automation/18ENPLUI/Release/CI/fullintegration в этом runtime не запускались.

## Перенос и воспроизводимость

Engine source `25a5830ca5447a3b25e7abd37350759e3e0841f3` (+cf5a6b1), обычный merge A `20f49b6`. Orchestration package SHA256 `7f5f41e41e537612319aa9b702a3d3cfc4a6bde1eca032f3ee36591f4ab1ff2f` неизменен в run. Точный prerequisite B `6d689b7` перенесён merge A `4ab2b60`, без позднего HTTP candidate; B SQL 511/6×20 — прежнее evidence B, не новый A integration gate. Main `5d15123e1271f93e7575433d4a09f7f04612e64a` не изменён. CI scripts/manifests/workflow совпадают с исходным A `2aafbdd`.

Config `docs/validation/automation/runs/parallel-ios-t036-pilot.config.json`,SHA256 `6bd5008b1fa38b96938a9f82a6eb14d92e309006743fe2db7d27b1bcee88a523`. Только context max_discovered_files=6/read_chars=16000 и preflight перенесены; lane checks/providers/budgets/timeout900/sessions/publishA сохранены. Config ignored и byte-identical после run. Прямой preflight подтвердил 7 inputs, непустой fixture и реальные fileRef/Sources для 5 Swift-файлов Plants/PlantsTests; новые Swift-файлы не добавлялись. Validate(1), context и script paths PASS до моделей.

Manifest `tools/automation/tasks.parallel-ios-t036-access-wire-pilot.json`; run `parallel-ios-t036-access-wire-pilot-20261110-01`; quality_contract `85e2f9441290fdbaccf431938759c1831fef76be94135d8db6d6e0270b8311f2`; final task fingerprint `5a8664018513adf2e0e4c45f63096ddc3a34e1d59c6871e7ab53158bae6ced91`. Source/contracts/tools до `a785d63abb8e539291a4fc4a73e8bdcc09d878bb46eeb895963345a17ebdbced`, после `aeb2c2ca849cf4bddc7b8993e4eec43b3a42b488dc80e1eeea157189cee66437`, 1530 files. Изменились только 3 разрешённых Swift-файла; infra/config/CI остались неизменны.

Локальные ignored artifacts: state `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/state.json`, metrics `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/orchestrator-parallel-ios-t036-access-wire-pilot-20261110-01/metrics.jsonl`, unit `/Users/ruslansabirov/.codex/worktrees/d09a/Plants/docs/validation/automation/runs/q-750c7fa9c2a28d4e30e1430f`, task report [отчёт задачи](tasks/parallel-ios-t036-access-wire-pilot.md). Полный текущий замер/все calls/check paths — [JSON](parallel-ios-t036-access-wire-pilot-2026-11-10.json).

## Ближайшая прежняя работа — canonical sync transport A1

| Run | Status | D/R/Q | Model elapsed,s (известная часть) | Unknown elapsed calls | Checks,s |
| --- | --- | --- | ---: | ---: | ---: |
| parallel-ios-sync-transport-20261109-01 | WAITING | 3/0/0 | 979.044 | 1 | 0.000 |
| parallel-ios-sync-transport-20261109-02 | BLOCKED | 0/0/0 | 0.000 | 0 | 41.029 |
| parallel-ios-sync-transport-20261109-03 | COMPLETED | 1/1/1 | 177.103 | 0 | 71.535 |

Принятый третий A1 run `7cb5893` был compile-repair уже подготовленного кандидата, risk=medium/complexity=medium, Sol Review/QA и 43 unit. Его Developer 48.141 с — не новая реализация; перед ним были WAITING на трёх Developer-попытках (две по 503.746/475.298 с, третья прервана с неизвестным elapsed) и BLOCKED compile check. Новая задача — свежий monthly DTO / GET / bound ownership,184→191 unit и risk=high/Astra split. Все quality_contract отличаются (значения и старые call records в JSON); старые prep/runtime wall не измерены, суммыcalls/checks не равны walltime. Unknown elapsed не считается нулём.

Наблюдение пилота: код принят за один runtime, без repair / re-review / retries / timeouts; основной расход runtime остаётся первый Developer 630.584 с. Scope/risk/tests/готовность кандидата и контракт различаются, sample=1 — **причинное ускорение не доказано**. Экономия процента подписочной квоты не вычислялась.

## Точка остановки

CLI завершён exit=0, state COMPLETED/done/inflight=null; PID 75332 отсутствует. Оставшийся A mobilecli daemon PID 80483 остановлен штатным SIGINT, повторный ps обоих PID подтвердил отсутствие. Конфигурация не менялась после старта. Никакого второго run, внешнего repair, CI или main promotion. Следующий шаг — отчёт владельцу и ожидание его отдельного решения.
