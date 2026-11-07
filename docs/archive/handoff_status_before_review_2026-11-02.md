# Narat (iOS MVP) — Передаточный отчёт о статусе разработки (Handoff Summary)

**Дата фиксации**: 2026-11-02  
**Спецификация**: Конституция проекта `v3.0.0`, [`specs/001-plants-ios-mvp/tasks.md`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/specs/001-plants-ios-mvp/tasks.md)  
**Ветка / Workspace**: `/Users/ruslansabirov/Documents/ChatGPT/Plants`

## Обновление 2026-11-02 — T041

- Реализованы `NativeAuthService`, адаптеры Apple/Google и Supabase token exchange, public configuration и Google callback. T041 отмечена `[X]`.
- Перед native sign-in обязателен checkpoint/claim preparation callback; отмена/ошибка/успешный вход не очищают гостевой кеш. Очистка разрешена после confirmed claim/plant.create в T046.
- **Проверено заново:** полный `xcodebuild test` на iPhone 17 Pro / iOS 26.3: 21 тест без ошибок, включая 10 новых auth unit-тестов. Подробности и команда — [native-auth.md](validation/native-auth.md).
- Живой OAuth ещё не проверен: нужны публичные параметры Supabase/Google, включённые providers и Apple signing. `ios/Configuration/Auth.local.xcconfig` исключён из Git.
- **Следующая задача — T046:** `CollectionRepository` + `ClaimFlowModel`, checkpoint и proof до смены сессии, commit/poll и fallback после TTL. Экран входа подключать одновременно с этим сценарием, а не с пустым callback.
- Проверкой существующего клиента установлено: `AnalysisFlowModel.submitAnalysis` сейчас формирует демонстрационный результат локально. Живой серверный анализ/квоты/сохранение результата в клиенте не подтверждены, несмотря на прежнее описание Phase 3 как 100% готовой.
- Backend-задачи Phase 4 из исходного отчёта ниже не перепроверялись; их наличие не означает пройденную приёмку. T040/T042/T043/T045/T129/T131 не отмечать автоматически по этому отчёту.
- Актуальный дизайн: [Quiet Garden](../design/design-concept.md), промпты [EN](../design/stitch-prompt.md) / [PL](../design/stitch-prompt-pl.md). SwiftUI реализуется напрямую, Stitch не является зависимостью.

Исходный отчёт 2026-11-01 ниже сохранён для контекста; перечисленные там будущие действия сверять с этим обновлением и `tasks.md`.

---

## 1. Общий прогресс по фазам

| Фаза | Задачи | Статус | Проверка / Верификация |
| :--- | :--- | :---: | :--- |
| **Phase 1: Setup** | `T001`–`T006` | **100% Завершено `[X]`** | XcodeGen, SwiftPM packages, Deno lock, CI workflow |
| **Phase 2: Foundational** | `T007`–`T027`, `T127`, `T128` | **100% Завершено `[X]`** | Все миграции foundation, RLS, SwiftData ModelActor, SyncEngine, LanguageStore (PL/EN) |
| **Phase 3: US1 — Первая помощь без регистрации** | `T028`–`T039`, `T100`, `T116` | **100% Завершено `[X]`** | Deno tests (18 passed), `xcodebuild test` iPhone 17 Pro (`** TEST SUCCEEDED **`) |
| **Phase 4: US2 — Коллекция, проверка перед сохранением, каталог и Basic Care** | `T040`–`T049`, `T101`, `T129`–`T131` | **В процессе (~45%)** | Бэкенд и Deno-тесты готовы на 100%; на очереди — клиентский слой SwiftUI и UI-тесты |
| **Phases 5–11** | `T050`–`T099`, `T102`–`T115`, `T117`–`T126`, `T132`–`T146` | **Ожидают очереди** | Запланированы строго по зависимостям в `tasks.md` |

---

## 2. Что конкретно сделано в текущей Фазе 4 (US2)

### Бэкенд (Supabase / Deno / SQL):
1. **`T040`** (`guest_claim` & `claim_transfer`):
   - [`supabase/tests/guest_claim.test.sql`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/tests/guest_claim.test.sql) — pgTAP тесты переноса гостевого черновика и fallback.
   - [`supabase/functions/_shared/tests/claim_transfer_test.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/_shared/tests/claim_transfer_test.ts) — Deno-тесты для overrides, stale-переходов, валидации HMAC-подписи analysis_receipt.
2. **`T042`** (`/claims/prepare` & `/claims/commit`):
   - [`supabase/migrations/202610200013_guest_claim.sql`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/migrations/202610200013_guest_claim.sql) — SQL-функции `prepare_guest_claim`, `commit_guest_claim`, `compute_next_available_step`.
   - [`supabase/functions/plants-api/claims.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/plants-api/claims.ts) — Deno-обработчики API клейма.
3. **`T043`** (Двухфазное копирование фото и очистка):
   - [`supabase/functions/maintenance/guest-claims.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/maintenance/guest-claims.ts) — копирование из `guest-drafts` в `plant-photos` и фоновое удаление истекших черновиков (>24ч TTL).
4. **`T044`** (`plant.create` & `room` команды):
   - [`supabase/migrations/202610200014_collection_commands.sql`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/migrations/202610200014_collection_commands.sql) — создание растений/комнат и локальный fallback-сохранение.
5. **`T045`** (Поиск по каталогу):
   - [`supabase/functions/plants-api/catalogue.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/plants-api/catalogue.ts) — нормализация запросов, поиск по PL/EN/латыни/синонимам, fallback на scientific_name и атрибуция лицензий (CC BY-SA).
6. **`T129`** (Basic Care — уход для 3 бесплатных растений):
   - [`supabase/migrations/202611010002_basic_care.sql`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/migrations/202611010002_basic_care.sql) — атомарное распределение слотов 1..3, `reconcile_owner_basic_care`, триггер soft-delete plants.
   - [`supabase/functions/_shared/BasicCareService.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/_shared/BasicCareService.ts) и [`supabase/functions/plants-api/basic-care.ts`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/functions/plants-api/basic-care.ts).
7. **`T131`**:
   - [`supabase/tests/free_care.test.sql`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/supabase/tests/free_care.test.sql) — тесты бесплатного ухода, превышения лимита (4-е растение), замены слотов и удаления.
8. **Статус Deno**: все 18 тестов `_shared/tests/` проходят успешно:
   ```bash
   DENO_DIR=/Users/ruslansabirov/Library/Caches/deno /opt/homebrew/bin/deno test --config supabase/functions/deno.json --lock=supabase/functions/deno.lock --allow-env --allow-read supabase/functions/_shared/tests/
   # ok | 18 passed | 0 failed (419ms)
   ```

### Дизайн и макеты:
- Исторические промпты предыдущего агента (актуальное направление — Quiet Garden, см. обновление выше):
  - [`docs/stitch-ui-prompts.md`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/docs/stitch-ui-prompts.md)
  - [`stitch_ui_prompts.md`](file:///Users/ruslansabirov/.gemini/antigravity/brain/408120e7-5a54-4ef6-85f2-95782b0f1e06/stitch_ui_prompts.md)

---

## 3. Точка старта для следующего агента (Next Action Items)

Следующему агенту необходимо продолжить реализацию клиентской части **Фазы 4 (US2)** в следующем порядке:

1. **`T041` — реализовано 2026-11-02**: Создан сервис [`ios/Plants/Integrations/Auth/NativeAuthService.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Integrations/Auth/NativeAuthService.swift)
   - Авторизация через Apple (AuthenticationServices) и Google (GoogleSignIn).
   - При отмене диалога или ошибке входа гостевой черновик в `GuestDraftCache` / `AddFlowState` **не должен сбрасываться**.
2. **`T046`**: Создать [`ios/Plants/Data/Repositories/CollectionRepository.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Data/Repositories/CollectionRepository.swift) и [`ClaimFlowModel.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/ClaimFlowModel.swift)
   - Вызов `/claims/prepare` и `/claims/commit`.
   - Если сервер вернул `410 DRAFT_EXPIRED` (> 24ч TTL), выполнять локальный автоматический fallback: отправлять команду `plant.create` с сохраненным `analysis_receipt` из `LocalStore` (GuestDraftCache) без повторного запуска ИИ.
3. **`T047` & `T101`**: Реализовать экраны коллекции и выбора:
   - [`ios/Plants/Features/Collection/AddPlantView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/AddPlantView.swift) (сначала выбор намерения, метод ухода вложен через готовый `AddPlantRouter.swift`).
   - [`ios/Plants/Features/Collection/PreSaveReviewView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/PreSaveReviewView.swift) (вид, условия с индикатором `camera_estimate` vs `unknown`, выбор/создание комнаты).
   - [`ios/Plants/Features/Collection/PostSaveNextStepView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/PostSaveNextStepView.swift) (первый шаг на основе `next_available_step`).
   - [`ios/Plants/Features/Analysis/IdentificationFlowModel.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Analysis/IdentificationFlowModel.swift) и [`IdentificationResultView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Analysis/IdentificationResultView.swift) (чистый режим `identification` без диагноза).
4. **`T048`**: Создать карточку растения [`ios/Plants/Features/PlantDetail/PlantDetailView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/PlantDetail/PlantDetailView.swift).
5. **`T130`**: Создать экран выбора бесплатного ухода [`FreeCareSelectionView.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/FreeCareSelectionView.swift) и [`BasicCareFlowModel.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/Plants/Features/Collection/BasicCareFlowModel.swift).
6. **`T049` & `T131`**: Написать UI-тесты в [`ios/PlantsUITests/CollectionTests.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/PlantsUITests/CollectionTests.swift) и [`ios/PlantsUITests/FreeCareTests.swift`](file:///Users/ruslansabirov/Documents/ChatGPT/Plants/ios/PlantsUITests/FreeCareTests.swift), затем запустить полный сьют:
   ```bash
   xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/PlantsDerivedData test
   ```
   и после прохождения тестов пометить задачи `T040`–`T049`, `T101`, `T129`–`T131` как `[X]` в `tasks.md`.

---

## 4. Важные технические правила для следующего агента
- **Песочница / Sandbox**: Сначала вызывать команды с `BypassSandbox: false`. При запуске Deno указывать путь к кешу: `DENO_DIR=/Users/ruslansabirov/Library/Caches/deno /opt/homebrew/bin/deno ...`.
- **XcodeGen и Package.resolved**: При генерации проекта командой `xcodegen generate --spec ios/project.yml` проект пересоздается — обязательно сразу копировать:
  `mkdir -p ios/Plants.xcodeproj/project.xcworkspace/xcshareddata/swiftpm && cp Package.resolved ios/Plants.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- **Язык общения**: Строго на русском языке. Все пути к файлам и типам форматировать кликабельными markdown-ссылками.
