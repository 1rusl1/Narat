#!/usr/bin/env python3
"""Verification gate for T148 (pipeline audit and 606-species catalogue release acceptance)."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "catalogue/releases/skeleton-300-v1"
MANIFEST_PL = ROOT / "knowledge-base/manifests/pl-description-translations.json"

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


def parse_image_dimensions_and_mime(raw: bytes):
    if raw.startswith(b"\x89PNG\r\n\x1a\n") and len(raw) >= 24:
        w, h = struct.unpack(">II", raw[16:24])
        return w, h, "image/png"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return None, None, "image/webp"
    if raw.startswith(b"\xff\xd8"):
        i = 2
        n = len(raw)
        while i + 9 < n:
            if raw[i] != 0xFF:
                i += 1
                continue
            while i < n and raw[i] == 0xFF:
                i += 1
            if i >= n:
                break
            marker = raw[i]
            i += 1
            if marker in (0xD8, 0xD9) or (0xD0 <= marker <= 0xD7) or marker == 0x01:
                continue
            if i + 2 > n:
                break
            seg_len = struct.unpack(">H", raw[i : i + 2])[0]
            if seg_len < 2 or i + seg_len > n:
                break
            if marker in (
                0xC0,
                0xC1,
                0xC2,
                0xC3,
                0xC5,
                0xC6,
                0xC7,
                0xC9,
                0xCA,
                0xCB,
                0xCD,
                0xCE,
                0xCF,
            ):
                h, w = struct.unpack(">HH", raw[i + 3 : i + 7])
                return w, h, "image/jpeg"
            i += seg_len
    raise ValueError("Unsupported or corrupt image header")


def verify_pipeline(root: Path = ROOT) -> dict:
    checks = []

    def record(name: str, passed: bool, detail: str):
        checks.append({"name": name, "status": "PASS" if passed else "FAIL", "detail": detail})
        if not passed:
            raise AssertionError(f"{name}: {detail}")

    pl_path = root / "knowledge-base/manifests/pl-description-translations.json"
    pl_data = json.loads(pl_path.read_text(encoding="utf-8"))

    expected_revs = {
        "begonia_maculata": 1376148716,
        "begonia_corallina": 1368208086,
        "hoya_lanceolata": 1342565019,
    }
    for pid, rev in expected_revs.items():
        entry = pl_data.get(pid)
        ok = (
            isinstance(entry, dict)
            and entry.get("source_revision") == rev
            and isinstance(entry.get("pl_text"), str)
            and len(entry["pl_text"].strip()) >= 50
            and isinstance(entry.get("pl_common_names"), list)
        )
        record(f"pl_manifest_{pid}", ok, f"rev={entry.get('source_revision') if isinstance(entry, dict) else None}")

    tirucalli_names = [n.casefold() for n in pl_data.get("euphorbia_tirucalli", {}).get("pl_common_names", [])]
    record(
        "pl_manifest_euphorbia_tirucalli",
        "wilczomlecz okazały" not in tirucalli_names and "wilczomlecz ołówkowy" in tirucalli_names,
        f"names={tirucalli_names}",
    )

    for pid, bad_genus in (
        ("ceropegia_linearis", "ceropegia"),
        ("cymbidium_goeringii", "cymbidium"),
        ("cymbidium_kanran", "cymbidium"),
        ("oncidium_sphacelatum", "oncidium"),
    ):
        names = [n.casefold() for n in pl_data.get(pid, {}).get("pl_common_names", [])]
        record(f"pl_manifest_no_bare_genus_{pid}", bad_genus not in names, f"names={names}")

    sys.path.insert(0, str(root / "knowledge-base/pipeline"))
    import import_catalogue_300 as imp  # noqa: E402

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
    cn_genus = imp.common_names(item_genus_label, "Pilea peperomioides")
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

    p_phal = {
        "title": "Phalaenopsis violacea",
        "revisions": [{"revid": 6}],
        "extract": "Phalaenopsis violacea is a species of orchid native to Malaya.",
    }
    names_phal = [n["name"] for n in imp.intro_common_names(p_phal, ["Orchid"], genera)]
    record("intro_rejects_generic_orchid_alias", names_phal == [], f"got={names_phal}")

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
        checks.append({"name": name, "status": "PASS" if passed else "FAIL", "detail": detail})
        if not passed:
            raise AssertionError(f"{name}: {detail}")

    out_dir = root / "catalogue/releases/skeleton-300-v1"
    plants_path = out_dir / "plants.json"
    coverage_path = out_dir / "coverage.json"
    manifest_path = out_dir / "manifest.json"
    validation_path = out_dir / "validation.json"
    image_val_path = out_dir / "image-validation.json"
    offline_val_path = out_dir / "offline-validation.json"

    val_before = hashlib.sha256(validation_path.read_bytes()).hexdigest()
    res = subprocess.run(
        [sys.executable, str(root / "knowledge-base/pipeline/validate_catalogue_skeleton.py"), "--check"],
        capture_output=True,
        text=True,
    )
    val_after = hashlib.sha256(validation_path.read_bytes()).hexdigest()
    record(
        "validate_catalogue_skeleton_check",
        res.returncode == 0 and val_before == val_after,
        res.stderr.strip() or "PASS (no file mutation)",
    )

    bundle = json.loads(plants_path.read_text(encoding="utf-8"))
    plants = bundle["plants"]
    coverage = json.loads(coverage_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    validation = json.loads(validation_path.read_text(encoding="utf-8"))
    image_val = json.loads(image_val_path.read_text(encoding="utf-8"))
    offline_val = json.loads(offline_val_path.read_text(encoding="utf-8"))

    record("species_count_606", len(plants) == 606 and coverage["records"] == 606, f"count={len(plants)}")
    record(
        "descriptions_en_pl_606",
        coverage["description_en"] == 606
        and coverage["description_pl"] == 606
        and coverage["description_pl_native"] == 187
        and coverage["description_pl_translated"] == 419,
        f"native={coverage.get('description_pl_native')}, translated={coverage.get('description_pl_translated')}",
    )

    by_id = {p["plant_id"]: p for p in plants}
    for pid in ("begonia_maculata", "begonia_corallina", "hoya_lanceolata"):
        pl_desc = by_id[pid]["descriptions"]["pl"]
        ok = (
            pl_desc.get("translation_source_language") == "en"
            and "lista gatunków" not in pl_desc["text"].lower()
            and by_id[pid]["scientific_name"].lower() in pl_desc["text"].lower()
        )
        record(f"pl_description_fixed_{pid}", ok, pl_desc["text"][:100])

    genera = {p["scientific_name"].split()[0].casefold() for p in plants}
    bad_en = [
        (p["plant_id"], n["name"])
        for p in plants
        for n in p["common_names"]["en"]
        if n["name"].casefold() in {x.casefold() for x in FORBIDDEN_COMMON_NAMES_EN}
        or n["name"].casefold() in genera
    ]
    record("no_forbidden_or_genus_en_common_names", bad_en == [], f"bad_en={bad_en}")

    bad_pl = [
        (p["plant_id"], n["name"])
        for p in plants
        for n in p["common_names"]["pl"]
        if (p["plant_id"], n["name"].casefold()) in CROSS_SPECIES_PL_LABELS
        or n["name"].casefold() in genera
        or (p["plant_id"] == "euphorbia_tirucalli" and n["name"].casefold() == "wilczomlecz okazały")
    ]
    record("no_forbidden_or_genus_pl_common_names", bad_pl == [], f"bad_pl={bad_pl}")

    dim_mismatches = []
    for p in plants:
        hero = p["hero_image"]
        raw = (root / hero["local_path"]).read_bytes()
        w, h, mime = parse_image_dimensions_and_mime(raw)
        if hero.get("width") != w or hero.get("height") != h or hero.get("mime") != mime:
            dim_mismatches.append((p["plant_id"], hero.get("width"), w, hero.get("height"), h, hero.get("mime"), mime))
    record("all_606_hero_image_dimensions_and_mime_match", dim_mismatches == [], f"mismatches={dim_mismatches[:5]}")

    record(
        "editorial_review_completed",
        coverage.get("editorial_review") == "completed" and validation.get("editorial_review") == "completed",
        f"coverage={coverage.get('editorial_review')}, validation={validation.get('editorial_review')}",
    )
    record(
        "image_and_offline_validation_artifacts_606",
        image_val.get("files_read") == 606
        and offline_val.get("plants_sha256") == manifest["plants_sha256"]
        and offline_val.get("plants_sha256_unchanged") is True,
        f"files_read={image_val.get('files_read')}, offline_sha={offline_val.get('plants_sha256')}",
    )

    readme_txt = (out_dir / "README.md").read_text(encoding="utf-8")
    import_doc = (root / "docs/validation/catalogue-300-import-2026-11-04.md").read_text(encoding="utf-8")
    review_doc = (root / "docs/validation/catalogue-stage-review-2026-11-05.md").read_text(encoding="utf-8")
    record(
        "docs_synced_with_187_419_and_606",
        "187" in readme_txt
        and "419" in readme_txt
        and "187" in import_doc
        and "419" in import_doc
        and "204 польских описания отсутствуют" not in import_doc
        and "P2" in review_doc,
        "README and validation docs match 606 species (187 native PL + 419 translated PL)",
    )

    return {"mode": "release", "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["pipeline", "release"], required=True)
    parser.add_argument("--run-id", default="manual")
    args = parser.parse_args()

    out_dir = ROOT / "docs/validation/automation/runs" / args.run_id
    out_dir.mkdir(parents=True, exist_ok=True)
    report = verify_pipeline(ROOT) if args.mode == "pipeline" else verify_release(ROOT)
    report["run_id"] = args.run_id
    report["timestamp"] = datetime.now(timezone.utc).isoformat()
    (out_dir / f"t148-{args.mode}-gate.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
