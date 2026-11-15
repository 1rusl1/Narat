# Published catalogue read

The public catalogue can be read before sign-in. The Edge function uses the existing anonymous Supabase role and published catalogue RPCs. The staging acceptance uses `X-Client-Locale: en`. Existing Polish data and locale resolution remain available.

- `GET /catalogue` accepts optional `q`, `limit` from 1 to 200, and nonnegative `offset`. The defaults are an empty search, limit 50 and offset 0. The response preserves `release_version`, `kb_release_id`, `locale`, `total`, `limit`, `offset` and `items` from `search_catalogue_species`.
- `GET /catalogue/{identifier}` accepts the published `plant_id` slug or `taxon_id` UUID. It returns the canonical card from `get_catalogue_species_card`, including scientific and display names, nullable hero image with attribution and `care_profile_available`. An absent or unpublished card returns 404.

Unknown or duplicate query keys, malformed pagination and invalid identifiers return 400. An unexpected RPC or result failure returns 503. Both reads operate on the active catalogue release and do not require a published KB or a completed analysis.
