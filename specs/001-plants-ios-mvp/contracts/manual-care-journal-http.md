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

`GET /sync` provides the pending control under `first_aid_followups`. Its `check_policy_snapshot` has `due_on` (calendar date), `interval_days`, and `source` (HTTPS `url` and `locator`). A client presents pending controls only during current access and treats the raw sync row as history after expiry. An exact `care.undo` targets the original entry as usual and changes an unfinished control to `undone` in the same transaction. No reminders, repeat chain or AI are used. Capturing a control observation or photo is a separate packet.
