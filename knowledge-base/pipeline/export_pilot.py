"""Offline, checksum-verified export of the pilot SQLite catalogue and local media."""
import argparse
from contextlib import closing
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[2]


def export(database, media_manifest, destination, *, root=ROOT):
    assets = json.loads(media_manifest.read_text())["assets"]
    by_plant = {}
    for asset in assets:
        # A pilot review covers a particular file, not every future Commons response.
        if asset["license"] not in {"CC0-1.0", "CC-BY-SA-3.0"} or not asset.get("author"):
            raise ValueError("Missing/unsupported asset license or author")
        image = (root / asset["local_path"]).resolve()
        if not image.is_relative_to(root.resolve() / "knowledge-base/raw/media"):
            raise ValueError("Media outside the local raw asset directory")
        if not image.exists() or hashlib.sha256(image.read_bytes()).hexdigest() != asset["sha256"]:
            raise ValueError(f"Missing/corrupted media: {asset['plant_id']}")
        by_plant.setdefault(asset["plant_id"], []).append(asset)
    with closing(sqlite3.connect(database)) as db, db:
        rows = db.execute("SELECT payload_json FROM catalogue_drafts ORDER BY plant_id").fetchall()
        plants = [json.loads(row[0]) for row in rows]
        if not plants:
            raise ValueError("No staged catalogue records")
        if set(by_plant) - {p["plant_id"] for p in plants}:
            raise ValueError("Media refers to a missing plant")
        db.execute("CREATE TABLE IF NOT EXISTS catalogue_media (plant_id TEXT NOT NULL, sha256 TEXT NOT NULL, local_path TEXT NOT NULL, metadata_json TEXT NOT NULL, PRIMARY KEY(plant_id,sha256))")
        for plant in plants:
            plant["media"] = by_plant.get(plant["plant_id"], [])
            for asset in plant["media"]:
                db.execute("INSERT INTO catalogue_media VALUES (?,?,?,?) ON CONFLICT(plant_id,sha256) DO UPDATE SET local_path=excluded.local_path,metadata_json=excluded.metadata_json",
                           (plant["plant_id"], asset["sha256"], asset["local_path"], json.dumps(asset, ensure_ascii=False)))
    destination.mkdir(parents=True, exist_ok=True)
    document = {"version": "pilot-0.1", "status": "draft", "source": "Wikidata structured entities + per-file Commons media",
                "plants": plants}
    path = destination / "plants.json"
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2)+"\n")
    with (destination / "plants.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["plant_id", "scientific_name", "label_pl", "label_en", "wikidata_id", "revision", "photos", "care_status", "safety_status"])
        for plant in plants:
            writer.writerow([plant["plant_id"], plant["scientific_name"], plant["labels"]["pl"], plant["labels"]["en"], plant["wikidata_id"], plant["source_revision"], len(plant["media"]), "not_collected", "unknown"])
    manifest = {"version": "pilot-0.1", "created_at": datetime.now(timezone.utc).isoformat(), "status": "draft",
                "plant_count": len(plants), "media_count": sum(len(p["media"]) for p in plants),
                "json_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "limitations": ["Not a published 300-species KB release", "Care/safety/protocols not verified", "Photos are reference material, final UI suitability not approved", "Original media retains original licenses; preserve BY-SA conditions on future derivatives"]}
    (destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")
    return manifest


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database",type=Path,default=ROOT/"knowledge-base/staging/catalogue.sqlite")
    parser.add_argument("--media-manifest",type=Path,default=ROOT/"catalogue/manifests/pilot-media.json")
    parser.add_argument("--destination",type=Path,default=ROOT/"catalogue/pilot")
    args=parser.parse_args()
    manifest=export(args.database,args.media_manifest,args.destination)
    print(json.dumps(manifest,ensure_ascii=False,indent=2))
