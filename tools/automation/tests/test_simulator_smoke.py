"""Acceptance/evidence guard fixtures, without Simulator or network access."""

import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from doctor import RUNS
from mcp_client import MCPError
from simulator_smoke import element_by_id, elements_from_result, png_evidence
from setup_mobile_agent import download_verified


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        RUNS.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="ui-fixture-", dir=RUNS)
        self.directory = Path(self.scratch.name)

    def tearDown(self): self.scratch.cleanup()

    def test_accessibility_response_requires_expected_array(self):
        nodes = [{"identifier": "welcome.intent.care", "ref": "@e1"}]
        result = {"content": [{"type": "text", "text": "Found these elements on screen: " + json.dumps(nodes)}]}
        self.assertEqual(elements_from_result(result), nodes)
        for text in ("screen unavailable", "Found these elements on screen: {}"):
            with self.assertRaises(MCPError):
                elements_from_result({"content": [{"type": "text", "text": text}]})

    def test_locator_refuses_missing_duplicate_or_disabled_buttons(self):
        node = {"identifier": "welcome.intent.care", "ref": "@e1"}
        self.assertEqual(element_by_id([node], node["identifier"])["ref"], "@e1")
        for nodes in ([], [node, node], [{**node, "enabled": False}]):
            with self.assertRaises(MCPError): element_by_id(nodes, node["identifier"])

    def test_png_requires_complete_artifact(self):
        path = self.directory / "screenshot.png"
        data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ9kAAAAASUVORK5CYII=")
        path.write_bytes(data)
        self.assertEqual(png_evidence(path)["width"], 1)
        for bad in (b"not an image", data[:24]):
            path.write_bytes(bad)
            with self.assertRaises(MCPError): png_evidence(path)

    def test_cached_agent_is_verified_without_network(self):
        path = self.directory / "agent.zip"
        path.write_bytes(b"fixture")
        lock = {"filename": path.name, "sha256": hashlib.sha256(b"fixture").hexdigest(), "url": "https://fixture.invalid"}
        with patch("setup_mobile_agent.urllib.request.urlopen", side_effect=AssertionError("network")):
            self.assertEqual(download_verified(lock, self.directory), path)

    def test_corrupt_agent_download_cannot_replace_verified_path(self):
        lock = {"filename": "agent.zip", "sha256": "0" * 64, "url": "https://fixture.invalid"}
        with patch("setup_mobile_agent.urllib.request.urlopen", return_value=io.BytesIO(b"wrong")):
            with self.assertRaises(ValueError): download_verified(lock, self.directory)
        self.assertFalse((self.directory / "agent.zip").exists())


if __name__ == "__main__": unittest.main()
