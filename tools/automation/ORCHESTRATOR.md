# Оркестратор Narat

Python 3.11+, stdlib, текущая авторизация Codex CLI. Конфигурация:
`tools/automation/orchestrator.config.json`. Аудит и результаты:
`docs/validation/automation/orchestrator-optimization-2026-11-08.md`.

Два параллельных управляющих чата: [план A/B](../../docs/parallel/README.md).
Нужны отдельные worktree и branch-specific `--config`: default config публикует в main.
Lock checkout не защищает общий Simulator между worktree; UI gates выполняет только A.

## Начало работы

Подготовьте manifest по `tasks.example.json`, с **явными** критериями, зависимостями,
читаемыми и изменяемыми файлами. Пример проверяет инфраструктуру на fixtures.
`prepare` за одну команду проверяет manifest, ветку публикации и входы задач,
у которых уже есть предпосылки. В выводе указаны проверки и начальные роли моделей.

```sh
python3 tools/automation/orchestrator.py prepare --config /absolute/path/lane.json --manifest /absolute/path/tasks.json
```

Запуск реальной очереди расходует CLI-квоту и после приёмки делает обычный
commit/push в ветку из config. Сохраните новый manifest и нужные файлы локальным
коммитом, чтобы запустить очередь с чистого дерева. Обычный push при приёмке
отправит и этот коммит. Проверки из плана выполняет очередь. Для нового gate
проверьте его работу при разработке самого gate.

```sh
python3 tools/automation/orchestrator.py run --manifest /absolute/path/tasks.json --run-id work-001
python3 tools/automation/orchestrator.py status --run-id work-001
python3 tools/automation/orchestrator.py summary --run-id work-001
python3 tools/automation/orchestrator.py metrics --run-id work-001
python3 tools/automation/orchestrator.py metrics --run-id work-001 --compare-run-id work-002
python3 tools/automation/orchestrator.py run --manifest /absolute/path/tasks.json --run-id work-001 --resume
```

Manifest/config должны совпадать с сохранённым хешем; при изменении контракта
нужен новый run. `--codex` задаёт установленный executable; глобальная установка
не требуется. Код выхода: 0 — все задачи опубликованы; 1 — осталась работа;
2 — ошибка конфигурации/lock; 130 — прерывание. Состояние — источник истины.

## Исполнение и доказательства

Для простых задач (`risk=low`, `complexity=low`):
`Developer → static/build/unit → QA checks → одна совмещённая приёмка Review/QA → публикация`.
Остальные задачи: `Developer → static/build/unit → Reviewer → QA checks → QA → публикация`.
Совмещённая роль `acceptance` проверяет и код/регрессии, и фактические доказательства
каждого критерия. Объединение не отменяет ни одного scope/AC gate и не позволяет
принять задачу до UI/QA checks. Политика — `acceptance.combined_levels: [low]`;
значения medium/high запрещены. Для старого split-пути задайте пустой список.
В `verification` закреплены `owner: developer`, `before_review: [static, build, unit]`,
`on_failure: repair_with_developer`. Developer управляет циклом подготовки и
исправлений; контроллер исполняет команды от его имени, сохраняет exit code и логи.
PASS Developer означает готовность патча к тестам; итоговую приёмку он не заменяет.
Провал проверки возвращает Developer ошибку для исправления; Review/QA ждут
успеха всех обязательных проверок. Отсутствие ещё не запущенных тестов на первом
шаге Developer само по себе не является BLOCKED.

Для задач с пустым `write_files` действует `read_only_tasks: checks_first`:
контроллер запускает проверки сразу, затем выбранную приёмку, без Developer-вызова.
Если такие проверки падают, задача BLOCKED: разрешённых файлов для исправления нет.
Это предпочтительный путь для уже подготовленного кандидата, а не повод снова
просить Developer подтвердить существующий код. После прерывания read-only задачи
повторяются проверки/приёмка; Developer не добавляется при resume.

Для проверки изменений готового кандидата добавьте в manifest `candidate_base`
(полный 40-символьный SHA исходного коммита), оставьте `write_files: []` и перечислите
**все** пути дельты в `files`, включая удалённые. Engine проверяет, что base — предок
HEAD, сохраняет настоящий полный `git diff base HEAD` в task.patch и передаёт SHA
обеих версий. Пустая дельта/неполный список путей блокируют вызов модели. Без
candidate_base read-only задача явно проверяет текущий snapshot: пустой patch не
подтверждает минимальность изменений. Критерии и обязательные scope checks сохраняются.

Необязательный `evidence_files` — список относительных путей к уже существующим
непустым fixtures/отчётам. Preflight проверяет inputs/evidence до вызова модели,
а перед приёмкой — наличие stdout/stderr сохранённых checks. В `preflight` config
заданы Xcode project и карта каталог→target. Для перечисленных/изменённых Swift
проверяются реальные fileRef и Sources нужного target, а не имя в комментарии.
Новые файлы проверяются после patch **до** сборки; target обновляет controller.
Неизвестная структура проекта останавливает проверку, а не считается включением.

Проверки выбираются по максимальному риску/сложности, scope и criteria.
Для `ios/` обязательны `ios_gate.py` (существующие doctor build/welcome и target
PlantsTests) и `simulator_smoke.py`. Для `supabase/` — существующий Deno task;
для автоматизации — unittest. SwiftLint/formatter не добавлялись: в проекте
нет закреплённой конфигурации; настройте их как checks, когда они появятся.

У каждого критерия есть ID, описание, check IDs и mode `fixture`, `local` или
`live`. Режим check обязан совпадать. Exit 0 без полного PASS summary для
встроенных iOS/MCP runner не принимается. Unit gate требует реальные passed
tests без skips. Произвольные checks — доверенные команды владельца проекта:
они должны сами проверять фактический результат, а не только наличие файла.
Для T152 нужен отдельный manifest и проверки его backend/outbox/UI-сценариев;
welcome smoke недостаточен. Физическая камера/OAuth требуют своих доказательств.

Поле findings содержит только нерешённые дефекты, пояснения идут в decisions. PASS с непустым findings — противоречивый ответ: WAITING без запуска Developer repair.

Reviewer/QA обязаны вернуть все criteria и check IDs; неизвестные/пустые или
устаревшие ответы не дают acceptance. QA получает пути к accessibility/PNG и
логам из результатов детерминированных runner. Прямой MCP-доступ агента отключён.
Успешный check переиспользуется только при том же fingerprint всех отслеживаемых
и неигнорируемых файлов и той же спецификации команды. Любое новое изменение
инвалидирует доказательства. Проверки не повторяются при неизменённом коде.

## Контекст и сессии

Каждая новая задача начинает отдельную CLI-сессию. Нет `resume --last`, fork
предыдущей задачи или пересылки её истории. В prompt идут полные критерии,
явные ограничения, Project State из маркеров основного handoff, релевантные пути,
решения только явных dependencies и краткие результаты проверок. Поиск — `rg`,
область manifest и diff. Дополнительные файлы доступны для самостоятельного чтения.

Новая сессия Reviewer/QA/acceptance получает diff, полные criteria, результаты
checks и ограничения. При настоящем resume той же задачи/роли/модели передаются
только изменения файлов с прошлого вызова этой роли, новые/изменённые результаты
checks, изменения краткого summary и ошибки. Criteria, architecture, Project State
и dependency context повторно не пересылаются: они остаются в сессии. Ответ обязан
повторить новый fingerprint. Полный task diff доступен по пути на диске.

При смене модели, lost session, неизвестном результате после прерывания или
compaction передаётся полный контракт: дельта допустима только для известной
продолжаемой сессии. Высокий риск и эскалация получают полный diff в новой сессии.
Длинный diff ограничен `context.diff_chars`, с признаком обрезания и путём к полному
файлу; критерии в полном пакете не обрезаются. История handoff не включается.

`sessions.policy`: `fresh` (ephemeral каждый вызов) или `reuse_within_task`
(явный ID, только та же задача/роль/модель). Пороги `max_turns`,
`max_estimated_tokens` и `rotate_after_phase` запускают compaction: структурированный
checkpoint на диске и новая сессия. `max_input_tokens` используется только если
адаптер явно вернул `context_tokens` со scope `context_tokens_scope=current_context`;
одни usage.input_tokens, включая per-turn/cumulative counters, не измеряют окно
контекста. Текущие Codex/Agy адаптеры такой метрики не предоставляют: действуют
лимит трёх turns и эвристика 24000 prompt tokens. Цель,
criteria, решения, изменения, результаты, проблемы и следующий шаг сохраняются;
транскрипты/рассуждения/полные успешные логи не копируются. Отдельных LLM-вызовов
для compaction нет. Порог estimates — эвристика bytes/4; reported input может
включать cached tokens и не является точным измерением окна контекста. При смене
reasoning effort той же модели также создаётся новая сессия. Метрики сохраняют
выбранный reasoning_effort; между разными задачами история не переносится.

`context.max_discovered_files=6` ограничивает только дополнительные подсказки
поиска; явные пути и changed files не обрезаются. `context.read_chars=16000` задаёт
ориентир в инструкции модели: rg→нужные диапазоны, при обрезании дочитать участок.
Это ограничение инструкции, не принудительное усечение stdout CLI; полные логи
и код доступны. Один manifest должен описывать одно проверяемое поведение.

## Записи и восстановление

Все агенты в read-only sandbox; Developer возвращает обычный unified Git patch.
Контроллер проверяет `git apply --numstat/--check`, scope/пути и применяет patch.
Обычные новые/изменённые/удалённые текстовые файлы поддерживаются; binary,
symlink, submodule и rename/copy patches не поддерживаются. Для больших бинарных
активов нужен отдельный детерминированный шаг. Handoff, tasks.md, AGENTS.md,
оркестратор и runtime-отчёты защищены от agent patch.

Один общий flock исключает два контроллера/doctor/Simulator одновременно.
Встроенные checks наследуют реальный descriptor lock, агентам он не передаётся.
Только контроллер обновляет Task Summary в `docs/handoff_status.md` и отдельный
`docs/validation/automation/tasks/<task-id>.md`. История и Project State сохраняются.
Продуктовые checkbox не закрываются автоматически: manifest может описывать
только срез большой задачи. Закрытие tasks.md требует полной продуктовой приёмки.

State записывается атомарно с fsync; budget списывается до запуска CLI.
Прерванная стадия никогда не считается успешной. `--resume` сохраняет бюджеты,
проверяет HEAD/fingerprint и запускает новую сессию при неизвестном исходе.
Применённый перед crash patch проверяется обратным `git apply --check` без
изменения файлов и повторно не применяется. Публикация имеет durable intent;
после crash/ошибки push можно продолжить её без нового Review/QA. Операции
reset/clean/stash/force push отсутствуют. Сторонние изменения вызывают остановку.

Статусы: PENDING, RUNNING, WAITING, BLOCKED, COMPLETED. COMPLETED требует
проверок, выбранной приёмки Review/QA и успешного push. При `publish.enabled=false` результат
остаётся WAITING. Неуспешная публикация останавливает очередь; причина в state.
Проверенный отчёт/сводка handoff сохраняются с указателем на состояние публикации.

## Retry, маршрутизация, квоты

По умолчанию: Developer ≤3, Review ≤3, QA ≤3, совмещённая acceptance ≤3
попыток на задачу. Ошибки транспорта расходуют budget. Разрешённый fallback при
limit/unavailable не расходует дополнительную логическую попытку, но каждый
фактический CLI-вызов остаётся в метриках расхода и retries. Одинаковая ошибка на неизменённых файлах дважды
даёт BLOCKED. Бюджеты настраиваются; исчерпание не означает acceptance.
Независимая задача может продолжиться только при чистом дереве; грязная
незавершённая работа сохраняется и останавливает переход к изменениям другой задачи.
Зависимости заблокированных задач не запускаются. Есть общий лимит времени и задач.

В `roles.<role>.<level>` задаются default `provider`, ordered `models`, reasoning effort.
Каждая запись в `models` может быть строкой `<provider>:<model>` (например,
`"codex:gpt-6.1-sol"`, `"agy:gemini-4-argon-low"`, `"agy:gemini-3.8-flash-high"`),
обычным именем модели (тогда берётся `provider` уровня) или объектом
`{"provider": "...", "model": "...", "reasoning_effort": "..."}`.
Developer использует complexity: low/medium → Sol medium, high → Sol high.
Сложное замечание (`finding_complexity=high`) включает high effort для дальнейшего
Developer repair, с новой сессией и прежним budget. Risk не занижается ради скорости.
Выбор checks по-прежнему использует максимум сложности и риска. Обычная приёмка
использует Sol (`gpt-6.1-sol`, fallback `gemini-3.8-flash-high`); высокая сложность
задачи сама по себе не включает Astra. Высокий риск (`risk=high`) или сложные
замечания включают high route: Astra (`gpt-6-astra`, fallback `gemini-4-argon-high`).
Ответ агента содержит `finding_complexity: low|medium|high`; high — для неоднозначных
межкомпонентных, security/data-loss дефектов (без замечаний — low). Старые ответы
без поля читаются совместимо. Также эскалация происходит после
двух отказов приёмки (`acceptance.escalate_after_failures`), если не исчерпан budget
и не сработал no-progress guard. Эскалация не сбрасывает budget, действует на все
следующие роли приёмки задачи и создаёт новую сессию при смене модели. Названия
моделей находятся только в конфигурации, а не в логике routing. Поддержаны адаптеры `codex` (ChatGPT Codex CLI)
и `agy` (Gemini.app / Antigravity local hub `agentapi` с read-only профилем `research`);
другие providers отклоняются до запуска. При переключении на fallback-модель
с другим именем или провайдером создаётся новая сессия с сохранением структурированного
checkpoint. Дополнительные стадии потребуют явных правил переходов/acceptance;
произвольные роли не исполняются автоматически.

Rate/usage limit или недоступность модели разрешают только следующий явно
настроенный fallback. Других моделей и обхода квот нет. Auth, timeout, неизвестная
ошибка — WAITING; lost session допускает свежую попытку в том же общем budget.
После Developer timeout ставится `replan_required`: даже явный resume этого run
не повторяет запрос. Контроллер должен уменьшить/уточнить manifest либо записать
устранённую причину остановки в новом manifest и использовать новый run-id.
Автоматического переноса патча/бюджета в новый run нет, старое evidence сохраняется.
`agent_timeout=900` и max_developer_attempts=3 оставлены прежними.
Без fallback лимит даёт WAITING, ожидание возобновляется вручную. Время сброса
не выдумывается. Нет бесконечного polling/retry и отдельной модели-диспетчера.

## Логи и метрики

Runtime исключён из Git: `docs/validation/automation/runs/orchestrator-<run-id>/`.
Там state.json, metrics.jsonl, checkpoint JSON, полные prompt/answer/JSONL,
stdout/stderr и diff. Метрики — идемпотентная проекция call records в state,
без двойного учёта после crash. Команды успешных checks представлены именем,
exit/status/временем и путями; ошибка — ограниченным excerpt с полным логом на диске.

`summary` выводит готовую Markdown-сводку из state. В ней есть результат, причина
остановки, коммит, режимы и логи проверок, время моделей, повторы и тайм-ауты.
Каждый вызов очереди сохраняет собственное время выполнения, включая resume.
После успешной приёмки engine включает замеры в отчёт и короткую запись handoff
в том же коммите. Используйте этот отчёт в итоговом ответе. При остановке готовую
сводку можно использовать в handoff, добавив фактический следующий шаг. Отдельные
обёртки для замера и ручные копии state в Markdown/JSON нужны только для отдельного
исследования производительности.

`metrics` показывает `tasks`, `overall` и `quality_cohorts`: полные затраты и
`per_accepted_task`. Знаменатель — только COMPLETED (проверки, приёмка и push).
Числитель включает все вызовы, repairs/retries/fallbacks, прерванные попытки и
непринятую работу, а также сохранённую историю времени checks. Если принятых задач
нет, удельный расход `null`. Время прерванного вызова без результата и полная
история checks старого state тоже не выдаются за нулевые/точные значения.

`quality_contract` фиксирует описание задачи, критерии/режимы доказательств,
ограничения, файлы, архитектуру, risk/complexity и фактические спецификации checks;
также candidate_base, evidence_files и policy preflight;
выбор модели/число ролей в него не входят. `--compare-run-id` (можно несколько)
сопоставляет только совпадающие контракты. Смешанный overall не доказывает экономию
при одинаковом качестве. Совпадение контракта не заменяет продуктовую приёмку;
fixture и live проверки остаются отдельными.

Сырые input/output/cached_input_tokens сохранены в `reported_tokens_by_call`.
Точные суммы допустимы только для явно гарантированного адаптером `per_turn` либо
`session_cumulative` (последний счётчик каждой сессии, без двойного учёта resume).
Текущие Codex/Agy адаптеры не гарантируют область CLI-счётчика: токеновый расход
на принятую задачу остаётся `null`. Для сравнения доступны фактические calls,
retries, prompt_bytes и время; `estimated_prompt_tokens` — отдельная эвристика
UTF-8 bytes/4. Неизвестное не заменяется нулём, токены не переводятся в деньги
или процент лимита подписки. Живую экономию нужно измерить отдельно.

## Проверка

```sh
python3 -m unittest discover -s tools/automation/tests -q
python3 tools/automation/orchestrator_smoke.py --run-id unique-cli-smoke
python3 tools/automation/orchestrator_smoke.py --provider agy --model gemini-4-argon-low --run-id unique-agy-smoke
```

Первая команда использует fixtures/временные Git-репозитории и локальный bare
origin. Вторая расходует квоту выбранной модели: новая сессия → resume того же
ID → новая изолированная задача, без инструментов. Это проверка CLI, не продукта.
Процент экономии не заявляется: baseline полноценных dev/review/QA вызовов
раньше отсутствовал. Сравнивайте prompt_bytes/calls/retries/checks и успех
сопоставимых рабочих задач; отдельно смотрите регрессии и реальные квоты.
