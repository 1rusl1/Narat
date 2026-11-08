# Оптимизация CLI-оркестрации — аудит и план

## Аудит до реализации

На 8 ноября 2026 рабочей очереди Developer → Review → QA нет. Реализованы
`doctor.py`, `mcp_client.py`, `simulator_smoke.py` и setup UI-helper. Это основа,
а не оркестратор, который можно оптимизировать заменой нескольких функций.

Уже есть: последовательные ephemeral CLI smoke-сессии, явные модели, JSONL,
ограничения sandbox, отключение пользовательских MCP/hooks/apps, общий flock,
тайм-ауты и остановка группы процессов, атомарный summary, полные логи на диске,
проверки сборки/xcresult/изолированной backend-конфигурации и реальный UI smoke.
Эти механизмы сохраняются. Базовая проверка: 22 unittest PASS (тестовые данные).

Нет: очереди и зависимостей, task state/resume, адресного контекста, compaction,
retry budgets, анализа прогресса, Review/QA gates, маршрутизации по риску,
метрик usage и политики ошибок провайдера. `tasks.md` — продуктовый план,
не готовый manifest автономного исполнения: задачам нужны явные критерии,
границы файлов и проверяемые доказательства. Следующая продуктовая задача T152.

Главный источник потенциального дублирования — многолетний по структуре
`docs/handoff_status.md`: актуальное состояние смешано с подробной историей.
Сейчас полноразмерные dev/review-запросы ещё не выполняются, поэтому измеренного
baseline расхода моделей и процента экономии нет. Вызовы doctor — connectivity
smoke, не метрика эффективности разработки.

## План реализации по приоритетам

1. Контекст и состояние: компактные разделы handoff с сохранением истории;
   manifest задач, строгая валидация, детерминированный выбор путей; атомарное
   состояние, общий lock, retry budgets. Полные требования не обрезаются.
2. Исполнение: Developer → обязательные checks → Review → QA → acceptance;
   конфигурируемые роли/модели, diff/re-review, проверка всех criteria/evidence,
   безопасные Git-операции и восстановление. Все агенты read-only; Developer
   возвращает patch, который единственный управляющий процесс проверяет и
   применяет только к разрешённым файлам. MCP/simulator запускает существующий
   детерминированный runner, QA читает доказательства. Это исключает прямую
   запись агентов в handoff/tasks и побочные записи внешних MCP-серверов агента.
3. Usage/compaction/лимиты: JSONL, measured/estimated/unknown отдельно, явные
   session IDs только внутри задачи/роли/модели, ротация с сохранённым кратким
   состоянием, конечные fallback и ожидание без выдуманного reset time.
4. Проверка: subprocess-фикстуры и временные Git-репозитории для полного цикла,
   сбоев, повторов, восстановления, публикации; существующие 22 теста; CLI help,
   минимальный live smoke при доступности. Продуктовые сценарии не закрываются
   по результатам инфраструктурных тестов.

## Основания CLI-контракта

Локальный `codex exec --help` / `exec resume --help` подтверждают явный resume ID,
JSONL, output-schema, output-last-message, ignore-user-config и sandbox.
Официальные [non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
и [CLI reference](https://learn.chatgpt.com/docs/cli/reference) проверены 8 ноября.
Usage берётся только из сообщённых CLI полей; квота подписки не выводится из токенов.
Отдельный публичный exec compaction command не предполагается: безопасная
альтернатива — сохранение структурированного состояния и новая сессия.

## Границы

Продуктовые исходники и checkbox в `specs/001-plants-ios-mvp/tasks.md` не меняются.
Новая инфраструктура не означает приёмку T152, физических устройств, OAuth,
backend, PL/EN. Проверки фикстур и живые проверки фиксируются раздельно.

## Этап 1 — контекст и состояние

Добавлены `orchestration/context.py`, `storage.py`, JSON-конфигурация и 14 контрактных тестов. 36/36 инфраструктурных тестов PASS, diff-check PASS. Критерии не обрезаются; длинный diff получает явный указатель на полный файл. Handoff хранит историю, но prompt выбирает только Project State. Маршрутизация учитывает максимум риска/сложности. State привязан к хешу manifest/config; budgets записываются до запуска. Runtime ещё не подключён; это проверка компонентов на фикстурах, без живых моделей/Simulator.

## Финальная реализация

Сохранены существующие doctor/MCP/Simulator-инструменты. Добавлены:

- `orchestrator.py`: validate/context/run/status/metrics, явный manifest и serial queue.
- `orchestration/engine.py`: pipeline, зависимости, бюджеты, риск, кэш успешных checks по fingerprint, delta review, проверка criterion evidence, durable publication.
- `orchestration/provider.py`: Codex CLI, read-only, stdin prompt, output-schema, JSONL, явный resume, строгая проверка ответа и ошибки/usage.
- `orchestration/process.py`: timeout/process group, полные логи на диске, ограниченный error excerpt.
- `orchestration/repository.py`: fingerprint tracked/untracked, text diff/patch scope, safe Git без reset/clean/stash/force.
- `ios_gate.py`: повторно использует doctor's build settings/welcome, запускает существующий PlantsTests и проверяет xcresult; `doctor.py` получил общий ios_command и наследование настоящего lock descriptor.
- `orchestrator_smoke.py`, `tasks.example.json`, два набора tests engine/provider, `ORCHESTRATOR.md`; обновлены README и CI workflow.

Один task = отдельная сессия. Reuse ограничен task/role/model. Компакция детерминированная: checkpoint и новая сессия, без дополнительной модели. Retry counts сохраняются до вызова; CLI failures не дают бесконечного повторения. Auth/unknown/timeouts/limit без разрешённого fallback → WAITING; отсутствие прогресса/бюджета → BLOCKED. Независимая очередь продолжается только при чистом дереве. Принятая задача не вызывается повторно. COMPLETED требует успешного commit/push; их recovery не запускает модели заново.

Handoff остаётся главным документом. Prompt выбирает только Project State; краткие отчёты задач сохраняются отдельно, историю можно читать по необходимости. Agent patch не может изменять handoff/tasks/controller. Нет автоматического переноса продуктовых checkbox: срез задачи и её полная приёмка различаются.

### Реально выполненные проверки

- `python3 -m unittest discover -s tools/automation/tests -q`: **74 PASS**, 21,823 с; fixtures, реальные subprocess и временные Git/bare origin. Включены прежние 22 tests, 14 context/state и 38 новых engine/provider tests. Проверены pipeline success, failed build без Review, evidence отказ, replay, бюджеты/CLI ошибки, публикация, crash после patch и commit, changed files и независимость задач.
- `orchestrator.py validate --manifest tools/automation/tasks.example.json`: VALID, без LLM.
- `orchestrator.py --help`, `ios_gate.py --help`: exit 0.
- `git diff --check`: PASS.
- Live `orchestrator_smoke.py --run-id orchestrator-cli-20261108`: **PASS**, три Sol-запроса без tools. Явный resume сохранил session ID; следующая задача получила новый. Локальное evidence в игнорируемом runs-каталоге.

В live JSONL input: 12844 / 26745 / 12844; output: 48 / 96 / 48;
cached: 0 / 12672 / 0. Это raw provider counters, на resume наблюдаются накопительные значения. В metrics они не складываются как отдельные per-call расходы: область счётчика не гарантирована, estimates выделены отдельно. Пятичасовая квота и reset не сообщены. Измерены три вызова, ~4,662 / 5,514 / 4,813 с, prompt по 335 bytes. Это transport smoke, не разработка задачи.

Детерминированное сравнение перед финальной записью handoff: полный файл 146403 bytes;
полный начальный packet примера 3997 bytes; все criteria сохранены, Historical Information не включена. Измерение в `runs/context-measurement.json`. Старого рабочего dev/review-пайплайна не было: процент экономии или изменение качества на реальных продуктовых задачах не заявляется.

### Ограничения и дальнейшая проверка

Live полный цикл с Developer/Reviewer/Astra-QA пока не запускался. Новый unit gate проверен на fixtures, а не новой Simulator-сборкой; исходники iOS не изменены. Live backend/OAuth/камера/PL/EN и T152 не приняты. Новый CI fixture job настроен, его удалённый результат пока неизвестен. Поддержаны Codex и text patches; другие providers, binary/rename edits и дополнительные роли требуют явных адаптеров/стадий. Автоматическое закрытие полной продуктовой задачи по одному infrastructure smoke запрещено.

Следующий шаг: manifest одного среза T152 с явными checks/evidence modes; validate → context → контролируемый run из чистого дерева. Наблюдать calls/task/role/model, prompt_bytes, retries/review cycles, успешность и регрессии; raw CLI usage и unknown учитывать отдельно от estimates и реальной подписочной квоты. Команды приведены в ORCHESTRATOR.md.

Публикация: `537cb2f` (аудит), `ee92fc5` (контекст/state), `dcaa05e` (pipeline/metrics/recovery) успешно отправлены обычным push в origin/main. После отправки реализации рабочее дерево чистое; это дополнение фиксирует результат.

## Исправление первого живого BLOCKED и Developer-owned tests

Реальный `first-001` остановился на Developer: модель корректно не подтвердила ещё не запущенные тесты, но контракт ошибочно не отделял готовность patch от acceptance. Старый BLOCKED/логи сохранены. По указанию владельца добавлен verification config, Developer владеет test/fix cycle, контроллер исполняет его проверки детерминированно. Ошибки возвращаются Developer; Review/QA ждут успешных checks. Read-only задачи начинают с checks и не расходуют Developer-вызов. Ролевые инструкции теперь явно различают подготовку patch и доказанную приёмку. Проверены реальный failed subprocess → repair → PASS → Review/QA и отсутствие модельных вызовов для упавшей read-only проверки. Исправлен отдельный lock тестов при наследовании контроллерского fd.

78 unittest PASS, включая полный запуск под настоящим production lock (exit 0, 25,480 с); validate/diff-check PASS. Live повтор полного примера ещё предстоит; исходники приложения/продуктовые checkbox не менялись. Следующий шаг: commit/push, новый `first-002` (старый контракт не изменять задним числом), зафиксировать его реальный исход.

### Дополнение по first-002

Тесты (78) и содержательная проверка Review/QA прошли, однако QA дважды поместил пояснение об ожидаемых негативных fixture-логах в findings при status=PASS. Строгий acceptance отказал, Reviewer budget исчерпан; run остался BLOCKED. Это не продуктовая приёмка. Исправлены инструкции/schema description: notes → decisions, findings → только actionable defects, PASS → findings=[]. Противоречие теперь даёт WAITING без Developer repair, а read-only acceptance FAIL не вызывает разработчика без writable scope. Добавлена регрессия. Старые evidence/state сохранены.

Проверки исправления формата: 79/79 unittest PASS (26,452 с); diff-check PASS.

### Успешный полный контрольный прогон first-003

После `9d6beca`/`9499b57` (оба push успешны) выполнен `orchestrator.py run --manifest tools/automation/tasks.example.json --run-id first-003`: exit 0, COMPLETED. Контроллер запустил 79 infrastructure fixture tests и diff-check; затем два независимых живых Astra-вызова (Review=1, QA=1), без Developer для read-only задачи. Критерий подтверждён, отчёт/handoff закоммичены и отправлены самим оркестратором (`ab088f9`). Дерево после публикации чистое. Это первое подтверждение полного infrastructure цикла с живыми моделями, без приёмки продукта/новой Simulator-сборки/live backend. Первый и второй blocked run не изменялись; повторный запуск принятого task ID не требуется. Следующий шаг — отдельный manifest среза T152.
