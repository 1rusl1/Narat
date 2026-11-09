# Статус контрактов

Цель от 2026-11-09: [spec](../spec.md), [API](api.md), [sync](sync.md), [переход](revision-2026-11-09.md).

| Контракт | Текущее состояние |
|---|---|
| `ai-result.schema.json` | Новый анализ: identification/diagnosis, без follow_up, вопросов и score routing. |
| `condition-profile.schema.json` | Condition2: независимые действия, ссылка на первую помощь, условия и следующая проверка вместо лечебных фаз/повторов. |
| `plant-profile.schema.json` | Plant2: действия или safety-факт, без обязательного полного care_algorithm_params/taxonomy/рецепта. |
| `catalogue-skeleton.schema.json` | Отдельный существующий каталог; сокращение лечебной базы его не удаляет. |
| `legacy/*.v1.schema.json` | Побайтовые исторические снимки. Не контракт новой публикации и не источник автоматического преобразования пользовательских рекомендаций. |

[Компактный формат 2](compact-profiles.md) согласован со schema/TypeScript validator/resolver/fixtures. Происхождение, права, ручная проверка и EN/PL сохранены; одна source-запись допустима. Legacy v1 не исполняется как новый совет; сырая история/подписи сохраняются.

Приняты через оркестратор: question-bank `f15e6c6`, follow_up `a97ff20`, score/DTO `31a465f`, evidence `e2a446d`, SQL mode guard `bd481a9`, Condition2 `e7d2d7b`, Plant2 `eb40f28`. Последняя проверка — **257 Deno tests PASS**, оба точных schema gate, deno-check, 89 automation tests и Review/QA PASS. SQL mode guard отдельно проверен clean/seeded upgrade PostgreSQL17: по 50 pgTAP, история неизменна. На staging не применён.

Три неиспользуемые Swift DTO прежнего профиля/timeline/comparison удалены в `93d77bc`: iOS build/welcome, 27 PlantsTests без skips, Simulator smoke и Review/QA PASS. T157 остаётся открытой. Новые карточки ещё требуют редакционной публикации и интеграционной проверки; fixtures не подтверждают живой фото→уход сценарий. Collection/quota/expiry, guest/прочие остатки и простой уход — T158–T160. Применённые SQL сохраняются; переходы вводятся forward migrations.

T158 — [удаление комнат](room-retirement.md) принято: SQL `b80a74e`, TS/Swift `0d8d4ee`; новые room writers отвергаются, sync плоский, старые данные/receipts сохранены. По 66 pgTAP clean/upgrade и реальные concurrent retries, 259 Deno, 28 PlantsTests/build/welcome/Simulator, Review/QA PASS. Миграция локально проверена, на стенд не применена. Следующий срез — Free-места/атомарный cap; guest claim остаётся несовместимым baseline для T159.
