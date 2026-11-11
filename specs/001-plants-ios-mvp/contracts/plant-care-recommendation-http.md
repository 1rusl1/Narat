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
