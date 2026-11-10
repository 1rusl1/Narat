"""Preflight uses local XML project fixtures; no Xcode or model invocation."""

from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from orchestration.preflight import swift_membership, verify_inputs


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.project = self.root / "ios/Plants.xcodeproj/project.pbxproj"
        self.project.parent.mkdir(parents=True)
        self.name = "ios/PlantsTests/FlowTests.swift"
        (self.root / self.name).parent.mkdir()
        (self.root / self.name).write_text("// meaningful test source fixture\n")
        self.policy = {"xcode_project": "ios/Plants.xcodeproj/project.pbxproj",
                       "swift_targets": {"ios/PlantsTests/": "PlantsTests"}}
        self.data = {"rootObject": "project", "objects": {
            "project": {"mainGroup": "main", "targets": ["target"]},
            "main": {"children": ["tests"], "sourceTree": "<group>"},
            "tests": {"path": "PlantsTests", "children": ["file"], "sourceTree": "<group>"},
            "file": {"path": "FlowTests.swift", "sourceTree": "<group>"},
            "build": {"fileRef": "file"},
            "phase": {"isa": "PBXSourcesBuildPhase", "files": ["build"]},
            "target": {"name": "PlantsTests", "buildPhases": ["phase"]}}}
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def save(self):
        self.project.write_bytes(plistlib.dumps(self.data))

    def test_explicit_target_source_inclusion(self):
        swift_membership(self.root, self.policy, [self.name])

    def test_reference_without_sources_is_rejected(self):
        self.data["objects"]["phase"]["files"] = []
        self.save()
        with self.assertRaisesRegex(ValueError, "absent from PlantsTests Sources"):
            swift_membership(self.root, self.policy, [self.name])

    def test_wrong_target_is_rejected(self):
        self.data["objects"]["target"]["name"] = "Plants"
        self.save()
        with self.assertRaisesRegex(ValueError, "absent from PlantsTests Sources"):
            swift_membership(self.root, self.policy, [self.name])

    def test_same_basename_in_another_directory_is_not_membership(self):
        self.data["objects"]["tests"]["path"] = "OtherTests"
        self.save()
        with self.assertRaisesRegex(ValueError, "absent from PlantsTests Sources"):
            swift_membership(self.root, self.policy, [self.name])

    def test_new_file_is_deferred_then_requires_target_before_checks(self):
        name = "ios/PlantsTests/NewTests.swift"
        swift_membership(self.root, self.policy, [name])
        (self.root / name).write_text("// new test\n")
        with self.assertRaisesRegex(ValueError, "NewTests.swift absent"):
            swift_membership(self.root, self.policy, [name])

    def test_cyclic_group_fails_closed(self):
        self.data["objects"]["tests"]["children"].append("main")
        self.save()
        with self.assertRaisesRegex(ValueError, "cyclic Xcode group"):
            swift_membership(self.root, self.policy, [self.name])

    def test_empty_evidence_is_rejected(self):
        (self.root / "evidence.json").write_text("")
        task = {"files": [], "write_files": [], "evidence_files": ["evidence.json"]}
        with self.assertRaisesRegex(ValueError, "missing/empty evidence"):
            verify_inputs(self.root, {}, task, {}, "reviewer")


if __name__ == "__main__":
    unittest.main()
