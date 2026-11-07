# Narat — Quiet Garden: английская версия для Stitch

Обновлено 2026-11-01. Новая [концепция](design-concept.md) заменяет прежнюю текстовую подачу. Скопируй текст ниже разделителя. Это самостоятельный промпт первого визуального прохода: 6 основных кадров и необходимые состояния.

Полное поведение сохранено в [спецификации дизайна](stitch-specification-en.md); оно применяется при детализации следующих проходов. Не вставляй все продуктовые правила в интерфейс. EN и PL генерируются отдельными наборами.

---

Design a new native iOS interface for **Narat**, an indoor plant care app. Direction: **Quiet Garden**. Replace the supplied text-heavy screens completely. Create product screens, not a landing page or marketing posters.

Generate a separate **English-only** frame set named Narat / Quiet Garden / EN. Every visible label, error, date and result must be natural English. Keep Latin species names. Do not place Polish translations beside English labels. The Polish set is generated separately with the same components.

## Design first

The user should recognise their plant and the next useful action before reading an explanation. Use real plant photography as the visual anchor; calm warm surfaces, generous whitespace, clear native controls and short everyday words. Inspiration: Planta's plant-and-task grouping, Botan's visual scenario choices, Greg's concise care list; Crouton (Apple Design Award 2024) for step-by-step focus, CapWords (2025) for photo-led interaction, Moonlitt (2026) for familiar platform interaction. Adapt principles; do not copy their branding, layouts or claims.

Do not turn product requirements into visible paragraphs. Business rules are behavior, not screen copy. Use three levels: glance → perform action → optional explanation. Never hide the condition needed to act safely, uncertainty, a relevant warning, or subscription charge/renewal terms behind “More”.

- 393 pt reference width, native safe areas and iOS navigation; also adapt to 320 pt and large Dynamic Type. Support iOS 17+. Use the system appearance appropriate to the OS; no decorative glass over reading surfaces.
- Warm background #F7F5EF, opaque surface #FFFFFF, text #202C24, secondary #626A61, action green #294D3C. Dark: #151C18 / #202A23, text #F0F3ED, secondary #B5C0B7, accent #B9D7A6 with dark text. Verify contrast.
- Semantic SF Pro: large title approximately 34 pt, section 22 pt, body 17 pt, supporting 15 pt, all scalable. Never fit content by shrinking text.
- 20 pt outer margins, 8 pt rhythm, 16–24 pt group spacing; photo corners around 24 pt. No nested card stacks. Keep text off photos unless a stable opaque backing ensures contrast.
- SF Symbols, accessible names, touch targets at least 44 × 44 pt. Keep labels on tab items and unfamiliar actions. Status must not rely on color. Include VoiceOver order and reduced-motion notes.
- One prominent primary action per focused state; keep secondary navigation quiet. No health scores, gauges, decorative charts, streaks, confetti, clinical jargon or dense dashboards.

## Generate only this first design batch

Create six connected frames. Do not generate all product features in the first pass. Use consistent photos, names, access state and task data.

**1. Today — returning user, two real tasks.** Large “Today”, one short count. The main task has a generous personal photo of a rubber plant, its name, “Check soil” and a clear button with that verb. The second task is a compact row: photo, Monstera, “Review leaves”, disclosure. Provide a modest “Help a plant” entry. Use the three labeled tabs Today / My Plants / Profile. No allowance meter, subscriptions, science explanations or duplicated page titles. Aim for about 25–45 visible words at default type size; this is a density guide, not a truncation rule.

**2. Soil-check sheet — opened from the first task.** Show the plant name, “Is the soil still damp?” and only the applicable short checking instruction from the supplied protocol. Offer “Still damp”, “Dry” and “Not sure”. A damp answer must not log watering. A dry answer shows the applicable watering instruction and a separate “Log watering” action only after the user actually waters. Confirmation offers Undo. Do not invent a universal checking depth, water volume or interval. Use a prototype annotation when the protocol fixture is missing; do not print internal implementation notes in the app.

**3. My Plants.** A quiet photo gallery with a two-column grid: photo, common name, at most one useful line such as room or next task. An obvious Add action. Use one column at large accessibility type sizes. No moisture percentage, lux, temperature, root-hydration score, diagnosis inferred from identification, or “Healthy / Thriving” defaults. Plant detail contains conditions and diary, rather than printing them on every tile. Do not add search/filter chrome to a tiny sample collection unless it solves a real need.

**4. First Help — free preliminary result.** A consistent photo of a Monstera with a yellowing lower leaf. Plain possible cause: “The soil may be staying wet.” One short basis: “Yellowing leaves + frequent watering.” Short uncertainty: “A photo cannot confirm the cause.” One relevant first step and its safety condition, then a Save plant CTA. A disclosure “Why this may help” holds supporting detail, alternatives and sources. Keep the result useful before sign-in or payment; saving opens sign-in when needed and preserves everything. Do not place this whole result inside nested report cards. Aim for roughly 45–70 words in the initial content, allowing necessary warnings and Polish expansion.

**5. Narat Plus — contextual, dismissible sheet.** An understated plant image or crop, short title, just three benefits: “100 photo analyses each month”, “Personal care and recovery plans”, “Care schedules for all your plants”. Two clear plan choices. Example local prices: PLN 199.99/year and PLN 49.99/month, formatted for the chosen language. Full annual total must be prominent. Show the actual charge, renewal period and store-confirmed next billing date before confirmation. Trial variant only when StoreKit confirms eligibility: 7 days on annual, opt-in reminder off by default; otherwise no trial promise. Clear close, Restore purchases, Terms and Privacy. No countdowns, default reminder permission or invented discounts. Cancellation returns to the original free result. Do not offer free diary or monthly reports as paid benefits.

**6. Today — nothing scheduled.** Calm plant imagery and “No tasks for today”. Keep the collection and Help entry accessible. No fake tasks, guaranteed health, gamified daily streak or upsell to fill the space.

Link Today → soil check → damp / dry / uncertain result → explicit log → undo; My Plants → plant detail; Help result → save/sign-in; requested paid plan → Plus → close back to free result. Any supporting route needed for these links can be a lightweight sheet, not another dense dashboard. Explain missing backend behavior in design annotations, never by faking success.

## Guardrails for every frame

- Two equal first-use intentions: Help a struggling plant / Set up plant care. Within care, photo identification and catalogue are methods. Keep an EN/PL language selector before sign-in and in Profile.
- Existing three care questions only: light (low / bright indirect / direct / unknown), watering frequency (several times a week / about weekly / less often / unknown), drainage holes (yes / no / unknown). Optional clarification follows an analysis; never require a fourth profile question.
- Collection, diary and manual photos are unlimited Free. Only basic-care schedules are limited to three selected plants. A fourth plant can be saved free; changing selected plants keeps history. First aid is independent of the three slots.
- Saving, enabling care, checking soil, and recording actual watering are distinct actions. An applicable free first action creates one follow-up only after explicit completion and only when the reviewed protocol supplies it. No universal “3 days” promise.
- Before sign-in: one successful starter identification and one starter diagnosis, separate. Signed-in monthly Free allowance: one shared identification/diagnosis, starting the next UTC calendar month after first starter success; unused applicable starter comes first. Show actual mode allowance only at scan entry, not throughout the app.
- Paid/trial: 100 successful photo analyses per access month, including annual billing. Period begins at first confirmed access including trial; trial conversion, restore and plan change do not refill it. Technical failures do not consume success; usable uncertain results do. Follow-up AI is paid; manual comparisons and reports are free.
- Prior personal full plans remain readable after expiry, with applicability/safety checks; new full plans and premium tasks require access. Do not imply a subscription guarantees recovery.
- No invented telemetry, exact light measurements, confidence percentages, confirmed diagnosis, chemical advice, product names, weather adaptation, social feed, shop or expert chat. Use only supplied observations. Mark unknown data honestly.
- Report relevant failure/empty/loading states, preserve drafts, and never silently record care. Detailed edge cases belong in later design batches using the full behavior reference, not as prose on these six screens.

## Acceptance

The screens must visibly differ from the old text-heavy reference. A user can identify the next action from photo + short label; complete a check without accidentally logging watering; find a plant by photo; dismiss Plus; and understand the amount and billing period. Text remains readable in EN/PL and at larger sizes. Do not claim this concept is usability-tested.
