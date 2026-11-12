# Owner plant care recommendation

`GET /plants/{plant_id}/care/recommendation` reads the currently published care profile for the saved plant's taxon. Use the permanent owner's Bearer session and the instance UUID. No query parameters are required. The response is private and uncached.

```json
{
  "plant_id": "17100000-0000-4000-8000-000000000011",
  "status": "available",
  "recommendation": {
    "action_id": "check_monstera_mix_before_watering",
    "action_code": "check_soil",
    "text": "Check the potting mix. Let it dry slightly between waterings. Once it has dried a little, water thoroughly.",
    "next_check_interval_days": null,
    "source": {
      "url": "https://hort.extension.wisc.edu/articles/monstera-deliciosa/",
      "locator": "Growing Swiss-Cheese Plant, watering paragraph"
    }
  }
}
```

The text describes a check and conditional watering. A null interval omits the calendar check. This route reads published guidance and leaves care facts and schedules to their respective commands. `X-Client-Locale` selects the supported locale through the shared resolver. The staging acceptance uses English.

An owned plant without an applicable published action returns HTTP 200 with `status: "unavailable"` and `recommendation: null`. An absent, deleted or foreign plant returns 404. An unauthenticated request returns 401 and an anonymous account returns 403.

## Calendar check (V11/V19)

The same response adds a top-level `next_check` object or null. Treat a missing field from an older server as null. `recommendation` remains the immediate conditional soil check. The calendar date is for checking the soil.

```json
{
  "next_check": {
    "due_on": "2026-11-17",
    "anchor_on": "2026-11-10",
    "interval_days": 7,
    "basis": "Based on the last recorded watering and the published 7-day interval.",
    "source": {
      "url": "https://example.test/reviewed-rule",
      "locator": "Soil check interval"
    }
  }
}
```

The example uses fixture values. The server needs a published, applicable `check_soil` routine action and direct evidence for `/actions/{index}/next_check_interval_days` from an HTTPS source approved for derived records. `recommendation.next_check_interval_days` contains the supported interval or null. The anchor is the stored local day of the latest actual active watering for this plant, ordered by occurrence time. `due_on` adds calendar days to that day and keeps overdue dates. On the next GET, a corrected date is reflected and an undone watering falls back to the previous active watering, if any.

The server returns null for a missing or unsupported interval, missing active watering, disabled basic care, a paused soil-check rule, or a recorded entitlement without current verified access. The immediate recommendation remains available when its own evidence is valid. `basis` uses the response locale. Clients can render the date as a calendar day and show the interval's source. This read projection creates no scheduled task, reminder, recurrence, or first-aid control.

After another actual watering, record the fact through the existing `care.record` command. The next GET projects one soil check from that newer factual anchor while the published rule remains applicable. Re-reading an overdue check keeps its original date. A recorded watering still appears in the journal when the interval evidence is absent or access has expired. A conditional soil check alone gives no new watering anchor.
