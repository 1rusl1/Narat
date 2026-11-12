# Manual care journal

An active permanent owner submits a manual watering fact for an existing plant through `POST /commands`. Use the same authenticated command envelope as plant creation, with a target `plant_id` UUID and a separate `operation_id` UUID. `payload_json` is a JSON-encoded string. Optional `X-Operation-Id` must match the body.

| `command_name` | Decoded `payload_json` | Receipt `state` |
| --- | --- | --- |
| `care.record` | `{"action_code":"water","occurred_at":"2026-11-11T18:00:00+03:00","timezone":"Europe/Moscow"}` | `active` |
| `care.correct_date` | `{"entry_id":"17000000-0000-4000-8000-000000000031","occurred_at":"2026-11-10T18:00:00+03:00","timezone":"Europe/Moscow"}` | `active` |
| `care.undo` | `{"entry_id":"17000000-0000-4000-8000-000000000031"}` | `voided` |

Send `occurred_at` as a calendar-valid timestamp with an offset and up to six fractional digits. The database rejects future events and derives the journal day in the given IANA time zone. Undo targets the same owner's manual watering entry on the selected plant.

Date correction targets an active manual watering entry on the selected plant. It uses a new operation ID and keeps the entry ID, original record operation and recorded time. The updated date appears in owner sync. A correction for an already voided entry returns 409. A previously accepted correction still replays its original receipt after undo.

HTTP 200 returns `plant_id`, `entry_id`, `reversal_id`, `state` and `watermark`. `reversal_id` is null for record. An exact replay returns its original receipt. Read current state from owner `GET /sync`, with `care_entries` for the fact and `care_reversals` for the undo history. An undone fact has `state: "voided"`.

Invalid input returns 400, unavailable ownership returns 403, and a missing or inaccessible plant or entry returns 404. Changing a stored operation or attempting a second distinct undo returns 409. The service returns 503 on unexpected storage failures. A manual entry has no linked task and does not create or update schedules or recommendations.

## First-aid action and one pending control (V19)

`POST /commands` accepts `care.first_aid.record` with the same envelope and `payload_json` containing `job_id`, `occurred_at`, and `timezone`. The job UUID must belong to a successful problem diagnosis bound to the same saved plant, with current conditions and a still-published applicable first action directly supported by an approved HTTPS source. This packet supports the published diagnostic soil check. A missing, foreign or incompatible job/action returns 404. The command rechecks eligibility independently of the [job status projection](diagnosis-photo-http.md#действие-первой-помощи-доступное-для-записи-v19).

An accepted fact returns the usual active entry receipt plus `control_id` (UUID or null). The same operation returns the same receipt. Another operation for the same diagnosis returns 409. The date of a pending control is the action's local day plus the published interval when that interval has direct approved source evidence and access is current. Without that evidence, the action remains in the journal with a null control ID.

`GET /sync` provides the pending control under `first_aid_followups`. Its `check_policy_snapshot` has `due_on` (calendar date), `interval_days`, and `source` (HTTPS `url` and `locator`). A client presents pending controls only during current access and treats the raw sync row as history after expiry. An exact `care.undo` targets the original entry as usual and changes an unfinished control to `undone` in the same transaction. No reminders, repeat chain or AI are used.

## Manual observation for a first-aid control (V19)

`POST /commands` accepts `care.first_aid.observe` with the same envelope. Its decoded `payload_json` has `control_id` (UUID), `status_code` (`improved`, `unchanged`, `worse`, or `unknown`), and optional `photo_id` (UUID). Omit `photo_id` to complete the control without a photo. The server records the acceptance time in `observed_at`.

HTTP 200 returns `plant_id`, `control_id`, `observation_id`, `state: "completed"`, and `watermark`. An exact replay by the active permanent owner returns the same receipt even after access expiry or undo. Invalid input returns 400. A missing control or a control outside the selected owner and plant returns 404. A changed operation or a new attempt on a completed, undone, stale, or expired control returns 409.

Owner sync returns the completed `first_aid_followups` row and the `care_observations` row with `first_aid_control_id`. If undo commits first, observation conflicts. If observation commits first, undo preserves the completed control and observation as history. Completion leaves quotas and analysis jobs untouched.

### Private observation photo

1. For an active control, `POST /media/first-aid/upload-ticket` takes the standard `operation_id`, `mime_type`, `byte_size`, `content_sha256`, plus the `plant_id` and `control_id` UUIDs. Use a separate operation ID for the observation. The [upload ticket fields and image limits](diagnosis-photo-http.md) apply. The ticket binds one private photo asset to that owner, plant and control. An exact ticket retry returns the same asset. A changed ticket operation returns 409.
2. `PUT` the normalized bytes to the returned same-origin `signed_upload_url` with the owner's Bearer and matching `Content-Type`. If the response is lost, use `POST /media/first-aid/complete` with `photo_asset_id`. Either returns `200 {"photo_asset_id":"…","state":"ready"}` when the stored bytes are verified. The existing 60-second upload window applies.
3. Use that ready asset UUID as `photo_id` in `care.first_aid.observe`. The response shape stays the same. `care_observations.photo_id` in owner sync confirms the attachment. The observation, photo link and control completion commit together. A missing photo, foreign photo or photo for another control returns 404. A matching unfinished photo returns 409. Exact observation replay requires the same photo UUID or the same omission.
4. `GET /care/observations/{observation_id}/photo` streams the verified bytes to the active permanent owner with `Cache-Control: private, no-store`. Read access to completed history survives undo and entitlement expiry. Unattached photos and other owners' observations return 404. Observation photos are ineligible for `/analysis/jobs`.
