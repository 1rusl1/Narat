# Photo identification HTTP contract (T150/T153)

An active permanent account uses the existing private upload-ticket, signed PUT and upload-complete sequence described in [photo diagnosis](diagnosis-photo-http.md). Create a job with `POST /analysis/jobs` and `{"operation_id":"<uuid>","mode":"identification","photo_asset_id":"<uuid>","flow_id":"<optional uuid>"}`. A new operation returns 202, and a matching replay returns 200 with the same job ID. Reusing an operation ID across modes conflicts. Poll `GET /analysis/jobs/:id` for the latest owner-scoped status.

The existing envelope contains `job_id`, `mode`, `status`, `quota_kind`, `quota_state`, `result`, `error_code` and `error_message`. Identification can use `starter_identification`, `free_monthly` or `paid_monthly`. A succeeded identification returns:

```json
{
  "schema_version": "1.0",
  "job_id": "<uuid>",
  "mode": "identification",
  "catalogue_release_id": "<uuid>",
  "identification_status": "identified",
  "plant_id": "<species uuid>",
  "plant_display_name": "Swiss cheese plant"
}
```

An `unknown` result has null `plant_id` and `plant_display_name`. An identified plant belongs to the published species rows of the catalogue pinned at admission. The returned UUID is the catalogue card's `taxon_id`. Species and named hybrids are eligible. The server supplies the name in the request locale with scientific-name fallback. The result contains no condition, KB or diagnosis receipt. Only a usable classification consumes the reserved analysis quota. An unsuitable image returns unknown and releases the reservation. Provider refusal, truncation or invalid JSON fails the job and releases the reservation. Polling and replay never run the provider a second time.

If the starter is exhausted and a legacy account lacks a verified registration date, create returns 409 `QUOTA_REGISTRATION_REQUIRED`.

Personal photo attachment and seven-day guest draft/claim have separate contracts.

## Save a confirmed species with its original photo

A permanent account sends the existing `POST /commands` envelope with its own `operation_id`, `command_name: "plant.create"` and the following object serialized as the `payload_json` string.

```json
{
  "creation_source": "catalogue",
  "add_method": "scan",
  "creation_intent": "care",
  "identification_job_id": "<completed identification uuid>",
  "taxon_id": "<confirmed catalogue taxon uuid>"
}
```

The confirmed taxon can come from the AI result or a manual catalogue correction. It must be a currently published species or hybrid. An optional `origin_flow_id` must match the job. The server takes the original ready photo and flow from the completed job owned by this account. Both the new plant and its photo link commit with the existing collection cap and operation receipt. The scan receipt includes `photo_id` alongside the saved plant instance `plant_id`. An exact retry returns the same receipt. A second operation for the same attached photo returns 409. A missing, unrelated, unfinished or foreign identification source returns 404.

`GET /plants/{plant_id}/photo` returns the original normalized bytes and MIME to the authenticated owner. The response is private and non-cacheable. Another owner, a missing photo or a deleted plant returns 404. The ordinary catalogue save still accepts its previous inputs and needs no photo.

## Guest draft and claim

Use the anonymous Supabase session and the same random `X-Installation-Credential` across sign-in. Register the installation via `POST /installations/register`, then use the same private upload and identification endpoints. Guest identification uses the installation's starter quota.

1. With the guest session, send `POST /drafts` with `operation_id`, `identification_job_id` and the confirmed catalogue `taxon_id`. The response contains `draft_id` and `expires_at`. The server sets a seven-day lifetime. An exact replay preserves the deadline.
2. Sign in with the permanent account and send `POST /installations/bind` with the registered `installation_id`.
3. Send `POST /claims/prepare` with `operation_id` and `draft_id`. The response contains `claim_id`, `draft_id` and `proof_expires_at`. Proof lasts up to 15 minutes and can be refreshed while the draft is valid.
4. Send `POST /claims/commit` with its own `operation_id` and `claim_id`. The server verifies and copies the original photo before committing one plant and transferring the original `photo_id`. The result is the canonical save receipt. Exact retries return the same receipt. `GET /claims/{claim_id}` reports progress or that result.

All steps after sign-in use the same installation credential and permanent Bearer. `DELETE /drafts/{draft_id}` discards an unclaimed draft using the original guest session. Expired or deleted drafts return 410 `DRAFT_EXPIRED`. The saved plant retains its private photo past the draft deadline. The service cleanup entry point sweeps expired or abandoned draft media and preserves committed destination objects.
