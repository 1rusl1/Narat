# Narat — Промпт для Stitch: Готовые маркетинговые скриншоты App Store (`1320 × 2868` PNG)

Этот промпт написан специально для того, чтобы **Stitch сразу генерировал готовые ASO-постеры App Store** (а не просто «голые» экраны приложения), соблюдая правильные пропорции конкурентов:
- **Верхние 25–28% холста** — просторная шапка и **огромный двустрочный заголовок** во всю ширину экрана (крупный кегль, читаемый даже в мелкой превью-выдаче App Store).
- **Нижние 72–75% холста** — корпус iPhone, уходящий за нижний край, и **выпрыгивающие за рамки телефона (pop-out) крупные карточки выгод**.
- **Фотографии в высоком разрешении (High-Res Macro)** — чёткие, детальные студийные/интерьерные снимки листьев без мыла и пикселизации.
- **Единый визуальный стиль Narat на всех 6 скриншотах** — глубокий лесной фон (`#244D3C`), кремово-белые заголовки (`#F7F6F0`), шалфейные плашки (`#E8EFE5`) и терракотовые акценты симптомов (`#C85A3B`).

---

## Шаг 1. Промпт для Stitch (English — 6 готовых ASO-скриншотов)

Скопируйте блок ниже целиком и отправьте в **Stitch**:

```markdown
Design a cohesive set of 6 high-converting iOS App Store marketing screenshots (ASO posters) for **Narat**, an indoor plant care and symptom-diagnosis iOS app.

### 1. Canvas Size, Export Resolution & Vertical Proportions (CRITICAL)
- **Target Resolution**: `1320 × 2868 px` (iPhone 6.9" App Store Connect mandatory portrait size, aspect ratio `9:19.5`, or `440 × 956 pt` @3x PNG export).
- **Strict Vertical Layout Split on ALL 6 Screens**:
  - **Top 26% of Canvas (Header Zone)**: Generous top margin + a **MASSIVE 2-line marketing headline** occupying 88–92% of the canvas width. The headline must be ultra-bold (`SF Pro Display Heavy/Black`, `42–46 pt` / `130–140 px` at 3x, tight line-height `1.04`, letter-spacing `-0.03em`) so it is immediately readable in small App Store search thumbnails.
  - **Bottom 74% of Canvas (Device & Pop-Out Zone)**: A sleek dark-bezel iPhone 16 Pro Max frame centered horizontally (`84%` of canvas width), starting at `26%` from the top and extending past the bottom edge of the canvas (occupying ~72% of the screen height, never 80%+).
  - **Floating Pop-Out Card Layer**: Every screen features **1 oversized floating UI card (`93%` of canvas width)** that breaks OUTSIDE the left and right edges of the iPhone bezel with a deep, realistic elevation shadow.
  - **Zero Small Text Rule**: Do NOT include paragraphs, tiny captions, or cluttered UI chrome. Every label, badge, and button inside the phone and pop-out cards must be oversized, bold, and scannable at a glance.

### 2. Unified Visual Style & Color Palette (Identical Across All 6 Screens)
Use the exact same background, headline color, and card styling on ALL 6 screens so the gallery looks like one unified brand:
- **Outer Canvas Background (All 6 Screens)**: Rich Deep Forest Green botanical gradient (`#2E614C` at top → `#244D3C` in middle → `#183529` at bottom) with subtle, soft organic Monstera leaf silhouettes in Pale Sage (`rgba(232, 239, 229, 0.08)`).
- **Top Marketing Headline Color (All 6 Screens)**: Warm Ivory `#F7F6F0` with a soft dark-forest drop shadow (`rgba(8, 24, 17, 0.35)`).
- **Inside Phone Screen Background**: Warm Ivory `#F7F6F0`.
- **Floating Pop-Out Cards & Inner Cards**: Pure White `#FFFFFF` with `20 pt` (`60 px`) rounded corners, subtle `#E4E7E0` border, and deep drop shadow (`0 24px 60px rgba(8, 24, 17, 0.42)`).
- **Primary Brand & Button Color**: Deep Forest Green `#244D3C` with Warm Ivory `#F7F6F0` text.
- **Supportive Pills & Badges**: Pale Sage `#E8EFE5` fill with Deep Forest `#244D3C` text.
- **Symptom / Alert Accent Color**: Warm Terracotta `#C85A3B` (solid) and Soft Terracotta `#F9EAE4` (tinted surface with `#A8462B` text).
- **Card Typography Colors**: Dark Charcoal `#202923` for titles, Muted Sage Grey `#53635A` for subtitles.
- **Photography Quality**: Use **ultra-sharp, high-resolution, crystal-clear macro and natural indoor photography** of real houseplants (sharp leaf veins, natural lighting, crisp focus, zero blur or pixelation).

---

### Screen 1: Instant Symptom Scan & First Help
- **Top 2-Line Headline**:
  `Yellowing Leaves?`
  `First Help`
- **Inside the iPhone Frame (Bottom 74%)**:
  - Full-bleed, **crystal-clear high-resolution close-up photo** of a real indoor *Monstera deliciosa* (or *Ficus lyrata*) leaf with a realistic yellowing lower section and sharp water droplets.
  - Four clean white rounded camera viewfinder corners framing the leaf.
  - Centered over the yellowing leaf area: a bold circular Terracotta (`#C85A3B`) target ring with a triangle `!` icon inside and a large Terracotta pill attached to the bottom of the ring reading **`Overwatering`**.
  - At the bottom of the phone screen: a clean dark camera shutter bar with a large central shutter button (Forest Green `#2E644E` center), left icon **`Photos`**, right icon **`3 Questions`**.
- **Floating Pop-Out Card (Breaking outside the phone bezel above the camera bar)**:
  - Left: Soft Terracotta rounded square (`#F9EAE4`) with a bold Terracotta first-aid kit icon (`#C85A3B`).
  - Middle: Large bold title **`Waterlogged Soil`** and subtitle **`Check soil 5 cm deep`**.
  - Right: Large pill CTA button in Deep Forest Green (`#244D3C`) reading **`Save`**.

---

### Screen 2: Step-by-Step 14-Day Recovery Plan (Before / After)
- **Top 2-Line Headline**:
  `Step-by-Step`
  `Recovery Plan`
- **Inside the iPhone Frame (Bottom 74%)**:
  - Top half of phone screen: A **high-resolution split Before / After photo comparison** of a houseplant leaf. Left half shows a yellowing, drooping leaf with dark pill **`Before`**; right half shows a vibrant, glossy healthy green leaf with dark pill **`After`**. In the center: a vertical white divider line with a circular slider handle (`↔`).
  - Below the photo: Bold heading **`Overwatering Risk`**, short bold subtitle **`Pause watering now & let the top 5 cm of soil dry out.`**, and section label **`Symptoms & First Steps`**.
  - At the bottom of the phone screen: Full-width Deep Forest Green (`#244D3C`) rounded pill button **`Start 14-Day Recovery Plan`**.
- **Floating Pop-Out Card (Breaking outside the phone bezel over the middle-lower section)**:
  - A bold `2 × 2` grid of 4 oversized rounded status pills (no small text):
    1. Top-left (Solid Terracotta `#C85A3B`, white text): **`✓ Yellow leaves`**
    2. Top-right (Soft Terracotta `#F9EAE4`, `#A8462B` text): **`✓ Wet soil`**
    3. Bottom-left (Solid Forest Green `#244D3C`, white text): **`✓ Pause watering`**
    4. Bottom-right (Pale Sage `#E8EFE5`, `#244D3C` text): **`✓ Check in 14d`**

---

### Screen 3: Smart Conditional Watering Reminders
- **Top 2-Line Headline**:
  `Set Smart`
  `Reminders`
- **Inside the iPhone Frame (Bottom 74%)**:
  - Top of phone screen: Clean weekly calendar strip (`Sun 6`, `Mon 7`, **`Tue 8`** highlighted in a Deep Forest Green `#244D3C` circle, `Wed 9`, `Thu 10`, `Fri 11`, `Sat 12`).
  - Below the floating pop-out card: A clean white card titled **`🌿 Soil Check & Care`** listing 3 plants with sharp high-res square photo thumbnails, bold names, room labels, and Pale Sage **`Complete`** buttons:
    - **`Fiddle-leaf fig`** • `Bedroom`
    - **`Peace lily`** • `Balcony`
    - **`Snake plant`** • `Office`
  - Bottom of phone screen: Clean 4-item iOS tab bar (`Schedule` active in `#244D3C`, `Diagnose`, `Find Plant`, `My Plants`).
- **Floating Pop-Out Card (Breaking outside the phone bezel right below the calendar strip)**:
  - Top row of card: Droplet icon + bold title **`Water`** on the left, and a Pale Sage (`#E8EFE5`) badge **`If top 5 cm dry`** on the right.
  - Main row of card: High-resolution square photo of **`Monstera`** in a terracotta pot + bold title **`Monstera`** (`Living room`) on the left, and a large Deep Forest Green (`#244D3C`) **`Complete`** pill button surrounded by celebratory confetti rays on the right.

---

### Screen 4: Photo Identification & 300+ Species Catalogue
- **Top 2-Line Headline**:
  `Identify &`
  `Care Plants`
- **Floating Pop-Out Card (Placed in the upper-middle zone right below the headline, breaking outside the phone width)**:
  - Top row: Sharp high-resolution square photo of a blooming **`Peace lily`**, bold title **`Peace lily`**, italic subtitle *`Spathiphyllum wallisii`*, and Pale Sage badge **`✓ Likely Match`** on the right.
  - Bottom row inside pop-out card: A Pale Sage (`#E8EFE5`) callout box with a `#244D3C` border reading: **`Care rule: Check soil 5 cm deep first — water only when the top layer feels dry.`**
- **Inside the iPhone Frame (Below the pop-out card)**:
  - Search bar pill at top: **`🔍 300+ Indoor Plants Catalogue`**.
  - Two large, lush, high-resolution botanical photo cards stacked vertically with dark bottom gradient overlays, bold white titles, and circular Deep Forest Green (`#244D3C`) **`+`** buttons:
    1. **`Monstera deliciosa`** — `Swiss Cheese Plant` (sharp macro Monstera leaf photo)
    2. **`Ficus elastica`** — `Rubber Plant` (sharp glossy Rubber Plant photo)

---

### Screen 5: Tailored to Your Room (3 Quick Questions)
- **Top 2-Line Headline**:
  `Tailored to`
  `Your Room`
- **Inside the iPhone Frame (Bottom 74%)**:
  - Top badge in Pale Sage (`#E8EFE5`): **`3 Quick Questions`**.
  - Large bold question heading: **`What light does your room get?`**
  - Option 1 card (unselected): Cloud icon + **`Low Light`** (`Shaded room or far from window`) + radio circle.
  - *(Space for the floating Pop-Out Card in the middle)*
  - Option 3 card (unselected): Sun icon + **`Direct Sun`** (`Bright south-facing window`) + radio circle.
  - Helper card in Deep Forest Green (`#244D3C` fill, white text): Camera icon + **`Check Light with Camera`** (`Instant room light estimate`) + `→` circle.
  - Two Pale Sage summary chips: **`✓ Pot with drainage`** and **`✓ Watered 5 days ago`**.
  - Bottom full-width Deep Forest Green (`#244D3C`) CTA button: **`Continue →`**.
- **Floating Pop-Out Card (Breaking outside the phone bezel in the middle of the options list, with a bold `#244D3C` border)**:
  - Left: Pale Sage icon box (`#E8EFE5`) with sun-behind-cloud icon + bold title **`Bright Indirect`** (`Near window, no harsh sun`) + Deep Forest Green pill **`✓ Optimal for Monstera`**.
  - Right: Large circular Deep Forest Green (`#244D3C`) checkmark **`✓`**.

---

### Screen 6: Personalized Plant Care Schedule & Diary
- **Top 2-Line Headline**:
  `Plant Care`
  `Schedule`
- **Inside the iPhone Frame (Bottom 74%)**:
  - Top hero card: High-resolution photo of **`Fiddle Leaf Fig`** (*`Ficus lyrata • Living Room`*) with dark bottom gradient overlay and large white title.
  - Segmented pill bar in Pale Sage (`#E8EFE5`): `Rooms` | **`Care`** (active in `#244D3C`) | `History`.
  - White summary card: **`Personalized Room Care Plan`** (`Adapted to your light, pot & watering`) with a circular **`100%`** progress ring in `#244D3C` on the right.
  - Section header: **`Plant care`** with a gear icon.
  - Below the floating pop-out card: Two clean white task cards:
    - **`Follow-Up Photo Check`** (`Need today` in `#C85A3B`) + camera action ring.
    - **`14-Day Recovery Check`** (`In 3 days` in `#244D3C`) + checkmark ring.
- **Floating Pop-Out Card (Breaking outside the phone bezel right below the "Plant care" heading)**:
  - Left: Bold title **`Check Soil Moisture`** and Terracotta subtitle **`Need today`** (`#C85A3B`).
  - Right: Large circular Terracotta action button (`#F9EAE4` fill, `#C85A3B` border, droplet icon inside) with a 3D tapping hand cursor **`👆`** clicking the button.
```

---

## Шаг 2. Промпт для перевода тех же 6 макетов на польский (`pl`) в Stitch

Когда Stitch сгенерирует английский набор, отправьте ему вторым сообщением этот промпт, чтобы получить идентичные макеты на польском языке:

```markdown
Now generate the Polish (`pl`) localized version of all 6 App Store marketing screenshots, keeping the exact same `1320 × 2868 px` proportions (top 26% huge 2-line headline, bottom 74% iPhone frame + floating pop-out cards), unified Narat Deep Forest Green & Sage palette (`#244D3C`, `#F7F6F0`, `#E8EFE5`, `#C85A3B`), and high-resolution plant photography.

Use these exact Polish strings:

1. **Screen 1**:
   - Headline: `Żółkną liście?` / `Pierwsza pomoc`
   - Target ring pill: `Przelanie`
   - Pop-out card: `Mokra ziemia` — `Sprawdź ziemię na 5 cm` — Button: `Ratuj`
   - Camera bar: `Zdjęcia` | `3 pytania`

2. **Screen 2**:
   - Headline: `Plan ratunku` / `krok po kroku`
   - Split photo labels: `Przed` | `Po`
   - Heading: `Ryzyko przelania` — `Wstrzymaj podlewanie i pozwól górnym 5 cm ziemi przeschnąć.`
   - Section: `Objawy i pierwsze kroki`
   - 4 Pop-out pills: `✓ Żółte liście` | `✓ Mokra ziemia` | `✓ Stop wody` | `✓ Kontrola 14d`
   - Bottom button: `Rozpocznij plan 14 dni`

3. **Screen 3**:
   - Headline: `Mądre` / `przypomnienia`
   - Week days: `Nd 6`, `Pon 7`, `Wt 8` (active), `Śr 9`, `Czw 10`, `Pt 11`, `Sob 12`
   - Pop-out card: `Podlewanie` | badge `Gdy 5 cm suche` | `Monstera` (`Salon`) | button `Gotowe`
   - Lower list (`Kolejne zadania`): `Fikus lirolistny` (`Sypialnia`), `Skrzydłokwiat` (`Balkon`), `Sansewieria` (`Biuro`) — buttons `Gotowe`
   - Tab bar: `Zadania`, `Diagnoza`, `Katalog`, `Rośliny`

4. **Screen 4**:
   - Headline: `Rozpoznaj` / `i pielęgnuj`
   - Pop-out card: `Skrzydłokwiat` (*`Spathiphyllum wallisii`*) | badge `✓ Dopasowano`
   - Tip box: `Zasada: Sprawdzaj ziemię na 5 cm — podlewaj tylko gdy górna warstwa przeschnie.`
   - Search bar: `Katalog 300 gatunków domowych`
   - Photo cards: `Monstera dziurawa` (`Monstera deliciosa`), `Fikus sprężysty` (`Ficus elastica`)

5. **Screen 5**:
   - Headline: `Dopasowane do` / `Twojego pokoju`
   - Badge: `3 szybkie pytania`
   - Question: `Jakie światło jest w pokoju?`
   - Option 1: `Słabe światło` (`Z dala od okna lub cień`)
   - Pop-out Option 2: `Jasne rozproszone` (`Blisko okna, bez ostrego słońca`) + pill `✓ Idealne dla Monstery`
   - Option 3: `Pełne słońce` (`Bezpośrednie promienie słoneczne`)
   - Camera card: `Zmierz światło aparatem` (`Szybka ocena światła w pokoju`)
   - Chips: `✓ Doniczka z odpływem` | `✓ Podlane 5 dni temu`
   - Button: `Dalej →`

6. **Screen 6**:
   - Headline: `Plan pielęgnacji` / `i dziennik`
   - Hero card: `Fikus lirolistny` (`Ficus lyrata • Salon`)
   - Tabs: `Pokoje` | `Opieka` (active) | `Historia`
   - Plan card: `Spersonalizowany plan opieki` (`Dopasowany do światła i doniczki`) — `100%`
   - Section: `Zadania pielęgnacji`
   - Pop-out card: `Sprawdź wilgotność ziemi` (`Na dzisiaj`) + 3D hand cursor `👆`
   - Lower cards: `Zdjęcie kontrolne liści` (`Na dzisiaj`), `Kontrola planu 14 dni` (`Za 3 dni`)
```
