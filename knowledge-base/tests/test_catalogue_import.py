from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from datetime import date, timedelta
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
from import_wikidata import build, normalize
from rights import RightsError, require_operations


def registry():
    return {"sources": [{"id": "wikidata_structured", "status": "allowed",
            "checked_at": date.today().isoformat(),
            "review_after": (date.today()+timedelta(days=30)).isoformat(),
            "terms_urls": ["https://www.wikidata.org/wiki/Wikidata:Licensing"],
            "allowed_operations": {"store_raw": True, "automated_fetch": True,
                                   "commercial_use": True, "derive_facts": True}}]}


def entity(qid="Q161077", scientific_name="Monstera deliciosa", rank="Q7432"):
    def claim(v):
        return [{"mainsnak": {"snaktype": "value", "datavalue": {"value": v}}}]
    return {"entities": {qid: {"id": qid, "lastrevid": 123,
            "labels": {"pl": {"value": "Monstera dziurawa"}},
            "claims": {"P225": claim(scientific_name), "P105": claim({"id": rank})}}}}


SEED = {"version": "fixture", "plants": [
    {"plant_id": "monstera_deliciosa", "scientific_name": "Monstera deliciosa", "wikidata_id": "Q161077"}]}


class CatalogueImportTests(unittest.TestCase):
    def cache(self, directory, payload=None):
        raw = json.dumps(payload or entity()).encode()
        path = directory / "Q161077.json"
        path.write_bytes(raw)
        path.with_suffix(".meta.json").write_text(json.dumps({
            "source_id": "wikidata_structured", "retrieved_at": "2026-11-02T00:00:00+00:00",
            "sha256": hashlib.sha256(raw).hexdigest()}))
        return path

    def test_blocked_candidate_unknown_and_unreviewed_sources_cannot_fetch(self):
        for status in ("candidate", "blocked", "expired", "allowed"):
            r = registry();r["sources"][0]["status"] = status
            if status == "allowed":r["sources"][0]["review_after"] = date.today().isoformat()
            with self.subTest(status=status), self.assertRaises(RightsError):
                require_operations(r, "wikidata_structured", ["automated_fetch"])
        with self.assertRaises(RightsError):
            require_operations(registry(), "unknown", ["automated_fetch"])
        with self.assertRaises(RightsError):
            require_operations(registry(), "wikidata_structured", ["download_media"])

    def test_reference_only_sources_do_not_unlock_bulk_import(self):
        root=Path(__file__).resolve().parents[2]
        actual=json.loads((root/"knowledge-base/manifests/source-registry.json").read_text())
        for source_id in ("perenual", "aspca_toxicity"):
            with self.subTest(source=source_id):
                require_operations(actual,source_id,["manual_reference"],today=date(2026,11,2))
                for operation in ("automated_fetch", "store_raw", "commercial_use", "llm_processing"):
                    with self.assertRaises(RightsError):
                        require_operations(actual,source_id,[operation],today=date(2026,11,2))

    def test_care_safety_and_missing_translation_are_not_invented(self):
        record = normalize(SEED["plants"][0], entity())
        self.assertIsNone(record["care"])
        self.assertEqual(record["safety"], {"cat": "unknown", "dog": "unknown"})
        self.assertIsNone(record["labels"]["en"])
        self.assertEqual(record["status"], "draft")
        self.assertFalse(record["care_profile_available"])

    def test_mismatched_name_genus_and_missing_revision_are_quarantined(self):
        for data in [entity(scientific_name="Monstera adansonii"), entity(rank="Q34740")]:
            with self.assertRaises(ValueError):normalize(SEED["plants"][0], data)
        data = entity();del data["entities"]["Q161077"]["lastrevid"]
        with self.assertRaises(ValueError):normalize(SEED["plants"][0], data)

    def test_offline_import_rebuilds_persistent_db_without_network_and_without_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp);self.cache(raw);database = raw / "catalogue.sqlite"
            with patch("import_wikidata.urlopen", side_effect=AssertionError("Network forbidden")):
                self.assertEqual(build(SEED,raw,database,registry(),offline=True),1)
                self.assertEqual(build(SEED,raw,database,registry(),offline=True),1)
            with closing(sqlite3.connect(database)) as db, db:
                self.assertEqual(db.execute("SELECT count(*) FROM catalogue_drafts").fetchone()[0],1)
                self.assertEqual(db.execute("SELECT count(*) FROM import_runs").fetchone()[0],2)
                stored=json.loads(db.execute("SELECT payload_json FROM catalogue_drafts").fetchone()[0])
                self.assertEqual(stored["source_revision"],123)
                self.assertTrue(stored["source_sha256"])

    def test_corrupt_snapshot_cannot_update_existing_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = Path(tmp);path=self.cache(raw);database=raw/"catalogue.sqlite"
            build(SEED,raw,database,registry(),offline=True)
            path.write_bytes(b'{"tampered":true}')
            with self.assertRaises(ValueError):build(SEED,raw,database,registry(),offline=True)
            with closing(sqlite3.connect(database)) as db, db:
                self.assertEqual(db.execute("SELECT count(*) FROM import_runs").fetchone()[0],1)

    def test_missing_snapshot_and_duplicate_seed_do_not_publish_partial_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw=Path(tmp);database=raw/"catalogue.sqlite"
            with self.assertRaises(ValueError):build(SEED,raw,database,registry(),offline=True)
            self.assertFalse(database.exists())
            duplicate={"version":"fixture", "plants":SEED["plants"]*2}
            with self.assertRaises(ValueError):build(duplicate,raw,database,registry(),offline=True)

    def test_network_mode_requires_real_contact_argument_before_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch("import_wikidata.urlopen",side_effect=AssertionError("Should never fetch")):
                with self.assertRaises(ValueError):build(SEED,Path(tmp),Path(tmp)/"data.sqlite",registry())


if __name__ == "__main__":unittest.main()
