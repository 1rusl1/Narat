# Оркестратор Narat

Python 3.11+, stdlib, текущая авторизация Codex CLI. Конфигурация:
`tools/automation/orchestrator.config.json`. Аудит и результаты:
`docs/validation/automation/orchestrator-optimization-2026-11-08.md`.

## Начало работы

Подготовьте manifest по `tasks.example.json`, с **явными** критериями, зависимостями,
читаемыми и изменяемыми файлами. Пример проверяет инфраструктуру на fixtures;
не используйте его как приёмку продукта. Проверка manifest и просмотр контекста
не вызывают модели и не меняют проект:

```sh
python3 tools/automation/orchestrator.py validate --manifest tools/automation/tasks.example.json
python3 tools/automation/orchestrator.py context --manifest tools/automation/tasks.example.json --role reviewer
```

Запуск реальной очереди расходует CLI-квоту и после приёмки делает обычный
commit/push в origin/main. Сначала сохраните текущую работу: требуется чистое
дерево Git. Не запускайте пример случайно вместо рабочего manifest.

```sh
python3 tools/automation/orchestrator.py run --manifest /absolute/path/tasks.json --run-id work-001
python3 tools/automation/orchestrator.py status --run-id work-001
python3 tools/automation/orchestrator.py metrics --run-id work-001
python3 tools/automation/orchestrator.py run --manifest /absolute/path/tasks.json --run-id work-001 --resume
```

Manifest/config должны совпадать с сохранённым хешем; при изменении контракта
нужен новый run. `--codex` задаёт установленный executable; глобальная установка
не требуется. Код выхода: 0 — все задачи опубликованы; 1 — осталась работа;
2 — ошибка конфигурации/lock; 130 — прерывание. Состояние — источник истины.

## Исполнение и доказательства

`Developer → static/build/unit → Reviewer → QA checks → QA → публикация`.
В `verification` закреплены `owner: developer`, `before_review: [static, build, unit]`,
`on_failure: repair_with_developer`. Developer управляет циклом подготовки и
исправлений; контроллер исполняет команды от его имени, сохраняет exit code и логи.
PASS Developer означает готовность патча к тестам; итоговую приёмку он не заменяет.
Провал проверки возвращает Developer ошибку для исправления; Review/QA ждут
успеха всех обязательных проверок. Отсутствие ещё не запущенных тестов на первом
шаге Developer само по себе не является BLOCKED.

Для задач с пустым `write_files` действует `read_only_tasks: checks_first`:
контроллер запускает проверки сразу, затем Review/QA, без лишнего Developer-вызова.
Если такие проверки падают, задача BLOCKED: разрешённых файлов для исправления нет.

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

Reviewer получает diff, полные criteria, результаты checks и ограничения.
Повторное ревью low/medium получает delta с предыдущего review и прежние findings;
полный diff доступен на диске. High risk всегда получает полный diff. Длинный
diff в prompt ограничен `context.diff_chars`, с явным признаком обрезания и путём
к полному файлу. Критерии/ограничения не обрезаются. История handoff не включается.

`sessions.policy`: `fresh` (ephemeral каждый вызов) или `reuse_within_task`
(явный ID, только та же задача/роль/модель). Пороги `max_turns`,
`max_estimated_tokens`, `max_input_tokens` и `rotate_after_phase` запускают
compaction: структурированный checkpoint на диске и новая сессия. Цель,
criteria, решения, изменения, результаты, проблемы и следующий шаг сохраняются;
транскрипты/рассуждения/полные успешные логи не копируются. Отдельных LLM-вызовов
для compaction нет. Порог estimates — эвристика bytes/4; reported input может
включать cached tokens и не является точным измерением окна контекста.

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
проверок, Review, QA и успешного push. При `publish.enabled=false` результат
остаётся WAITING. Неуспешная публикация останавливает очередь; причина в state.
Проверенный отчёт/сводка handoff сохраняются с указателем на состояние публикации.

## Retry, маршрутизация, квоты

По умолчанию: Developer ≤3, Review ≤2, QA ≤2 CLI-вызовов на задачу, включая
ошибки транспорта/fallback. Одинаковая ошибка на неизменённых файлах дважды
даёт BLOCKED. Бюджеты настраиваются; исчерпание не означает acceptance.
Независимая задача может продолжиться только при чистом дереве; грязная
незавершённая работа сохраняется и останавливает переход к изменениям другой задачи.
Зависимости заблокированных задач не запускаются. Есть общий лимит времени и задач.

В `roles.<role>.<level>` задаются provider, ordered `models`, reasoning effort.
Используется максимум сложности и риска. Названия моделей находятся только
в конфигурации, а не в логике routing. Сейчас реализован Codex CLI adapter;
другие providers отклоняются до запуска. Подключение нового provider требует
адаптера с тем же контрактом результата. Дополнительные стадии потребуют явных
правил переходов/acceptance; произвольные роли не исполняются автоматически.

Rate/usage limit или недоступность модели разрешают только следующий явно
настроенный fallback. Других моделей и обхода квот нет. Auth, timeout, неизвестная
ошибка — WAITING; lost session допускает свежую попытку в том же общем budget.
Без fallback лимит даёт WAITING, ожидание возобновляется вручную. Время сброса
не выдумывается. Нет бесконечного polling/retry и отдельной модели-диспетчера.

## Логи и метрики

Runtime исключён из Git: `docs/validation/automation/runs/orchestrator-<run-id>/`.
Там state.json, metrics.jsonl, checkpoint JSON, полные prompt/answer/JSONL,
stdout/stderr и diff. Метрики — идемпотентная проекция call records в state,
без двойного учёта после crash. Команды успешных checks представлены именем,
exit/status/временем и путями; ошибка — ограниченным excerpt с полным логом на диске.

Наблюдайте task/agent/model/provider, calls, retries, review cycles, prompt_bytes,
elapsed_seconds, task status, measured input/output/cached_input_tokens, unknown
usage и reported quota. `estimated_prompt_tokens` хранится отдельно, с методом.
`reported_tokens_by_call` показывает сырые счётчики, unknown_usage_calls —
вызовы с неполной статистикой. Токены между вызовами не суммируются: на живом
resume CLI сообщил накопительные значения, а область счётчика не гарантирована
в JSONL-контракте. Эти значения не объявляются точным расходом отдельного turn.
Токены не переводятся в процент пятичасового лимита подписки.

## Проверка

```sh
python3 -m unittest discover -s tools/automation/tests -q
python3 tools/automation/orchestrator_smoke.py --run-id unique-cli-smoke
```

Первая команда использует fixtures/временные Git-репозитории и локальный bare
origin. Вторая расходует квоту выбранной модели: новая сессия → resume того же
ID → новая изолированная задача, без инструментов. Это проверка CLI, не продукта.
Процент экономии не заявляется: baseline полноценных dev/review/QA вызовов
раньше отсутствовал. Сравнивайте prompt_bytes/calls/retries/checks и успех
сопоставимых рабочих задач; отдельно смотрите регрессии и реальные квоты.
