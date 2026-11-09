# Narat / Quiet Garden / EN — первый набор макетов

Редакция 2026-11-09. Перед генерацией использовать [локальную спецификацию](stitch-specification-en.md) и [общий flow](../docs/stitch-ui-prompts.md); они являются частью задания.

Create six connected native iOS frames in English: photo entry; unified preliminary result with Save; flat My Plants collection; plant card with recommendations/history; Today with conditional check/log/undo; dismissible subscription sheet. Include an empty Today state as a variant. Use the same plant, observations and account state throughout.

Use warm background #F7F5EF, surface #FFFFFF, text #202C24, secondary #626A61, green #294D3C. Plant photography is the main visual anchor. Use native scalable typography, generous spacing, clear labels and one primary action per state. Support iOS 17+, narrow screens, Dynamic Type, VoiceOver and reduced motion. Verify contrast; do not reduce text size to fit.

The main path is recognition → diagnosis → recommendations → care. One photo analysis can return species and issue. Show action now, its condition/reason and next justified check. A dry observation is not a watering record; logging is explicit and reversible. Do not invent dates, diagnosis, health, source data or completed actions.

Provide catalogue/identification-only alternatives without a mandatory intention screen. Save from the result, sign in if needed, then open the plant card. Free first help precedes login/paywall. Catalogue does not require photo/questions. First diagnosis asks missing basics only; repeat diagnosis has no questions.

Free: two separate starter uses; three monthly analyses from registration; collection cap three. Paid/trial: 100 analyses in that same period, unlimited adding, additional applicable care actions. Prices/trial use verified store values. No unavailable advice or treatment-program promise. Expiry stops automatic care for all plants, preserving own history/manual entries. Local trial reminder is opt-in.

Do not add rooms, light measurement, clarification questions after analysis, reports, free-care slots, photo export/main-picker/comparison, AI progress scoring, seasonal override UI or multi-step treatment timelines. Error/empty states must preserve context and never pretend a backend action succeeded. These designs still require user and integration testing.
