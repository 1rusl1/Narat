# Manual care journal

An active permanent owner submits a manual watering fact for an existing plant through `POST /commands`. Use the same authenticated command envelope as plant creation, with a target `plant_id` UUID and a separate `operation_id` UUID. `payload_json` is a JSON-encoded string. Optional `X-Operation-Id` must match the body.

| `command_name` | Decoded `payload_json` | Receipt `state` |
| --- | --- | --- |
| `care.record` | `{"action_code":"water","occurred_at":"2026-11-11T18:00:00+03:00","timezone":"Europe/Moscow"}` | `active` |
| `care.undo` | `{"entry_id":"17000000-0000-4000-8000-000000000031"}` | `voided` |

Send `occurred_at` as a calendar-valid timestamp with an offset and up to six fractional digits. The database rejects future events and derives the journal day in the given IANA time zone. Undo targets the same owner's manual watering entry on the selected plant.

HTTP 200 returns `plant_id`, `entry_id`, `reversal_id`, `state` and `watermark`. `reversal_id` is null for record. An exact replay returns its original receipt. Read current state from owner `GET /sync`, with `care_entries` for the fact and `care_reversals` for the undo history. An undone fact has `state: "voided"`.

Invalid input returns 400, unavailable ownership returns 403, and a missing or inaccessible plant or entry returns 404. Changing a stored operation or attempting a second distinct undo returns 409. The service returns 503 on unexpected storage failures. A manual entry has no linked task and does not create or update schedules or recommendations.
