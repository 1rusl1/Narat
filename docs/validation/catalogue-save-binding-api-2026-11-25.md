# Catalogue C1 — принятые внутренние API, 25 ноября

Точные source5 из private `960f762e`, проверенная база `1bbde61`. В Root уже перенесены вместе с ID-B1; новые source/API C2 ещё не приняты.

- `CatalogueSaveBinding(scope: CatalogueSDKSnapshot, flowId: UUID?)` фиксирует текущий SDK epoch и указатель; nil означает зафиксированное отсутствие. `matches(scope:flowId:)` не разрешает смену владельца/epoch/flow.
- `CatalogueConnection.rememberModel(_:expected:replacingFlow:)` — новый overload с обязательным `UUID?`. Проверяет captured pointer до checkpoint await и перед публикацией, затем scope и собственный pointer; rollback сохраняет более новый callback pointer. Старый двухаргументный API и его тело не менялись. Проверку replaceability журнала выполняет вызывающий SaveView; этот overload её не заменяет.
- `CatalogueSaveView` добавляет совместимые параметры: `restoresResumableSave = true`, `resumeFlowId = nil`, `resumeScope = nil`, `feedbackAnchor = nil`, `onExplicitFeedback: ((CatalogueSDKSnapshot) -> Void)? = nil`. Обычный fresh Guest browse передаёт false, явное resume — точные flow/scope. `synchronize` не принимает новую binding автоматически; typed native continuation меняет её только для того же model/flow/operation/payload.
- `onExplicitFeedback` вызывается после явного Save/auth/Retry/восстановления результата под revision/locale/current SDK guard. Guest использует scoped ScrollViewReader и anchor; пассивные SDK/body updates не прокручивают экран.
- Fresh Browse показывает список. Continue save/Open saved plant явно перечитывают прежний pointer под owner/locale/revision guards. Возврат к списку не удаляет checkpoint/journal/receipt; новый ввод разрешён лишь при replaceable journal и забывает только совпавший pointer. Pending/неясное состояние не обходится.

Ограничение C1: проверен обычный каталог. Identification input имеет nil speciesSlug; C2 должен использовать speciesIdentifier, selectedTaxon и pinned analysisSaveIdentity для анализа. При taxon lookup текущий loadSpecies ещё нельзя проверять сравнением card.id со строкой UUID. Исходные job/photo/flow, отсутствие Edit-new для анализа и полноценный rendered resume принимаются в C2/B2.

Общий PublishedPlantImageSource/Loader/View footer не менялся; использовать принятый [media API](published-media-api-2026-11-25.md), не создавать новый cache. Результаты и границы: [C1](tester-catalogue-C1-2026-11-25.md).
