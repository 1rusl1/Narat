"""Validate and prepare the approved T148 artefact for narat-staging only."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import build_opener, HTTPRedirectHandler, Request
import uuid


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "knowledge-base/pipeline"))
from catalogue_image import parse_image_dimensions_and_mime

SOURCE = ROOT / "catalogue/releases/skeleton-300-v1"
EXPECTED_SHA = "85fcaba4bfe8ef1cf4a3c1f07fdd1ce3517aea7feb8886124dc063a43b2e3887"
PROJECT = "ijwnyjdomwvnzmmcurkt"
ORIGIN = f"https://{PROJECT}.supabase.co"
BUCKET = "catalogue-media"
VERSION = f"skeleton-300-v1-en-{EXPECTED_SHA[:8]}"
RELEASE = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{ORIGIN}/catalogue/{EXPECTED_SHA}"))
PRIOR_RELEASE = "f10e8952-15d9-447d-89d6-9ef139536edb"
CARE_KB = "3ed50000-0000-4000-8000-000000000012"
PILOT_TAXA = {
    "chlorophytum_comosum": "01286dbd-268e-415e-999a-348ed0e4ef16",
    "ficus_elastica": "62ce01d2-1b58-4f42-827f-a72bfb6b7123",
    "monstera_deliciosa": "83f27806-3577-4bdc-9b18-222bedcf06d7",
}
PILOT_PLANTS = (
    "276ffeec-1522-4b42-b290-e6c07860f8d8",
    "9ee20834-951a-4c4e-9f63-cfe6221554ec",
)
MIME_SUFFIX = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
RECORDS = 606
BATCH_SIZE = 30


class PublishError(ValueError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@dataclass(frozen=True)
class Asset:
    file: Path
    key: str
    sha256: str
    mime: str
    size: int

    @property
    def public_url(self):
        return f"{ORIGIN}/storage/v1/object/public/{BUCKET}/{self.key}"


def digest(content):
    return hashlib.sha256(content).hexdigest()


def require(condition, message):
    if not condition:
        raise PublishError(message)


def load_release():
    raw = (SOURCE / "plants.json").read_bytes()
    manifest = json.loads((SOURCE / "manifest.json").read_bytes())
    review = json.loads((SOURCE / "editorial-review.json").read_bytes())
    require(digest(raw) == EXPECTED_SHA == manifest["plants_sha256"] == review["plants_sha256"],
            "The artefact is not the approved T148 release.")
    bundle = json.loads(raw)
    records = bundle["plants"]
    paths = {item["path"]: item["sha256"] for item in manifest["media"]}
    require(bundle["version"] == "skeleton-300-v1" and bundle["schema_version"] == "catalogue-skeleton-1.1"
            and len(records) == manifest["records"] == review["records_reviewed"] == len(paths) == RECORDS,
            "The release metadata or record count differs.")

    assets = []
    for record in records:
        image = record["hero_image"]
        path = ROOT / image["local_path"]
        mime = image["mime"]
        sha = image["sha256"]
        require(path.parent == SOURCE / "media" and path.is_file() and not path.is_symlink()
                and paths.get(image["local_path"]) == sha and re.fullmatch(r"[a-f0-9]{64}", sha)
                and mime in MIME_SUFFIX and (path.suffix.lower() == MIME_SUFFIX[mime]
                                             or mime == "image/jpeg" and path.suffix.lower() == ".jpeg"),
                f"Unexpected local asset for {record['plant_id']}.")
        raw_image = path.read_bytes()
        require(len(raw_image) == image["bytes"] and digest(raw_image) == sha,
                f"Wrong local media bytes for {record['plant_id']}.")
        require(parse_image_dimensions_and_mime(raw_image) == (image["width"], image["height"], mime),
                f"Wrong local media metadata for {record['plant_id']}.")
        require(all(isinstance(image.get(field), str) and image[field].strip() for field in
                    ("author", "license", "license_url", "attribution", "source_page", "download_url")),
                f"Missing attribution for {record['plant_id']}.")
        asset = Asset(path, f"{VERSION}/{sha}{MIME_SUFFIX[mime]}", sha, mime, len(raw_image))
        assets.append(asset)
        # Keep the upstream download URL and all attribution. The existing iOS
        # photo decoder uses download_url, so point that field at staging Storage.
        image["source_download_url"] = image["download_url"]
        image["download_url"] = asset.public_url
        image["storage_path"] = asset.key

    require(len({r["plant_id"] for r in records}) == len({r["wikidata_id"] for r in records})
            == len({a.key for a in assets}) == RECORDS, "Duplicate taxon or asset in the release.")
    return records, assets, bundle["sources"]


def sql_json(value):
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    require("$t149_data$" not in payload and "$t149$" not in payload, "Unexpected SQL delimiter in release.")
    return f"$t149_data${payload}$t149_data$::jsonb"


def sql_uuid_list(values):
    return ", ".join(f"'{uuid.UUID(value)}'::uuid" for value in values)


def render_sql(out, records, assets, sources):
    out.mkdir(parents=True, exist_ok=False)
    substitutions = {
        "@RELEASE@": RELEASE, "@PRIOR_RELEASE@": PRIOR_RELEASE, "@VERSION@": VERSION,
        "@SHA@": EXPECTED_SHA, "@BUCKET@": BUCKET, "@ORIGIN@": ORIGIN,
        "@COUNT@": str(RECORDS), "@CARE_KB@": CARE_KB, "@PILOT_PLANTS@": sql_uuid_list(PILOT_PLANTS),
        "@PILOT_TAXA@": sql_json(PILOT_TAXA),
    }

    def write(name, sql):
        for marker, value in substitutions.items():
            sql = sql.replace(marker, value)
        (out / name).write_text(sql)

    write("00-bucket.sql", """BEGIN;
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('@BUCKET@', '@BUCKET@', true, 10485760, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;
DO $t149$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='@BUCKET@' AND name='@BUCKET@'
      AND public AND file_size_limit=10485760
      AND allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp']) THEN
    RAISE EXCEPTION 'unexpected_catalogue_bucket_configuration';
  END IF;
END;
$t149$;
COMMIT;
""")
    guard = """DO $t149$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@PRIOR_RELEASE@' AND state='published')
     OR NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@RELEASE@' AND version='@VERSION@'
                    AND source_hash='@SHA@' AND kb_release_id IS NULL AND state IN ('draft','validated')) THEN
    RAISE EXCEPTION 'unexpected_catalogue_release_state';
  END IF;
END;
$t149$;
"""
    write("01-draft.sql", """BEGIN;
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));
INSERT INTO public.catalogue_releases(id,version,schema_version,source_hash,sources,state)
VALUES ('@RELEASE@','@VERSION@','catalogue-skeleton-1.1','@SHA@',""" + sql_json(sources)
          + """,'draft') ON CONFLICT DO NOTHING;
""" + guard + """COMMIT;
""")
    for offset in range(0, len(records), BATCH_SIZE):
        batch = records[offset:offset + BATCH_SIZE]
        write(f"draft-{offset // BATCH_SIZE + 1:02d}.sql", """BEGIN;
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));
""" + guard + """CREATE TEMP TABLE t149_batch ON COMMIT DROP AS
SELECT item FROM jsonb_array_elements(""" + sql_json(batch) + """) AS item;
SELECT count(public.upsert_catalogue_skeleton_species('@RELEASE@', item, true)) AS imported FROM t149_batch;
DO $t149$
BEGIN
  IF EXISTS (
    SELECT 1 FROM t149_batch b LEFT JOIN public.catalogue_release_species s
      ON s.release_id='@RELEASE@' AND s.plant_id=b.item->>'plant_id'
    WHERE s.taxon_id IS NULL OR s.status <> 'published' OR EXISTS (
      SELECT 1 FROM jsonb_each(b.item - 'status' - 'taxon_id') f
      WHERE to_jsonb(s)->f.key IS DISTINCT FROM f.value
    )
  ) THEN
    RAISE EXCEPTION 'staged_catalogue_batch_differs_from_approved_payload';
  END IF;
END;
$t149$;
COMMIT;
""")

    # The cutover also proves that the draft is the exact rendered record set.
    # Keep this compact so it can be sent in one Management API query.
    media_fields = ("sha256", "storage_path", "author", "license", "license_url",
                    "attribution", "source_page", "mime", "bytes")
    projections = {r["plant_id"]: [r["wikidata_id"], *(r["hero_image"][key] for key in media_fields),
                                  r["scientific_name"]] for r in records}
    write("99-activate.sql", (Path(__file__).with_name("staging_catalogue_activation.sql").read_text()
                              .replace("@PROJECTIONS@", sql_json(projections))))
    write("rollback.sql", """BEGIN;
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(hashtext('public.catalogue_releases_mutex'));
DO $t149$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@RELEASE@'
                 AND state='published' AND source_hash='@SHA@')
     OR NOT EXISTS (SELECT 1 FROM public.catalogue_releases WHERE id='@PRIOR_RELEASE@' AND state='retired')
     OR EXISTS (SELECT 1 FROM public.diagnosis_job_runtime WHERE catalogue_release_id='@RELEASE@')
     OR EXISTS (SELECT 1 FROM public.plants p JOIN public.catalogue_release_species s
           ON s.taxon_id=p.taxon_id AND s.release_id='@RELEASE@'
           WHERE p.deleted_at IS NULL AND NOT EXISTS (
               SELECT 1 FROM public.catalogue_release_species old
               WHERE old.release_id='@PRIOR_RELEASE@' AND old.taxon_id=p.taxon_id)) THEN
    RAISE EXCEPTION 'catalogue_rollback_requires_manual_review';
  END IF;
END;
$t149$;
SELECT public.publish_catalogue_release('@PRIOR_RELEASE@') AS rollback;
COMMIT;
""")
    (out / "media.json").write_text(json.dumps(
        [{"key": a.key, "sha256": a.sha256, "bytes": a.size, "mime": a.mime} for a in assets],
        indent=2) + "\n")


def storage_key():
    # The privileged key stays in memory. Never log CLI output or HTTP headers.
    result = subprocess.run(["supabase", "projects", "api-keys", "--project-ref", PROJECT,
                             "--reveal", "-o", "json"], capture_output=True, timeout=45)
    require(result.returncode == 0, "The staging Storage credential is unavailable.")
    try:
        keys = json.loads(result.stdout)
        key = next(row["api_key"] for row in keys if row.get("name") == "service_role")
    except (ValueError, KeyError, StopIteration, TypeError):
        raise PublishError("Could not resolve the staging service role.") from None
    require(isinstance(key, str) and key.count(".") == 2, "Unexpected Storage credential format.")
    try:
        payload = key.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except ValueError:
        raise PublishError("Could not validate the staging credential metadata.") from None
    require(isinstance(claims, dict) and claims.get("ref") == PROJECT and claims.get("role") == "service_role",
            "Storage credential is for another project or role.")
    return key


def request_asset(req, limit):
    for retry in range(4):
        try:
            with build_opener(NoRedirect).open(req, timeout=30) as response:
                return response.status, response.headers.get_content_type(), response.read(limit)
        except HTTPError as err:
            if err.code not in (429, 500, 502, 503, 504) or retry == 3:
                with err:
                    return err.code, err.headers.get_content_type(), err.read(limit)
        except (URLError, TimeoutError):
            if retry == 3:
                raise PublishError("A staging Storage request failed after retries.") from None
        time.sleep(0.5 * 2 ** retry)
    raise AssertionError("Unreachable retry state")


def verify_asset(asset):
    status, mime, raw = request_asset(Request(asset.public_url), asset.size + 1)
    if status == 404:
        return False
    require(status == 200 and mime == asset.mime and len(raw) == asset.size
            and digest(raw) == asset.sha256, f"Public object does not match the release: {asset.key} ({status}).")
    return True


def publish_media(assets, upload):
    key = storage_key() if upload else None

    def handle(asset):
        if key:
            url = f"{ORIGIN}/storage/v1/object/{BUCKET}/{asset.key}"
            headers = {"Authorization": f"Bearer {key}", "apikey": key, "x-upsert": "false",
                       "Content-Type": asset.mime, "Cache-Control": "max-age=31536000"}
            status, _, response = request_asset(Request(url, data=asset.file.read_bytes(), headers=headers), 2048)
            if status not in (200, 201):
                # Duplicate responses are safe only if the unchanged object
                # proves byte-for-byte identical. Never overwrite a conflict.
                duplicate = status in (400, 409) and any(
                    value in response.lower() for value in (b"already exists", b"duplicate"))
                require(duplicate, f"Upload failed for {asset.key} ({status}).")
        for attempt in range(3):
            if verify_asset(asset):
                return
            if attempt < 2:
                time.sleep(attempt + 1)
        raise PublishError(f"Public object missing: {asset.key}.")

    with ThreadPoolExecutor(max_workers=6) as pool:
        for count, _ in enumerate(pool.map(handle, assets), 1):
            if count % 100 == 0 or count == len(assets):
                print(f"Verified {count}/{len(assets)} public objects", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify", "render", "upload", "verify-media"])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--project-ref", choices=[PROJECT])
    args = parser.parse_args()
    if args.action == "render" and args.out is None:
        parser.error("render requires --out")
    if args.action in ("upload", "verify-media") and args.project_ref != PROJECT:
        parser.error("staging Storage requires the documented --project-ref")
    try:
        records, assets, sources = load_release()
        print(f"{VERSION} {RELEASE}: {len(records)} verified records, {sum(a.size for a in assets)} image bytes",
              flush=True)
        if args.action == "render":
            render_sql(args.out, records, assets, sources)
        if args.action in ("upload", "verify-media"):
            publish_media(assets, args.action == "upload")
    except PublishError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
