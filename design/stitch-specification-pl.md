# Narat — Polish UI specification

Updated 2026-11-09. Behavioral source: [current UI flow](../docs/stitch-ui-prompts.md) and [product specification](../specs/001-plants-ios-mvp/spec.md). These replace previous room/selection/report/diagnostic-clarification flows. Design is not evidence of implemented behavior.

All user-facing labels, errors, dates and example content must be natural Polish, with diacritics; no English fallback labels. Keep Latin scientific names and user-entered names. Generate this locale separately; use the same underlying actions and states as the other locale.

Primary entry: Sprawdź roślinę. Alternatives: catalogue and identification only. Use one result with species, preliminary issue or uncertainty, action now, reason and next check; save/edit from that result. No mandatory intention/pre-save/post-save screens.

Create only the screens in [the shared flow](../docs/stitch-ui-prompts.md). Use [Quiet Garden](design-concept.md): warm background, real plant photo, short action labels, native controls, visible uncertainty and necessary conditions. Minimum 44pt targets, semantic scalable type, VoiceOver labels, 320pt/393pt and large Dynamic Type layouts. No fabricated success, exact health scores, lux, timeline, rooms or photo comparison.

Local prices: 49,99 zł/miesiąc; 199,99 zł/rok, actual storefront values take precedence. Annual trial only when eligible, opt-in reminder. Free=3/paid=100 monthly analyses from account registration; Free collection up to three. After expiry all automatic care stops, own history/manual diary remain. Never sell unavailable advice.

Link photo → missing basics → result → sign-in/save → card → check/log/undo. Catalogue skips photo/questions. Returning user opens Today. Include error/loading/unknown/empty/permission-denied states and pause/expiry. Four stages describe value, not four required API calls.
