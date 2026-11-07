# Narat — полная спецификация поведения для дизайна (PL)

Сохранённая полная спецификация поведения, 2026-11-01. Новое визуальное направление — [Quiet Garden](design-concept.md). Для первой генерации используй [короткий промпт](stitch-prompt-pl.md). Этот документ нужен для последующей детализации: его список 22 групп не означает, что их нужно генерировать за один проход. При конфликте визуальной подачи приоритет у новой концепции; продуктовые правила не меняются.

---

Design a coherent, high-fidelity native iOS app named **Narat** for indoor plant owners in Poland. Create actual app interfaces, reusable components, and connected prototype flows, not a landing page, App Store screenshots, slide deck, or device mockup.

Generate this version entirely in natural **Polish**, including labels, errors, sample results, dates, and accessibility labels. Keep Latin scientific names. English phrases below describe the intended meaning: translate them naturally, never leave English fallback text inside Polish screens. Produce a separate frame set labeled PL with exactly the same components, actions, and states as the English version. Use Polish diacritics, sentence case, localized month/date forms, and Polish storefront formatting: **49,99 zł / miesiąc**, **199,99 zł / rok**, **7 dni bezpłatnie** only when eligible. Do not change the product rules during translation.

Preferred Polish UI wording (use natural inflections where needed):
- Today → Dzisiaj; My Plants → Moje rośliny; Profile → Profil.
- Help your plants thrive → Zadbaj o swoje rośliny.
- Help a struggling plant → Pomóż roślinie; Set up plant care → Ustaw pielęgnację.
- Identify with a photo → Rozpoznaj ze zdjęcia; Find in catalogue → Znajdź w katalogu.
- Confirm plant → Potwierdź gatunek; Choose another species → Wybierz inny gatunek.
- Living Room → Salon; Bedroom → Sypialnia; No Room → Bez pokoju.
- What light does your plant get? → Jakie światło dociera do rośliny?
- Low light → Mało światła; Bright, indirect light → Jasne, rozproszone światło; Direct sunlight → Bezpośrednie słońce; Not sure → Nie wiem.
- How often do you water? → Jak często podlewasz roślinę? Several times a week → Kilka razy w tygodniu; About once a week → Mniej więcej raz w tygodniu; Less than once a week → Rzadziej niż raz w tygodniu.
- Does the pot have drainage holes? → Czy doniczka ma otwory odpływowe? Yes / No → Tak / Nie.
- Estimate with camera → Oszacuj światło aparatem; Approximate estimate → Przybliżona ocena.
- More care details → Dodatkowe warunki pielęgnacji; Pot material → Materiał doniczki; Automatic calendar season → Automatycznie według kalendarza.
- Preliminary guidance → Wstępne wskazówki; Possible cause: soil staying too wet → Możliwa przyczyna: zbyt długo wilgotne podłoże.
- A little more detail may help narrow this down → Dodatkowy szczegół może pomóc zawęzić możliwe przyczyny.
- Save plant → Zapisz roślinę; Enable basic care → Włącz podstawową pielęgnację; Mark first action done → Oznacz pierwsze działanie jako wykonane.
- Check soil moisture → Sprawdź wilgotność podłoża; Check done → Sprawdzenie wykonane; Watered today → Podlano dzisiaj.
- No tasks due today → Brak zadań na dziś; Care needs review → Zalecenia wymagają przeglądu.
- Choose up to 3 plants for free basic care → Wybierz do 3 roślin do bezpłatnej podstawowej pielęgnacji.
- Basic reminders paused → Podstawowe przypomnienia wstrzymane; History kept → Historia zachowana.
- Waiting to sync → Oczekuje na synchronizację; Saved → Zapisano; Could not save → Nie udało się zapisać; Retry → Spróbuj ponownie; Undo → Cofnij; Skip → Pomiń.
- Overview / Diary / Photos / Analyses → Przegląd / Dziennik / Zdjęcia / Analizy.
- Improved / Unchanged / Worse / Not sure → Lepiej / Bez zmian / Gorzej / Nie wiem.
- Assess progress with AI → Oceń zmiany z pomocą AI; Time to review your plant → Czas sprawdzić stan rośliny.
- Monthly Progress Report → Miesięczne podsumowanie; Recorded care actions → Zapisane czynności pielęgnacyjne; What's next → Co dalej.
- Start 7-day free trial → Rozpocznij 7-dniowy okres próbny; Restore purchases → Przywróć zakupy; Manage subscription → Zarządzaj subskrypcją; Terms → Regulamin; Privacy → Polityka prywatności.

These translations guide prototype copy; final EN/PL release wording still needs language review.

## Product and visual direction

Help people understand a possible plant problem, take a useful first action, save individual plants, and follow appropriate everyday care. English support does not expand the approved treatment-product market beyond Poland. Follow the behavior below; do not invent features or claims to fill screens.

Use the supplied **Natural Tech** direction: quiet Nordic-botanical minimalism, clear hierarchy, natural plant photography, warm neutral surfaces, and restrained forest green.

- Target iOS 17+, a consistent 393 pt-wide reference canvas, native safe areas, navigation bars, sheets, pickers, and tab bars. Layouts must adapt to smaller supported iPhones and larger text.
- Light tokens: primary Forest Green `#1E3F20`, accent Sage `#4A7C59`, background `#F9FAF8`, surface `#FFFFFF`, primary text `#191C1A`, secondary text `#5C645D`, warning Amber `#D97706`.
- Dark tokens: background `#121413`, surface `#1C1F1D`, primary text `#E1E3DF`, secondary text `#8C938D`, primary action green `#2D5E30`. Adjust combinations for readable contrast; a palette token is not a guarantee that every text/background pairing works.
- Semantic SF Pro typography, Dynamic Type, 8 pt spacing rhythm, 16 pt card corners, approximately 24 pt sheet/pill corners, 14 pt custom button corners. Preserve familiar native control shapes.
- Minimum 44 pt interaction targets, meaningful icon/accessibility labels, visible selected/disabled/focus states, and status conveyed by text as well as color. Large accessibility text must wrap or scroll without clipping essential actions. Include reduced-motion annotations.
- One clear primary action per state. Distinguish navigating, saving, enabling care, and recording care actually performed. Avoid excessive nested cards, neon gradients, decorative health scores, gamification, and alarming red everywhere.
- Design all flows in light mode plus representative dark-mode variants for Today, First Help, Plant Detail, Paywall, and Progress Report, using shared semantic components.

Use three main tabs: **Today**, **My Plants**, **Profile**, localized for this version. Provide an obvious add action in My Plants and a help entry on Today. Camera, onboarding, and questions use focused flows without the tab bar. Returning users open Today; unfinished drafts can resume. Opening the app never requires a paywall.

The released MVP supports English and Polish from day one. Include a language selector before sign-in and in Profile. Initial language follows the first supported device preference, otherwise English. Language changes preserve input and access; historical analyses/plans keep their creation language, visibly labeled. Do not generate mixed-language screens or automatically translate historical results.

Use a consistent example throughout the problem flow: **Monstera / Monstera deliciosa**, one individual plant in **Living Room**, with a personal photo showing a yellowing lower leaf. Localize common names/rooms. Keep photos, dates, history, access state, and remaining quota consistent across connected frames. Different plants of the same species remain separate individuals.

Example care text is illustrative prototype content, not a verified prescription. Real recommendations come from a reviewed, versioned knowledge base. Do not invent pesticide brands, doses, treatment intervals, toxicity facts, or observations the user never supplied. Missing information stays unknown. Keep this implementation explanation in handoff notes, not the consumer interface.

## Mandatory access rules

### Photo analyses

- Before permanent sign-in: **one successful starter identification and one successful starter diagnosis**, tracked separately. Using one does not consume the other.
- For a signed-in Free account: **one shared successful identification or diagnosis per calendar month UTC**, without rollover, beginning in the month after the first successful starter analysis. An unused starter for the requested mode is used before that month's Free allowance. Monthly Free is not granted merely by registration or subscription expiry.
- Before a scan, show the actual allowance for that mode and next renewal date in plain language. Catalogue search remains available without a photo or scan allowance. Distinguish a running/reserved attempt from an exhausted allowance.
- Active subscription or subscription trial: **100 successful photo analyses per month**, shared by identification, diagnosis, and AI progress assessment. This remains monthly on the annual plan; it is not 100 per billing year or per trial.
- The paid monthly period starts at the first confirmed access, including trial. Trial→paid, restore, and a plan change do not refill it. Free allowances are not added on top while paid access is active.
- Technical failures and reopening an existing result do not use another successful attempt. A usable but uncertain result still uses its attempt; low confidence does not promise unlimited free retries.
- AI assessment of a follow-up photo requires paid access and uses the same monthly pool. Saving photos/observations, manual photo comparison, clarification answers, reports, and plans built from existing information use no photo analysis.

### Care and history

- Collection, plant cards, diary, and personal photos are **not limited to three plants**.
- Free basic care includes conditional soil checks, recurring checks, reminders, and history for up to **three selected individual plants**, after either catalogue or photo identification. No extra AI call is needed.
- A fourth plant can be saved for free. Enabling its basic schedule requires changing the selected three or subscribing. Selection may contain fewer than three, including none; history is never deleted to enforce the limit.
- Paid access enables basic care for any number of plants, new full routine/recovery plans, and applicable advanced feeding, repotting, treatment, and progress tasks.
- After saving a problem result, an applicable first action can be recorded for free, creating **one linked control task only when a reviewed protocol provides a suitable check**. It occupies no basic-care place. No universal 3-day/5-day follow-up promise; timing and signs come from the actual protocol. Missing action/timing has an honest explanation.
- Saving a plant does not mean it was watered, its first action was performed, or care was enabled. Show tasks as saved only after confirmation.
- After expiry/refund, earlier personal full plans, including trial plans, remain readable with date, version, original language, and applicability. New full plans, full-plan updates, and new advanced tasks require access. The free three continue basic care.
- Existing tasks and history remain available. Removing a plant from Free selection pauses its automatic basic reminders while preserving old records. Re-enabling checks current conditions/history and never marks missed care performed.
- Outdated or withdrawn instructions are blocked independently of payment, including in cached plans. Reading an old plan does not prove it still applies.

### Subscription

- Two products only: **PLN 49.99/month without trial**; **PLN 199.99/year with an optional 7-day trial only when the store confirms eligibility**. Use the actual localized storefront price; do not imply fixed currency conversion for other regions.
- Eligibility is not the same as being a new app user. Ineligible or unknown eligibility must not show a guaranteed trial. Confirmed store state determines access and billing dates.
- Before confirmation show full charge, billing period, renewal terms, and trial-end/next-charge date when applicable. Annual total must be at least as prominent as any monthly equivalent. No invented discount or urgency countdown.
- Trial is voluntary. A reminder 24 hours before the confirmed trial end is opt-in, off by default. Denied notifications do not hide the date; delivery is not guaranteed.
- Paywalls follow a requested paid extension after free value. Dismissal preserves the result and free next action. Verified purchase resumes the requested action after applicability is rechecked; treatment still needs explicit start.
- Unlimited plants in care does not mean unlimited analyses. Free monthly reports, diary, and manual photo comparison are not paid benefits.

## Complete prototype routes

**Problem help:** Welcome/Add intention → one photo → three care questions → analysis loading → preliminary first help → optional clarification when indicated → result → sign-in to save → review and confirmed save → explicitly record first action → free control/observation/optional photo → Today/diary. Skipping clarification preserves preliminary help.

**Routine care:** Welcome/Add intention → photo identification or catalogue → identify/search → confirm species or retain uncertainty → the same three questions → sign-in to save → review and confirmed save → explicitly enable basic care or choose the free three → Today. Identification alone never gives a diagnosis or declares health.

**Paid extension:** Applicable full-plan/advanced-care request or a scan without available Free allowance → contextual paywall → verified purchase/trial → resume requested action. Cancel/pending/error grants no false success. Missing species/profile/protocol is explained before asking payment for an unavailable plan.

**Repeat use:** Today ↔ My Plants ↔ plant detail/diary; Profile manages access/preferences. A completed-month report opens from collection/diary and links to real plants/tasks. Recovery→routine requires reviewing current condition and explicit confirmation; completed tasks never automatically mean recovery.

Developer annotations only: diagnosis/follow-up may request at most two suitable Yes/No questions if top score <0.80 **or** the top-two gap <0.10. These are routing thresholds, not calibrated health probabilities. Never display numeric confidence/thresholds in consumer UI. Clarification occurs after analysis, not directly after the care questions.

## Screen groups and variants

Create the following **22 groups**, with reusable sheets and state variants where appropriate. Do not compress this into ten isolated screens. If generated in batches, use A: 01–09, B: 10–16, C: 17–22 and carry the same component library and fixture data across all batches.

### 01. Welcome, language, and intention

Headline: “Help your plants thrive.” Two equally prominent choices: “Help a struggling plant” and “Set up plant care.” Explain the difference without assuming illness. Include language selection and an existing-account sign-in link. First result needs no account/payment; permanent saving requires sign-in. Reuse intentions for later additions. No compulsory payment or long onboarding before help.

### 02. Care method, catalogue, and species confirmation

Separate “Identify with a photo” and “Find in catalogue.” Show mode-specific scan access before the photo route. Catalogue supports common/scientific names and synonyms, no-results and missing-profile states, and source/image attribution. Do not pass catalogue images off as personal diary photos.

Identification shows tentative species and “Confirm plant” / “Choose another species,” plus unknown/out-of-scope and catalogue fallback. No disease or “healthy” claim from identification alone. Confirming a species leads to care questions. Let a new analysis attach to an existing plant or create a separate individual without merging by species.

### 03. Camera, gallery, and one-photo review

Viewfinder, subtle framing guide, shutter/gallery/close. Problem guidance: “Show the plant and the visible symptom clearly.” Identification: “Show the plant clearly.” Require **one** photo, not a full-plant shot plus a separate close-up. Review: “Use photo” / “Retake.” No premature diagnosis overlay.

Include camera denied/gallery fallback, unsuitable/unreadable photo, replacement, and preparation states preserving other input. Readable large originals are prepared automatically, not rejected merely for exceeding 10 MB. Lighting estimation belongs in question 1, not a mandatory camera step.

### 04. Three care questions and optional conditions

One reusable screen in three variants: progress “1 of 3 / 2 of 3 / 3 of 3,” back, selected answers, continue, optional photo thumbnail. Preserve input on back. Exact concepts/options:

1. “What light does your plant get?” — Low light / Bright, indirect light / Direct sunlight / Not sure.
2. “How often do you water?” — Several times a week / About once a week / Less than once a week / Not sure.
3. “Does the pot have drainage holes?” — Yes / No / Not sure.

Watering frequency is not the last watering date; actual-date correction belongs in care history. Drainage is not pot material. Do not mix terracotta/no holes/self-watering into a single answer list.

An optional disclosure within existing steps offers pot material: Terracotta / Plastic / Glazed ceramic / Other / Not sure; season: Automatic calendar season / Summer / Winter. No fourth required step, weather adaptation, or inferred heating/material. Explain automatic season as a calendar assumption.

### 05. Approximate lighting estimate

From question 1: “Estimate with camera.” Sheet with qualitative approximate result, manual correction, explicit “Use this estimate,” and skip. Distinguish confirmed answer, camera estimate, and unknown. No lux meter, precision/ambient-sensor promise, or all-day-light measurement. Failure leads to manual selection; nothing is applied silently.

### 06. Loading, running analysis, and failure

“Identifying your plant…” before care species confirmation; “Analyzing your photo and answers…” after problem questions. Care questions do not launch another scan. Indeterminate progress without fake percentages, completed stages, or a disease finding.

Include still-running, technical failure, timeout, retry, preserved photo/answers, and explanation that failure did not use a successful attempt. Reopening a running result does not launch a second call. In annotations only, the project targets 95% within 30 seconds and a terminal outcome by 60 seconds; do not promise instant universal results in consumer copy.

### 07. Free preliminary result

Near the top show photo, tentative species, likely cause, actual evidence, limitation, first action, and its reason. Illustrative heading: “Possible cause: soil staying too wet.” Evidence may cite the visible yellowing leaf and a genuinely supplied answer, never fabricated “soil wet for 7 days,” root damage, or unseen pests.

Illustrative action: “Check the soil before watering,” explained conditionally. A photo does not confirm root condition. Label “Preliminary guidance,” not “Diagnosis confirmed” or “Root issue detected.” Include likely issue, no obvious issue visible, insufficient evidence, and unsupported species/problem variants. No obvious issue does not prove health.

Primary: “Save plant.” Secondary: “View full recovery plan,” contextual, without covering free help. Explain that recording an applicable first action after saving may add a protocol-based control. Do not invent a control date or claim the task already exists.

### 08. Optional diagnostic clarification

One appropriate approved-content question at a time, maximum two. Copy: “A little more detail may help narrow this down.” Yes / No / Skip; no promise to confirm the diagnosis. Unresolved, contradictory, or skipped answers preserve uncertainty and safe first help.

Question content must fit the example; do not fabricate a symptom to force a conclusion. Do not always promise a second question. Answers require no new photo/AI/quota; accepted/pending answers survive back/restart/sign-in with honest saved/retry status. No disease clarification for identification-only results.

### 09. Sign-in, review, and save

On permanent save, show Apple/Google sign-in. Cancelling returns to the result or care draft without loss. Review species/unknown, personal photo if present, optional nickname, actual conditions, optional room, “No room,” and create-room. Catalogue plants can save without a photo.

Distinguish user answers, confirmed camera estimates, and unknowns. Correcting species/conditions labels the old result “Based on earlier information”; it neither reruns analysis nor automatically updates a full plan. Room/name changes do not imply diagnosis changes.

Separate Saving / Saved / Could not save — Retry. Repeated taps do not duplicate plants. Include expired-guest-draft restoration from available local data without another scan and a partial-data fallback. Keep technical tokens, receipts, TTL, and revisions out of UI.

### 10. Post-save next step

Confirm the saved plant, then offer one actual next action:
- Problem: “Mark first action done,” or “Open control” if already created. Dates only when supported and established.
- Care: “Enable basic care,” with available free places, or “Choose your three plants.” A fourth plant is already saved.
- Missing data/profile/control: explain and offer “Review plant details.” Do not sell an unavailable plan.

Paid extensions remain secondary explicit requests. Include pending/failure when enabling care. A save-success checkmark is not a watering/treatment completion. Verified purchase returns to the requested applicable action.

### 11. Today and task details

Actual date/count, separate overdue/today groups, plant image/name/room, accessible action. “Check soil moisture” is conditional, not an unconditional watering alarm. Labels match facts: “Check done” for an actual check; “Watered today” only when watering was performed. Checking damp soil must not record watering.

Detail shows condition/action/date and “Why did this date change?” with old/new dates and cause. Include completion, undo, past actual-date correction, and postponing a basic check without recording care. No arbitrary chemical-treatment rescheduling outside reviewed instructions.

Show Waiting to sync / Saved / Could not save — Retry; offline actions stay pending. “Care needs review” permits recording actual care/undo while outdated instructions are not shown as current. Never display `check_soil_first` or `needs_review` as consumer badges.

### 12. Empty Today and return after a break

“No tasks due today,” with next real check when known or an explanation of no active schedule. No “All plants cared for” or inferred good health. Link to plant detail.

After a break, ask about actual care and dates, including “Not sure.” Preserve overdue history. No automatic completion, reset of all dates to today, or catching up missed treatments back-to-back. Tasks remain accessible with notifications disabled.

### 13. My Plants and room management

Photo-led collection/search, room filters All / Living Room / Bedroom / No Room, add action, monthly-report entry. Personal-photo and no-photo variants; neutral placeholder instead of invented diary content. Empty collection offers both intentions/catalogue.

Truthful labels: “Basic care active,” “Basic reminders paused,” “No schedule yet.” Fourth plant stays visible and usable. Room create/rename/delete sheets explain that deleting a room keeps its plants and history under No Room.

### 14. Free basic-care selection

“Choose up to 3 plants for free basic care.” All plants/photos/history stay saved; only automatic basic care is limited. Independent checkboxes, count, save, secondary paid extension. Do not use radio buttons for multi-selection.

Select a new fourth plant and deselect an old one in a single confirmation; allow fewer than three or none. Explain excluded basic reminders pause without deleting history. Include pending/success/retry and selection-changed-on-another-device state.

During paid access this is the preference for after expiry, not a restriction on current unlimited care. Preserve the previous selection or explain default first three by activation order when no choice exists. Explicit empty selection stays empty. Re-enabling checks current conditions without marking missed care completed.

### 15. Plant detail, diary, photos, and safety

Photo/nickname/species/room/edit, clear Overview / Diary / Photos / Analyses sections. Show next existing task, conditions, basic-care status, current/historical plans. Catalogue-only plant has an honest empty Analyses state.

Diary distinguishes actual care dates from later recording where relevant. Include undo/date correction, editing species/conditions without losing history, selecting one's diary photo as main, and saving one's photo to the phone. Do not add arbitrary custom events or bulk export.

Pet safety distinguishes cats/dogs, species/source/unknown; missing data is not safe and pet data does not imply child safety. Make catalogue/image credits reachable. Do not invent toxicity claims for the sample plant.

### 16. Free first-aid control

Same individual plant, recorded first action, protocol-supported timing, observable signs, optional photo-angle guidance. Observation choices Improved / Unchanged / Worse / Not sure; optional note/photo. These are user observations, not an AI diagnosis or declaration of recovery.

Saving is free, with no scan or basic-care place used. “Assess progress with AI” is separate, explicit, paid, with allowance shown first. Include undo/date correction and retry: adjust the same control, do not duplicate it; undo of the first action pauses the pending control reminder. Explain absent timing instead of inventing a task. Full treatment must not automatically repeat an equivalent action already recorded.

### 17. Basic, full, recovery, and historical plans

Distinct Basic care / Full routine care / Recovery plan. Basic: soil checks/reasons. Full routine: applicable feeding/repotting/advanced checks, without disease claims. Recovery: preliminary cause, reasons, applicability, urgency/contagiousness only if supported (otherwise unknown), duration, ordered finite steps, check criteria.

New full plans need access and applicable data; no extra scan for a plan built from existing information. Generating/error/retry/missing-profile/context-changed states. Explicit “Start treatment,” start date, and one verified applicable option when needed; no invented brands/doses or mixing alternatives. A planned timeline is not completed care.

Earlier personal plans remain readable after trial/expiry/refund with date/version/original language/applicability. Preserve historical context while blocking outdated/withdrawn instructions. Updating or creating full plans may be paid; reading one's existing plan is not.

### 18. Recovery review and photo comparison

After steps finish: “Time to review your plant,” never “Plant cured.” Check current state before explicitly transitioning to appropriate routine/basic care. Worse/unchanged/unknown offers condition review and an optional analysis under actual access; no hidden AI or automatic repeat treatment.

Transition reconciles tasks and Free places without losing history. No available place → selection before schedule changes. Paid AI comparison shows same plant's prior/current photos and dates, context, allowance, and limitations for incomparable photos. Manual comparison stays free; checked tasks/photos alone do not prove improvement.

### 19. Contextual paywall and purchase states

Recovery, expanded-care, and scan-allowance variants share components. Always show close and available Free continuation. Benefits: applicable new full plans/advanced care, any number of plants in basic care, 100 successful monthly analyses including AI follow-up.

Two product cards with the approved Polish storefront amounts. Eligible annual: optional 7-day trial, next full annual charge/date, opt-in 24-hour reminder off. Ineligible: immediate annual payment, no trial promise. Monthly: immediate monthly payment, no trial. CTA follows the selected product and eligibility.

Show renewal terms, Restore purchases, separate Terms/Privacy links, subscription management. Disabling auto-renew does not end confirmed access early. Include pending/cancelled/failed/verified success, restore success/no purchase, purchase linked to another app account. No foreign data disclosure or silent ownership transfer. Success resumes the request, not a falsely completed plan.

### 20. Allowances and access changes

Readable sheet showing separate starter modes; Free monthly allowance/renewal for eligible signed-in Free; or paid monthly pool/renewal during Trial/Paid. No implementation ledger or financial dashboard.

Variants: one starter used/other available, Free month not yet started, last attempt processing, Free exhausted, paid quota exhausted while other care remains active, trial→paid without refill, expiry with old plans readable and Free three continuing. Catalogue/history stay reachable where applicable.

### 21. Free monthly Progress Report

Completed **local calendar month**, from collection/diary, accessible without a notification. Clear period label distinct from UTC scan allowance. Only actual recorded care, existing photos/observations, and separate current “What's next” tasks.

Use “Recorded care actions,” not “Plants saved,” growth/health scores, inferred recovery. Undo/date corrections update counts. Missing entries do not prove no care. Full/partial month, no records, and no photos variants with explicit limitations; photos not required.

Free in every access state, no AI/scan use. Optional notification off by default, at most once per report month; timezone changes/reopening do not repeat it. Offline cached date and pending changes distinguished from confirmed totals. Links open real plant/task; only a subsequent paid request opens a paywall. No revenue/retention/funnel charts in the consumer report.

### 22. Profile, notifications, sign-out, deletion

Account, EN/PL selector, access/trial status and confirmed dates, allowances, manage/restore subscription, sign out, delete account. No previous owner's plants/photos/reports/reminders after account switching.

Care reminder local time defaults to 09:00 with integer-hour choice 00–23. Separate care/trial-end/monthly-report preferences. Ask notification permission contextually; show denied/revoked settings routes. Keep tasks/dates/reports accessible without push and do not guarantee delivery.

Confirm plant/account deletion with clear consequences/cancel. Deleting an account does not cancel App Store subscription; offer its management route. Normal reversible care actions use undo, not unnecessary confirmation dialogs.

## Components, handoff, and completion checks

Provide reusable typography/color tokens, buttons, answer tiles, task rows, plant cards, status banners, allowance summaries, plan access labels, subscription cards, report summaries, sheets, and empty/error/offline/pending/confirmed states. Include core dark/accessibility variants.

Frame labels outside the app canvas include screen number, branch, language, access/state. Connect primary/secondary/back/close/skip/retry/cancel. If a live behavior cannot be simulated, annotate it rather than claiming it works. Keep API names, thresholds, access enums, UUIDs, receipts, revisions, and sync internals out of consumer copy.

No weather adaptation, AI-generated monthly report, automatic cure, chatbot, marketplace checkout, Android, social features, shared-household care, numeric health scores, or guaranteed diagnosis.

Verify these complete prototype paths:
1. Guest problem → photo/questions → help/optional clarification → cancelled/successful sign-in/save → explicit first action → free control.
2. Identification and catalogue → confirm species/questions/save → Free basic care, with no photo/room and missing-profile variants.
3. Fourth plant saved → atomic Free-selection replacement → history retained/basic reminders paused.
4. Free value → paid request → dismiss/eligible/ineligible/pending/error/verified purchase → requested context restored.
5. Today → actual check/care/undo/date correction/postpone → pending/retry/next task; empty day/return after break.
6. Trial→paid without refill → expiry → existing plans/safety/Free three, no new advanced task without access.
7. Recovery review → worse/unknown or explicit routine transition without automatic recovery/repeated treatment.
8. Completed-month report → corrected/undone history/missing data/photos/timezone/offline/account change → real plant/next task.

Deliver connected flows and a coherent reusable system, not just attractive isolated screens. Generating mockups does not verify production integrations, accessibility testing, or horticultural accuracy.
