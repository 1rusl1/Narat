# Narat — текущий статус и передача работы

**Обновлено 2026-11-09.** Владелец принял рекомендации аудита. Спецификация и связанные действующие документы приведены к пути **распознавание → диагностика → рекомендации → уход**. Конституция 5.0.0. Это завершённый этап сокращения scope, не реализация нового runtime.

**Workspace:** `/Users/ruslansabirov/Documents/ChatGPT/Plants`, ветка `main`.
**Источники:** [spec](../specs/001-plants-ios-mvp/spec.md), [tasks](../specs/001-plants-ios-mvp/tasks.md), [решения](validation/spec-simplification-2026-11-09.md), [аудит и карта зависимостей](validation/overengineering-review-2026-11-09.md).

## Выполнено

- Определён простой уход: действия сейчас, основание/условие и следующая проверка; обычные повторы и один контроль первой помощи. OPEN-PLAN разрешён; T156 закрывает только документальное продуктовое решение.
- В необязательный v2 вынесены лечебные цепочки, AI-динамика, комнаты, дополнительные фотофункции, универсальный pipeline, расширенный сезонный UI и журнал пересчётов. [Полный список](../specs/001-plants-ios-mvp/deferred.md).
- Убраны обязательный экран намерений/pre-post-save, распределённый trial claim и отдельный durable analytics outbox. Локальный opt-in reminder и best-effort клиентские события; billing/квоты надёжны отдельно.
- Сохранены тарифы/два starter/Free=3/paid=100/регистрационный месяц, cap до трёх и прекращение автоматики после expiry; owner isolation, история, outbox и проверенная база.
- T155 разделена на T157–T160 для согласования схем/анализа, коллекции/доступа, guest/остатков и простого ухода. Ещё 9 задач сняты без отметки выполнения. Всего 137 активных: 13 отмечены (12 прежних + документальная T156), 124 открыты; 23 снятых ID отдельно. 60 действующих FR, 24 SC, 7 историй. Это не процент готовности продукта.
- Обновлены дизайн/ASO тексты. Старые PNG и генератор перемещены без изменения содержимого в [архив](../design/archive/aso-before-2026-11-09/README.md); новых проверенных изображений пока нет.
- Удалён исполняемый минимальный gate 300 видов из валидатора каталога; сохранены count/hash/ID/источники/SQLite проверки фактического выпуска, добавлен read-only `--check`. Манифест T148 больше не требует автоматически поставить editorial completed после правки regex.

## Изменённые файлы

- `.specify/memory/constitution.md`; `specs/001-plants-ios-mvp/{spec,user-flow,plan,data-model,research,knowledge-base-pipeline,tasks,quickstart,deferred}.md`; `contracts/{api,sync,README,revision-2026-11-08,revision-2026-11-09}.md`; оба checklist.
- `design/{design-concept,stitch-specification-en,stitch-specification-pl,stitch-prompt,stitch-prompt-pl,stitch-aso-screens-prompt,aso-store-content}.md`; `docs/stitch-ui-prompts.md`; `design/screenshots/README.md`; архив генератора/17 PNG и README в `design/archive/aso-before-2026-11-09/`.
- `docs/{infrastructure-preparation,plant-catalogue-skeleton,plant-database-sourcing}.md`; `research/prompts/gemini-argon-plant-data-deep-research-ru.md`; `docs/validation/{overengineering-review-2026-11-09,spec-simplification-2026-11-08,spec-simplification-2026-11-09}.md`.
- `knowledge-base/pipeline/validate_catalogue_skeleton.py`; `tools/automation/tasks.t148-pipeline.json`; этот handoff и его [исторический снимок](archive/handoff_status_before_simplification_2026-11-09.md).

## Проверки и ограничения

- `python3 -m unittest discover -s knowledge-base/tests -v` — **PASS, 27 тестов** на фикстурах/локальных данных; лог `/tmp/narat_simplification_kb_tests.log`.
- `python3 -m unittest tools.automation.tests.test_t148_catalogue_gate -v` — **PASS, 2 теста** (локальные изображения/константы, не редакционная приёмка).
- `python3 knowledge-base/pipeline/validate_catalogue_skeleton.py --check` — **PASS** на существующем выпуске; отчёт `/tmp/narat_catalogue_simplification_check.json`. Это проверка реальных локальных данных/источников/медиа/SQLite; редакционный статус остаётся not_completed. Проверка неизменности каталога — PASS; data/media/JSON/SQLite не менялись.
- `python3 /tmp/narat_scope_checks_20261109.py` — **PASS**: 60 FR/24 SC/7 US, полнота T001–T160 и трассировки, 137 активных/13 отмеченных/124 открытых/23 снятых, только T156 новая отметка, ссылки 34 действующих документов, 17 PNG + генератор в архиве побайтово совпадают с исходными; runtime/данные каталога не менялись. `--help` валидатора показывает `--check`; `git diff --check` и `git diff --cached --check` — **PASS**.
- Живые интеграции, app/SQL/AI/StoreKit/UI tests **не запускались**; бинарные ASO-изображения не редактировались и визуально не принимались.
- Swift/TypeScript/SQL runtime и машинные JSON Schema **ещё содержат старые механизмы**; документация не объявляет их обновлёнными. Они явно отделены от цели в `contracts/README.md` и открытых T157–T160. T148/T155 не закрыты. Историческая T152 сохраняет только ранее проверенные границы отсутствия фиктивных успехов.
- Публичный eval требует до запуска конкретной выборки/достаточности T118; малые ранние прогоны не доказывают цели точности. EN/PL ASO — черновик до редакторской/визуальной приёмки и реализации.

## Запуск очистки через оркестратор

Пользователь разрешил поручить очистку оркестратору. Подготовлен `tools/automation/tasks.t157-cleanup.json`: первый срез OLD-01/T157, только ConditionProfile schema, KnowledgeTypes и analysis_result_test. Отдельный `t157_question_contract_gate.py` проверяет точный допустимый semantic diff схемы и удаление банка из типов; конфигурация добавляет этот static gate. Существующие Deno tests/check, Reviewer и QA обязательны. Миграции/деплой/Swift и другие механизмы этим срезом не меняются; T157 остаётся открытой до полного объёма.

Подготовка: manifest validate — PASS, 1 задача, без вызова моделей; 89 automation unit tests — PASS на fixtures. Новые продуктовые проверки ещё не выполнены. Запуск планируется с run-id `t157-questions-20261109-01` после сохранения чистого Git. Следующий шаг — выполнить run, дождаться результата Developer/checks/Reviewer/QA/push; при остановке сохранить точный статус/логи и причину, не объявлять срез принятым.

## Точный следующий шаг

Начать **T157**: сопоставить `contracts/{ai-result,condition-profile,plant-profile}.schema.json`, `supabase/functions/_shared/{KnowledgeTypes,AnalysisValidator,ProtocolResolver}.ts` и `ios/Plants/Data/Remote/APIModels.swift`; определить текущий/целевой компактный контракт identification/diagnosis + действий/следующей проверки, затем согласованно изменить потребителей/фикстуры с сохранением старой истории. После этого принимать реальный фото→результат срез, не считать JSON-файл готовым сценарием.

T148 остаётся на прежней остановке до запуска следующего pipeline-среза; фактические дефекты имён/переводов/медиа перечислены в обновлённом `tools/automation/tasks.t148-pipeline.json` и [архиве handoff](archive/handoff_status_before_simplification_2026-11-09.md). Полная редакционная приёмка отдельна; минимум охвата снят, сохранность 606 карточек проверяется.

**Git:** основной коммит `905d71e` (`docs: apply approved MVP simplification and align delivery scope`) создан и успешно отправлен в `origin/main`, push exit 0. Staged whitespace check — PASS; 17 PNG и генератор распознаны Git как переносы 100%. Эта запись подтверждённой публикации сохраняется отдельным документационным коммитом.

<!-- orchestrator:project-state -->
## Project State

- Narat: Swift 6/SwiftUI/SwiftData, Supabase, StoreKit 2, EN/PL; конституция 5.0.0.
- Scope принят 9 ноября: простой путь и уход, OPEN-PLAN разрешён; документы не подтверждают runtime.
- 137 активных задач: 13 отмечены (12 исторических + T156 документ), 124 открыты; 23 снятых. T155/T157–T160 открыты; T148 остановлена перед pipeline slice.
- Runtime AI классифицирует, советы из проверенных карточек. Sync/outbox, история/приватность/покупки сохранены. Тарифы/expiry не изменены.
- Следующий технический срез T157; T148 может продолжать независимую редактуру без ложного completed. Применённые миграции не переписывать.
- Handoff/tasks/Git изменяет только управляющий процесс. Fixtures ≠ live; снятый объём не выполнение. Субагенты не запускаются без отдельного разрешения.
<!-- /orchestrator:project-state -->

<!-- orchestrator:task-summary -->
## Task Summary

Этап сокращения спецификации завершён после согласия владельца; проверки/публикация описаны выше. Реализация целевых контрактов не начата. T156 — документальное решение, остальные сценарии остаются в открытой очереди. Старые отчёты и остановка T148 сохранены в архиве, не служат текущими требованиями.
<!-- /orchestrator:task-summary -->
