# Photo identification UI contract (accepted scoped technical)

Production Model/DTO API is unchanged from accepted ID-A/ID-B1/W0. PreliminaryResultView consumes `connection.publicMediaLoader`; picker supplies `confirmationTitle`, `cancelTitle`, `contextTitle` without changing default legacy behavior. Published text/images come from existing validated DTO; no confidence threshold or generated care text is introduced.

Suggested: published hero/name/scientific name/description/credit/source + uncertainty, explicit Confirm and Choose another species. Unknown: immediate Choose a species. Picker preview GET is distinct from exactly one fresh scoped Model validation GET per explicit UUID callback. Context changes/whole result removal invalidate the view-owned request; ordinary sheet presentation remains usable.

Confirm freezes the selected taxon while preserving original job/photo/source owner. It does not create a draft. Actual Save uses the existing GuestPhotoClaim/durable journal, with selected B and original job/photo; no fabricated photo_id request field. Owner conversion legitimately clears the analysis model, while journal/receipt/canonical facts retain source identity. Uploaded-byte proof refers to `aiVisionJPEG`, not raw display/selected JPEG.

Direct route upper native Back is local to Prelim when returnToPlant is nil; existing locks/actions remain. Guest transfer gains default-compatible locale text only. DEBUG Root/fixture controls are namespaced and absent in Release; they are not public application APIs. Same-SDK proof compares the full snapshot (including ABA), and a fresh increasing Root probe revision reads the live retained model after UIKit host removal.

Fixture acceptance does not prove real Storage/AI/provider integration, delivered late HTTP completion, broad PL care localization or physical device behavior. See tester-photo-identification-2026-11-26.{md,json} for the exact executed matrix.
