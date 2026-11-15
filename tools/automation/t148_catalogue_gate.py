#!/usr/bin/env python3
"""Verification gate for T148 (pipeline audit and 606-species catalogue release acceptance)."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import os
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "catalogue/releases/skeleton-300-v1"
sys.path.insert(0, str(ROOT / "knowledge-base/pipeline"))
from catalogue_image import parse_image_dimensions_and_mime

FORBIDDEN_COMMON_NAMES_EN = {
    "flowering perennial herbaceous bulbous plant",
    "eastern regions of Brazil",
    "rock crevices",
    "river banks",
    "coastal cliffs",
    "basalt banks along trails",
    "by its Māori name of tī",
    "cousin to African violets",
    "simply ladder brake",
    "simply jasmine",
    "'painted echeveria'",
    "orchid",
    "cactus",
}

CROSS_SPECIES_PL_LABELS = {
    ("dracaena_braunii", "dracena sandera"),
    ("begonia_corallina", "begonia koralowa"),
    ("hoya_lanceolata", "hoja piękna"),
}


def verify_pipeline(root: Path = ROOT) -> dict:
    checks = []

    def record(name: str, passed: bool, detail: str):
        checks.append({"name": name, "status": "PASS" if passed else "FAIL", "detail": detail})
        if not passed:
            raise AssertionError(f"{name}: {detail}")

    import import_catalogue_300 as imp

    # Historical Polish text is usable only when the source is about the card's taxon.
    for qid, title in (
        ("Q2893846", "Lista gatunków z rodzaju begonia"),
        ("Q814368", "Begonia koralowa"),
        ("Q162311", "Hoja piękna"),
    ):
        page = {"title": title, "pageprops": {"wikibase_item": qid}}
        record(f"reject_cross_taxon_source_{qid}",
               imp.eligible_polish_article({"id": qid}, page) is None, title)
    valid_page = {"title": "Monstera dziurawa", "pageprops": {"wikibase_item": "Q161077"}}
    record("retain_matching_polish_article",
           imp.eligible_polish_article({"id": "Q161077"}, valid_page) == valid_page,
           "preserves the source article for a matching species")

    # 1. Verify common_names filtering
    item_braunii = {
        "id": "Q31318",
        "claims": {"P225": [{"mainsnak": {"snaktype": "value", "datavalue": {"value": "Dracaena braunii"}}}]},
        "labels": {"en": {"value": "Dracaena braunii"}, "pl": {"value": "Dracena Sandera"}},
    }
    cn_braunii = imp.common_names(item_braunii, "Dracaena braunii")
    record("common_names_rejects_dracaena_braunii_collision", cn_braunii["pl"] == [], f"got={cn_braunii['pl']}")

    item_genus_label = {
        "id": "Q1936434",
        "claims": {
            "P225": [{"mainsnak": {"snaktype": "value", "datavalue": {"value": "Pilea peperomioides"}}}],
            "P1843": [
                {"mainsnak": {"snaktype": "value", "datavalue": {"value": {"language": "en", "text": "cactus"}}}},
                {"mainsnak": {"snaktype": "value", "datavalue": {"value": {"language": "en", "text": "Fatsia"}}}},
            ],
        },
        "labels": {"en": {"value": "Pilea"}, "pl": {"value": "Pilea"}},
    }
    cn_genus = imp.common_names(item_genus_label, "Pilea peperomioides", {"fatsia", "pilea"})
    record(
        "common_names_rejects_genus_and_generic",
        cn_genus["en"] == [] and cn_genus["pl"] == [],
        f"got={cn_genus}",
    )

    # 2. Verify intro_common_names fixes
    genera = {"hippeastrum", "adiantum", "cordyline", "columnea", "pteris", "jasminum", "echeveria", "phalaenopsis"}
    p_hipp = {
        "title": "Hippeastrum striatum",
        "revisions": [{"revid": 1}],
        "extract": "Hippeastrum striatum, the striped Barbados lily, a flowering perennial herbaceous bulbous plant, in the family Amaryllidaceae, native to the southern and eastern regions of Brazil.",
    }
    names_hipp = [n["name"] for n in imp.intro_common_names(p_hipp, [], genera)]
    record("intro_hippeastrum_striatum", names_hipp == ["striped Barbados lily"], f"got={names_hipp}")

    p_adiantum = {
        "title": "Adiantum raddianum",
        "revisions": [{"revid": 2}],
        "extract": "Adiantum raddianum, the Delta maidenhair fern, is one of the most popular ferns to grow indoors. It grows on rock crevices, river banks, coastal cliffs and basalt banks along trails.",
    }
    names_adiantum = [n["name"] for n in imp.intro_common_names(p_adiantum, [], genera)]
    record("intro_adiantum_raddianum", names_adiantum == ["Delta maidenhair fern"], f"got={names_adiantum}")

    p_cord = {
        "title": "Cordyline australis",
        "revisions": [{"revid": 3}],
        "extract": "Cordyline australis, commonly known as the cabbage tree, or by its Māori name of tī or tī kōuka, is a monocot tree.",
    }
    names_cord = [n["name"] for n in imp.intro_common_names(p_cord, [], genera)]
    record(
        "intro_cordyline_australis",
        "by its Māori name of tī" not in names_cord and "cabbage tree" in names_cord,
        f"got={names_cord}",
    )

    p_ech = {
        "title": "Echeveria nodulosa",
        "revisions": [{"revid": 4}],
        "extract": "Echeveria nodulosa, the 'painted echeveria', is a species of flowering plant.",
    }
    names_ech = [n["name"] for n in imp.intro_common_names(p_ech, [], genera)]
    record("intro_echeveria_nodulosa_quotes", names_ech == ["painted echeveria"], f"got={names_ech}")

    p_jas = {
        "title": "Jasminum officinale",
        "revisions": [{"revid": 5}],
        "extract": "Jasminum officinale, known as the common jasmine or simply jasmine, is a species of flowering plant.",
    }
    names_jas = [n["name"] for n in imp.intro_common_names(p_jas, [], genera)]
    record("intro_jasminum_simply_stripped", names_jas == ["common jasmine", "jasmine"], f"got={names_jas}")

    p_col = {
        "title": "Columnea gloriosa",
        "revisions": [{"revid": 7}],
        "extract": "Columnea gloriosa is commonly known as the goldfish plant (a name it shares with other species). Also known as a cousin to African violets.",
    }
    names_col = [n["name"] for n in imp.intro_common_names(p_col, [], genera)]
    record("intro_columnea_rejects_relationship", names_col == ["goldfish plant"], f"got={names_col}")

    p_phal = {
        "title": "Phalaenopsis violacea",
        "revisions": [{"revid": 6}],
        "extract": "Phalaenopsis violacea is a species of orchid native to Malaya.",
    }
    names_phal = [n["name"] for n in imp.intro_common_names(p_phal, ["Orchid"], genera)]
    record("intro_rejects_generic_orchid_alias", names_phal == [], f"got={names_phal}")

    media = root / "catalogue/releases/skeleton-300-v1/media/48854fc7b2b6d711a508c396.jpg"
    raw = media.read_bytes()
    checksum = hashlib.sha256(raw).hexdigest()
    record("media_fixture_matches_pinned_bytes",
           checksum == "bd004e951b155a37235a6dd80c019768db160321b40015ec6b490a1b009bbb3a",
           media.name)

    class CachedImage:
        def request(self, url, path, *, binary):
            assert binary and url == "https://upload.wikimedia.org/example.jpg"
            return raw, {"retrieved_at": "2026-11-04T00:00:00+00:00"}

    downloaded = imp.download_image(CachedImage(), {
        "download_url": "https://upload.wikimedia.org/example.jpg",
        "width": 10, "height": 11, "mime": "image/png",
    })
    actual = downloaded["width"], downloaded["height"], downloaded["mime"]
    record("download_persists_byte_dimensions_and_mime",
           actual == (960, 1091, "image/jpeg") and downloaded["sha256"] == checksum,
           f"decoded={actual}")

    # 3. Verify validate_catalogue_skeleton.py has --check flag in help
    help_res = subprocess.run(
        [sys.executable, str(root / "knowledge-base/pipeline/validate_catalogue_skeleton.py"), "--help"],
        capture_output=True,
        text=True,
        check=True,
    )
    record("validator_supports_check_flag", "--check" in help_res.stdout, help_res.stdout.strip())

    return {"mode": "pipeline", "checks": checks}


def verify_release(root: Path = ROOT) -> dict:
    checks = []

    def record(name: str, passed: bool, detail: str):
        if not passed:
            raise AssertionError(f"{name}: {detail}")
        checks.append({"name": name, "status": "PASS", "detail": detail})

    out_dir = root / "catalogue/releases/skeleton-300-v1"
    plants_path = out_dir / "plants.json"
    plants = json.loads(plants_path.read_text(encoding="utf-8"))["plants"]
    coverage = json.loads((out_dir / "coverage.json").read_text(encoding="utf-8"))
    manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
    review = json.loads((out_dir / "editorial-review.json").read_text(encoding="utf-8"))
    images = json.loads((out_dir / "image-validation.json").read_text(encoding="utf-8"))
    overrides_path = root / "catalogue/manifests/skeleton-300-editorial-media.json"
    overrides = json.loads(overrides_path.read_text(encoding="utf-8"))["plants"]
    checksum = hashlib.sha256(plants_path.read_bytes()).hexdigest()
    ids = [(p["plant_id"], p["wikidata_id"]) for p in plants]
    ids_sha = hashlib.sha256(json.dumps(ids, separators=(",", ":")).encode()).hexdigest()
    record("pinned_release_and_reviewed_taxon_identities",
           checksum == manifest["plants_sha256"] == review["plants_sha256"]
           and ids_sha == review["original_taxon_identity_sha256"]
           and len(set(ids)) == len(plants) == coverage["records"] == manifest["records"] == review["records_reviewed"],
           f"{len(plants)} preserved identities and a digest-bound review")

    en_count = sum(bool(p["descriptions"]["en"]) for p in plants)
    pl_count = sum(bool(p["descriptions"]["pl"]) for p in plants)
    missing_pl = {p["plant_id"] for p in plants if p["descriptions"]["pl"] is None}
    record("english_content_and_legacy_polish_fallback",
           en_count == coverage["description_en"] == len(plants)
           and pl_count == coverage["description_pl"]
           and missing_pl == set(review["polish_description_gaps"])
           and all(p["descriptions"]["en"]["language"] == "en" for p in plants),
           f"{en_count} EN descriptions, {pl_count} retained PL descriptions, {len(missing_pl)} honest fallbacks")

    genera = {p["scientific_name"].split()[0].casefold() for p in plants}
    forbidden_en = {x.casefold() for x in FORBIDDEN_COMMON_NAMES_EN} | genera
    names_en = [(p["plant_id"], n["name"].casefold()) for p in plants for n in p["common_names"]["en"]]
    names_pl = [(p["plant_id"], n["name"].casefold()) for p in plants for n in p["common_names"]["pl"]]
    bad_en = [row for row in names_en if row[1] in forbidden_en]
    bad_pl = [row for row in names_pl if row[1] in genera or row in CROSS_SPECIES_PL_LABELS]
    record("no_known_misleading_common_names", not bad_en and not bad_pl,
           f"English={bad_en}, Polish={bad_pl}")

    by_id = {p["plant_id"]: p for p in plants}
    replacement_sha = hashlib.sha256(overrides_path.read_bytes()).hexdigest()
    record("editorial_image_replacements_and_taxon_sources",
           review["media_overrides_sha256"] == replacement_sha
           and set(overrides) == set(review["image_replacements"])
           and all(by_id[pid]["wikidata_id"] == item["wikidata_id"]
                   and by_id[pid]["hero_image"] == item["hero_image"]
                   and by_id[pid]["hero_image"]["file_title"] != item["replaces"]
                   and bool(item["identity_evidence"])
                   for pid, item in overrides.items()),
           f"{len(overrides)} authored replacements agree with the pinned identity and asset bytes")

    manifest_media = {item["path"]: item["sha256"] for item in manifest["media"]}
    asset_paths = {str(p.relative_to(root)) for p in (out_dir / "media").iterdir()
                   if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}}
    observed_formats = Counter()
    for p in plants:
        image = p["hero_image"]
        path = root / image["local_path"]
        width, height, mime = parse_image_dimensions_and_mime(path.read_bytes())
        if (width, height, mime) != (image["width"], image["height"], image["mime"]):
            raise AssertionError(f"Stored image metadata differs from {path.name}")
        if manifest_media.get(image["local_path"]) != image["sha256"]:
            raise AssertionError(f"Missing or inconsistent image in manifest for {p['plant_id']}")
        observed_formats[mime] += 1
    record("all_media_headers_and_visual_decode_evidence",
           len(manifest_media) == len(plants) == images["files_read"] == review["media_reviewed"]
           and asset_paths == set(manifest_media)
           and images["plants_sha256"] == checksum
           and observed_formats == images["formats"] and not images["errors"],
           f"{len(plants)} actual file headers and digest-bound full decode/visual review evidence")

    raw = root / "knowledge-base/raw/catalogue-300"
    reference = root / "knowledge-base/references/personal/watering/plantfolio-common-plants"
    if not (raw.is_dir() and reference.is_dir()):
        raise AssertionError("Offline verification needs the pinned catalogue and Plantfolio inputs described in the README")
    files = ("plants.json", "coverage.json", "manifest.json", "discovery.json", "progress.json")
    with TemporaryDirectory(prefix="narat-t148-offline-") as temp:
        scratch = Path(temp)
        target_out = scratch / out_dir.relative_to(root)
        target_out.mkdir(parents=True)
        for subdir in ("knowledge-base/pipeline", "knowledge-base/manifests", "catalogue/manifests"):
            shutil.copytree(root / subdir, scratch / subdir, ignore=shutil.ignore_patterns("__pycache__"))
        for actual in (raw, reference):
            link = scratch / actual.relative_to(root)
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(actual.resolve(), target_is_directory=True)
        (target_out / "media").symlink_to((out_dir / "media").resolve(), target_is_directory=True)
        shutil.copy2(out_dir / "validation.json", target_out / "validation.json")
        for seed in ("19", "83"):
            env = {**os.environ, "PYTHONHASHSEED": seed}
            rebuild = subprocess.run(
                [sys.executable, str(scratch / "knowledge-base/pipeline/import_catalogue_300.py"), "--offline"],
                cwd=scratch, env=env, text=True, capture_output=True, timeout=45,
            )
            if rebuild.returncode:
                raise AssertionError(f"Offline import failed for hash seed {seed}: {rebuild.stderr[-1700:]}")
            for filename in files:
                if (target_out / filename).read_bytes() != (out_dir / filename).read_bytes():
                    raise AssertionError(f"Offline import drift for {filename} with hash seed {seed}")
            valid = subprocess.run(
                [sys.executable, str(scratch / "knowledge-base/pipeline/validate_catalogue_skeleton.py"), "--check"],
                cwd=scratch, text=True, capture_output=True, timeout=45,
            )
            if valid.returncode:
                raise AssertionError(f"Independent offline validator failed: {valid.stderr[-1700:]}")
    record("two_offline_imports_and_independent_sqlite_validation", True,
           "Two hash seeds reproduced the checked-in JSON byte for byte. The independent validator checked retained sources, rights, image hashes and SQLite parity.")
    offline = json.loads((out_dir / "offline-validation.json").read_text(encoding="utf-8"))
    record("offline_report_matches_this_release",
           offline["plants_sha256"] == checksum and offline["plants_sha256_unchanged"] is True
           and offline["network_required"] is False and offline["hash_seeds"] == [19, 83],
           "The published report refers to the same reproducible release bytes")
    return {"mode": "release", "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["pipeline", "release"], required=True)
    parser.add_argument("--run-id", default="manual")
    args = parser.parse_args()

    out_dir = ROOT / "docs/validation/automation/runs" / args.run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    summary_path = out_dir / "summary.json"
    summary_path.unlink(missing_ok=True)
    report = verify_pipeline(ROOT) if args.mode == "pipeline" else verify_release(ROOT)
    report["run_id"] = args.run_id
    report["timestamp"] = datetime.now(timezone.utc).isoformat()
    report["status"] = "PASS"
    (out_dir / f"t148-{args.mode}-gate.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    summary_path.write_text(json.dumps({"status": "PASS", "mode": "local",
                                        "report": f"t148-{args.mode}-gate.json"}) + "\n",
                            encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
