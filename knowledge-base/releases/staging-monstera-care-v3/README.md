# Unpublished staging Monstera care v3 candidate

This candidate contains one PlantProfile v2 record (record_version=2), release 3ed50000-0000-4000-8000-000000000013. It is not published or activated. The v2 release and catalogue are unchanged. This packet contains no publication SQL or deployment operation and makes no task-completion claim; T160/T171 remain open.

## Reviewed facts

- UW–Madison Extension: indoor Monstera potting mix should dry slightly before thorough watering. The v2 source document, evidence note digest and /actions/0 evidence are preserved.
- Illinois Extension, https://extension.illinois.edu/sites/default/files/hkmw-_houseplants.pdf, page 2, Day to Day Maintenance / Watering: check indoor soil every few days to weekly, water as necessary, let water drain. Frequency depends on plant, soil and conditions. Verified 2026-11-15T08:46:56Z. This is general houseplant guidance, not species-specific Monstera evidence.
- University of Minnesota Extension, https://extension.umn.edu/garden-and-home/yard-and-garden/gardening-in-minnesota/propagating-monstera-deliciosa, Quick Facts: Monstera deliciosa is a medium-light houseplant. Reviewed 2026-11-15. Its mature-plant watering guidance is not used.

## Staging-only editorial inference and applicability

The EN/PL action text is authored editorial content. Seven days is an upper routine soil observation cadence inferred from the Illinois range for this narrow staging context, not a species-specific interval established by that publisher. Check sooner as needed. A next check is an observation, never automatic watering or an instruction to postpone justified watering. Slight drying remains the watering condition; water thoroughly when needed and allow excess water to drain.

Eligibility is limited to a saved, potted indoor Monstera with the exact current context in refresh-conditions.json: medium light, manually supplied and explicitly confirmed; watering habit unknown; drainage yes; plastic pot. The watering_code value unknown is an explicit recorded habit category, not permission to proceed with missing context. Manual confirmation, unknown watering habit and chosen plastic material are narrow editorial eligibility choices, not facts or recommendations attributed to the publishers. Medium indoor light is supported by UMN; draining indoor pots are supported by Illinois.

The sidecar is separate from the compact profile and is intended for validation_report.refresh_conditions, keyed by the unchanged action ID. No refresh_conditions field is added to the action schema. The provenance path /actions/0/refresh_conditions documents applicability metadata; it is not an embedded profile property. Its first source is UMN (medium indoor light), followed by Illinois (draining indoor houseplants). The interval path /actions/0/next_check_interval_days links specifically to Illinois; /actions/0 retains Wisconsin.

## Retained evidence notes and hashes

Hashes identify the following exact retained UTF-8 editorial notes without a trailing newline, except Illinois, whose hash identifies the checked PDF bytes. These conventions do not claim a raw HTML digest or permission to republish source documents. The existing schema field names are preserved. Each source's allowed_for is limited to derived_records; use_basis covers only derived factual content and the identified editorial inference.

Wisconsin retained note (unchanged from v2):

> The Extension article advises thorough watering of indoor Monstera deliciosa after the growing medium has dried slightly since the last watering.

SHA-256: c08594a4ad0f2e830f630451c9c9b111da71e76f74e7bd14e5ce0b37a6d8550d

UMN retained note:

> University of Minnesota Extension lists Monstera deliciosa as a medium-light houseplant in Quick Facts.

SHA-256: 6ed55823ebe6369a82c153470e432acf42bae6eb5c59aa115e8b9b966f3e2d94

UMN retrieved_at uses 2026-11-15T00:00:00Z as a date-only review marker required by the schema, not an observed retrieval time. Illinois uses the supplied verification timestamp. The combined validation timestamp records that supplied evidence review, not a new live retrieval by this packet.

Illinois checked PDF SHA-256: 6cf3f44999ce73441313278c7baefc651da22f66b24fca469963afc465939860. No PDF or raw HTML copy is added here; source document references and the prior Wisconsin provenance are retained.

## Technical gate and next step

A numeric interval alone cannot create a date. The separate backend packet's 052 resolver and 056 explicit contextual calendar gate require known, exactly matching current conditions, enabled care membership, a persisted qualifying watering fact, and an explicit matching refresh with current snapshot, revision, profile, action, interval and provenance evidence. Missing, mismatched or withdrawn evidence must fail closed. Existing access and publication gates still apply. This packet does not implement or activate that gate.

Preparation is limited to these three v3 files. Controller checks are pending: diff-check, t157-compact-plant, v19-contextual-kb and kb-tests. No fixture, build or live integration checks were run for this packet. After controller checks and Review/QA, the next separate step is atomic publication rehearsal preserving v2, followed by live dated owner operations; this README does not authorize publication.
