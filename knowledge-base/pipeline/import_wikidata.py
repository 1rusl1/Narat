"""Build-time import into a local SQLite staging DB. Never invoked by the iOS app.

Network requires an identifiable User-Agent with a real public contact. JSON snapshots
are retained for an offline rebuild. This imports taxonomy/names only, not verified care.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time
import unicodedata
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from rights import require_operations

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = "wikidata_structured"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def values(entity, property_id):
    return [s["mainsnak"]["datavalue"]["value"]
            for s in entity.get("claims", {}).get(property_id, [])
            if s.get("rank") != "deprecated" and s.get("mainsnak", {}).get("snaktype") == "value"]


def normalize_name(value):
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def normalize(seed, document):
    qid = seed["wikidata_id"]
    entity = document.get("entities", {}).get(qid)
    if not entity or entity.get("id") != qid or "missing" in entity:
        raise ValueError(f"Missing entity {qid}; redirects require manual reconciliation")
    names = values(entity, "P225")
    if len(names) != 1 or normalize_name(names[0]) != normalize_name(seed["scientific_name"]):
        raise ValueError(f"Scientific name mismatch/ambiguity for {qid}")
    ranks = [v.get("id") for v in values(entity, "P105") if isinstance(v, dict)]
    if ranks != ["Q7432"]:
        raise ValueError(f"Expected one species rank for {qid}, got {ranks}")
    if not isinstance(entity.get("lastrevid"), int):
        raise ValueError(f"Missing revision for {qid}")
    labels = {lang: entity.get("labels", {}).get(lang, {}).get("value") for lang in ("en", "pl")}
    aliases = {lang: [a["value"] for a in entity.get("aliases", {}).get(lang, [])] for lang in ("en", "pl")}
    return {
        "plant_id": seed["plant_id"], "scientific_name": names[0],
        "wikidata_id": qid, "source_revision": entity["lastrevid"],
        "labels": labels, "aliases": aliases,
        "parent_taxa": values(entity, "P171"),
        "image_candidates": values(entity, "P18"),
        "common_name_statements": [v for v in values(entity, "P1843")
                                   if isinstance(v, dict) and v.get("language") in ("en", "pl")],
        "taxon_author_abbreviations": values(entity, "P6507"),
        "descriptions": {lang: entity.get("descriptions", {}).get(lang, {}).get("value") for lang in ("en", "pl")},
        "external_identifiers": {
            property_id: [s["mainsnak"]["datavalue"]["value"] for s in statements
                          if s.get("rank") != "deprecated" and s.get("mainsnak", {}).get("snaktype") == "value"
                          and s.get("mainsnak", {}).get("datatype") == "external-id"]
            for property_id, statements in entity.get("claims", {}).items()
            if any(s.get("mainsnak", {}).get("datatype") == "external-id" for s in statements)
        },
        "care": None, "safety": {"cat": "unknown", "dog": "unknown"},
        "status": "draft", "care_profile_available": False,
        "evidence_url": f"https://www.wikidata.org/wiki/{qid}", "license": "CC0-1.0",
    }


def fetch(qid, target, user_agent):
    if not re.fullmatch(r"Q[1-9][0-9]*", qid):
        raise ValueError("Invalid Wikidata QID")
    url = f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
    request = Request(url, headers={"User-Agent": user_agent, "Accept": "application/json"})
    try:
        with urlopen(request, timeout=30) as response:
            raw = response.read(8_000_001)
            if len(raw) > 8_000_000:
                raise ValueError("Entity response exceeds 8 MB")
    except HTTPError as error:
        # In particular, never circumvent 403 or repeatedly hit a 429.
        raise ValueError(f"HTTP {error.code}; import stopped, respect Retry-After/source policy") from error
    json.loads(raw)  # Do not cache an HTML error page as entity data.
    target.write_bytes(raw)
    metadata = {"url": url, "retrieved_at": datetime.now(timezone.utc).isoformat(),
                "sha256": hashlib.sha256(raw).hexdigest(), "source_id": NAMESPACE}
    target.with_suffix(".meta.json").write_text(json.dumps(metadata, indent=2)+"\n")
    return raw


def build(seed, raw_dir, destination, registry, *, user_agent=None, offline=False):
    source = require_operations(registry, NAMESPACE,
                                ["store_raw", "commercial_use", "derive_facts"] + ([] if offline else ["automated_fetch"]))
    if not offline and (not user_agent or not re.search(r"https?://|mailto:|[\w.+-]+@[\w.-]+", user_agent)):
        raise ValueError("Supply --user-agent containing the actual public contact email or project URL")
    plants = seed["plants"]
    ids = [p["plant_id"] for p in plants]
    qids = [p["wikidata_id"] for p in plants]
    if not plants or len(ids) != len(set(ids)) or len(qids) != len(set(qids)):
        raise ValueError("Seed must have distinct nonempty plant IDs and QIDs")
    if any(not re.fullmatch(r"[a-z][a-z0-9_]*", p) for p in ids):
        raise ValueError("Invalid stable plant ID")
    raw_dir.mkdir(parents=True, exist_ok=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    normalized = []
    for plant in plants:
        qid = plant["wikidata_id"]
        path = raw_dir / f"{qid}.json"
        if not path.exists():
            if offline:
                raise ValueError(f"Missing cached snapshot: {path}")
            fetch(qid, path, user_agent)
            time.sleep(1)  # Serial, conservative access; reruns reuse snapshots.
        raw = path.read_bytes()
        metadata = load(path.with_suffix(".meta.json"))
        if metadata.get("sha256") != hashlib.sha256(raw).hexdigest():
            raise ValueError(f"Snapshot checksum mismatch: {qid}")
        if metadata.get("source_id") != NAMESPACE or not metadata.get("retrieved_at"):
            raise ValueError(f"Snapshot provenance missing: {qid}")
        item = normalize(plant, json.loads(raw))
        item.update({"source_sha256": metadata["sha256"], "retrieved_at": metadata["retrieved_at"]})
        normalized.append(item)
    with closing(sqlite3.connect(destination)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS catalogue_drafts (plant_id TEXT PRIMARY KEY, scientific_name TEXT NOT NULL, source_id TEXT NOT NULL, payload_json TEXT NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS import_runs (id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, manifest_json TEXT NOT NULL)")
        for item in normalized:
            db.execute("INSERT INTO catalogue_drafts VALUES (?,?,?,?) ON CONFLICT(plant_id) DO UPDATE SET scientific_name=excluded.scientific_name, source_id=excluded.source_id, payload_json=excluded.payload_json",
                       (item["plant_id"], item["scientific_name"], NAMESPACE, json.dumps(item, ensure_ascii=False)))
        manifest = {"source_review": source, "seed_version": seed["version"],
                    "records": [{"plant_id": p["plant_id"], "source_sha256": p["source_sha256"],
                                 "revision": p["source_revision"]} for p in normalized]}
        db.execute("INSERT INTO import_runs(created_at,manifest_json) VALUES (?,?)",
                   (datetime.now(timezone.utc).isoformat(), json.dumps(manifest, ensure_ascii=False)))
    return len(normalized)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=Path, default=ROOT / "knowledge-base/manifests/pilot-seed.json")
    parser.add_argument("--registry", type=Path, default=ROOT / "knowledge-base/manifests/source-registry.json")
    parser.add_argument("--raw-dir", type=Path, default=ROOT / "knowledge-base/raw/wikidata")
    parser.add_argument("--database", type=Path, default=ROOT / "knowledge-base/staging/catalogue.sqlite")
    parser.add_argument("--user-agent")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    try:
        count = build(load(args.seed), args.raw_dir, args.database, load(args.registry),
                      user_agent=args.user_agent, offline=args.offline)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Import failed: {error}\n")
    print(f"Staged {count} drafts in {args.database}; care and safety are not verified/published.")


if __name__ == "__main__":
    main()
