# Статус контрактов

**Целевое поведение от 2026-11-09:** [spec](../spec.md), [API](api.md), [sync](sync.md), [переход](revision-2026-11-09.md).

**Прогресс 9 ноября:** банк diagnostic_disambiguation удалён из ConditionProfile schema и backend-типа/semantic validator в первом срезе T157; новые regression tests прошли, коммит f15e6c6. Другие поля/режимы ещё не согласованы; T157 остаётся открытой.

Существующие `ai-result.schema.json`, `plant-profile.schema.json`, `condition-profile.schema.json` — машинные контракты прежней реализации. Они ещё содержат старые режимы/поля; их нельзя использовать как основание вернуть снятые функции. T157 согласует schema, TypeScript validator/resolver, Swift DTO и fixtures вместе. `catalogue-skeleton.schema.json` обслуживает отдельный существующий каталог и не удаляется из-за сокращения лечебной базы.

Документационный этап не меняет машинные schema в отрыве от потребителей и не объявляет их совместимыми. Переход и сохранение исторических данных входят в T155/T157–T160. Старые применённые SQL — история; новые правила вводятся forward migrations.
