# Две параллельные сессии Plants

**Пилот завершён 10 ноября 2026:** engine25a5830 перенесён в A/B, по одному следующему
пакету принято (A e04103f, B88a8ea8), обе очереди снова остановлены.
[Результаты и измерения](../validation/automation/throughput-pilot-2026-11-10.md).
Следующие пакеты, main promotion и CI не запускаются без новой команды владельца.

**Решение владельца 10 ноября 2026:** остановить обе очереди перед изменением конфигурации; автоматически не возобновлять. GitHub Actions/дальнейшая CI-работа отложены, T006 открыта и не блокирует разработку. Локальные проверки сохраняются. [Измерения и предложения по ускорению](../validation/automation/throughput-audit-2026-11-10.md); принятые изменения engine описаны ниже. Инструкции запуска ниже действуют только после новой команды на возобновление.

**Обновление engine/config 10 ноября:** изменения реализованы в
`codex/development-throughput-audit`, 147 локальных fixture-тестов PASS, без запуска A/B. Пакет уже принят A (merge20f49b6) и B (merge2d1b374);
политика переноса ниже сохраняется для последующих обновлений между runs. В каждом собственном branch config перенести новые `context` и `preflight`
из принятого общего config, сохранив все lane-specific checks, routing providers,
budgets и `publish.branch=codex/plants-ios`/`codex/plants-backend`. Не заменять branch
config целиком default-конфигурацией и не resume старый run с новым config/engine.
Для готового кандидата — read-only manifest с `candidate_base` и всеми путями дельты;
для timeout Developer — пересмотр задания и новый run. Сам перенос не разрешает запуск.

Подготовлено 9 ноября 2026 по `main` на `344eeb3`. Это распределение оставшейся работы и задания управляющим чатам; сессии, worktree и модельные запуски этим этапом не создавались. Источник статусов — [tasks.md](../../specs/001-plants-ios-mvp/tasks.md), фактических доказательств — [handoff](../handoff_status.md). На старте распределены 137 открытых ID: A — 59, B — 78, включая 3 необязательные задачи комнат; исходно выполненные/снятые ID исключены. После полной fixture-приёмки T162 `532984c` текущие checkbox 15/151, открыты 136 (A — 58, B — 78); allocation сохраняет исходную карту владения. Фактические текущие статусы — tasks/handoff.

## Запуск двух чатов

1. Создать два чата **Worktree** от коммита подготовки, содержащего этот документ; обоим дать соответствующее задание ниже. Создание чатов и worktree не заменяется двумя CLI-процессами в исходной папке.
2. A работает в своей ветке `codex/plants-ios`, B — `codex/plants-backend`. Если Worktree открылся в detached HEAD, управляющий чат создаёт свою ветку; если она уже существует — проверяет её checkout, не сбрасывает и не пересоздаёт.
3. В каждом checkout проверить `git rev-parse --show-toplevel`, `git branch --show-current`, чистоту дерева и отсутствие старого активного контроллера. Запускать **копию** `tools/automation/orchestrator.py` из своего checkout: ROOT определяется местом скрипта, а не только cwd.
4. Использовать сохранённый config своей ветки. Для пакета подготовить узкий manifest и выполнить `prepare`. Сохранить новые файлы одним локальным коммитом и запустить очередь с чистого дерева. Engine публикует этот коммит вместе с принятым пакетом и отчётом.

Задания для вставки в новые чаты:

- [Сессия A: iOS и объединение](session-ios.md).
- [Сессия B: сервер, данные и контракты](session-backend.md).
- [Полная карта ID](allocation.json): ровно один ответственный за каждый открытый ID; `contributors` обозначает обязательный вклад второй сессии, а не второй независимый запуск той же задачи.

Оба задания разрешают применение существующего оркестратора с его Developer/Reviewer/QA. Начать с одного активного CLI-контроллера на сессию: два контроллера всего. Дополнительные деревья подагентов на старте не нужны. Сохранить routing и budgets текущего config; квота и ускорение фактически не измерены.

## Публикация и ресурсы

Основной config публикует в `main`. Для очереди A/B явно указывать собственный `--config`. Создайте его один раз в своём worktree, заменив `lane` на `ios` или `backend`.

```python
import json
from pathlib import Path

lane = "ios"  # во второй сессии: "backend"
config = json.loads(Path("tools/automation/orchestrator.config.json").read_text())
config["publish"]["branch"] = f"codex/plants-{lane}"
path = Path(f"docs/validation/automation/runs/parallel-{lane}.config.json")
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("x") as stream:
    json.dump(config, stream, ensure_ascii=False, indent=2)
```

Путь config игнорируется Git. Повторно используйте его для следующих пакетов. При изменении config задайте новый run-id. Типовой запуск готового manifest выглядит так.

```sh
python3 tools/automation/orchestrator.py prepare --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-slice.json
python3 tools/automation/orchestrator.py run --config docs/validation/automation/runs/parallel-ios.config.json --manifest tools/automation/tasks.parallel-ios-slice.json --run-id parallel-ios-slice-01
python3 tools/automation/orchestrator.py summary --run-id parallel-ios-slice-01
```

Подставьте имя своего manifest и уникальный run-id. Для B используйте backend config. Проверки пакета идут внутри `run`. После приёмки используйте опубликованный отчёт engine и `summary`. При остановке возьмите факты из `summary` и запишите следующий шаг в handoff.

У двух веток отдельные run directories и `.doctor.lock`; общий lock действует только внутри checkout. Поэтому **между worktree Simulator не защищён**: Simulator/Xcode UI gates выполняет только A. B запускает Deno и изолированные PostgreSQL/KB checks; Swift-проверки своего серверного пакета передаёт A. Локальные SQL gates должны создавать собственные data/socket/database и не трогать общий Supabase stack. Не выполнять параллельно reset/deploy общего backend. Живые тестовые аккаунты/данные тоже разделять; production не использовать для конкурентных экспериментов.

## Границы изменений

| Область | Единственный автор | Участие второй сессии |
| --- | --- | --- |
| `ios/**`, `ios/project.yml`, pbxproj, xcstrings | A | B передаёт контракт и fixtures, Swift не правит |
| `supabase/**`, SQL migrations/tests, server TS | B | A передаёт требуемый клиентский сценарий/дефект |
| `catalogue/**`, `knowledge-base/**`, `evals/**` | B | A проверяет чтение/вывод и EN/PL UI |
| Машинные/HTTP контракты `specs/001-plants-ios-mvp/contracts/**` | B | A подтверждает совместимость клиента перед изменением wire |
| `.github/workflows/validate.yml` | A | B передаёт проверенные Deno/SQL команды |
| `tools/automation/tasks.parallel-ios-*.json`, новые `parallel_ios_*` gates | A | Только controller-owned подготовка |
| `tools/automation/tasks.parallel-backend-*.json`, новые `parallel_backend_*` gates | B | Только controller-owned подготовка |
| Общие `tools/automation/orchestrator.config.json`, `orchestration/**`, существующие gates | По умолчанию не менять | Необходимое общее исправление сначала передать A, принять и перенести в B до новых runs |
| `docs/handoff_status.md` | Каждый controller в собственной ветке | A объединяет факты обеих веток, сохраняет историю и актуальный Project State |
| `tasks.md`, этот план и карта распределения | A | B передаёт отчёт по ID; checkbox закрывается после полной приёмки и интеграции |
| Остальные spec/plan/data-model/quickstart | A | B передаёт конкретную согласованную правку; scope самовольно не расширять |

Новый серверный контракт сначала описывает B: поля, ошибки, timestamps, owner, legacy read, fixtures и migration version. До принятой передачи A продолжает работать с уже опубликованным `collection-http.md`. B не ломает текущий sync wire ради квот: при неизбежном изменении выделяет отдельный зависимый пакет и согласует его с A. A не вводит временный фиктивный backend. Новые schema/DTO меняются согласованными парами; задача не закрывается по серверной половине.

## Очерёдность и передачи

| Волна | A | B | Условие перехода |
| --- | --- | --- | --- |
| 1, параллельно | Два небольших T162 sync prerequisites: wire DTO/transport → engine/disk checkpoints | T163: таблица перехода квот → SQL clean/upgrade/concurrency gate → серверные правила и API | Уже принятые receipt/auth/cap/HTTP adapters не повторять; T163 не зависит от полного T162 |
| 2 | Catalogue repository/outbox/save/card/cap и локальные UI gates; затем клиент квот T036 | T166 после серверного T163: prepare → media/commit → cleanup/race. Между зависимыми пакетами — T165/T167/T168 server и T148 pipeline | Каталоговый prerequisite можно проверить локально; полный T149 требует T148/T159 и live evidence |
| 3 | Guest/cache/claim и фото/единый результат T150/T170; подключение billing UI | Classification/jobs/media/KB T157/T153/T031–034/T116 и billing T052–054; T169 после T166/T168 | На каждый flow — принятый серверный контракт, без советов от AI и local fallback |
| 4 | Care/card/history/reminders, expiry offline/restart, local trial | T164 после T162/T163; T171 после T164/T165/T167/T169 и применимых карточек; SQL schedule/record/undo | B может готовить независимые компоненты раньше, но родительские зависимости не снимаются |
| 5 | T096/T097, объединённые T155/T098/T099, UI/StoreKit Sandbox, release evidence | RLS/upgrade/integrations T154, eval protocol→cases→eval, load, серверная часть аналитики | Полные продуктовые gates и живые доступы подтверждены отдельно от fixtures |

Номер волны — приоритет, не новая зависимость для всех ID строки. Внутри каждой сессии одновременно исполняется один узкий пакет; независимую работу брать, когда ждёшь артефакт второй сессии. T163 сначала фиксирует серверный контракт и проверки; полная приёмка T163 ждёт клиентский remaining/reset от A. Аналогично смешанные T157–T160/T164–T171 закрываются по обеим половинам.

**Первый обмен:** B передаёт квотный контракт/матрицу переходов и SHA серверного среза → A подключает T036; A передаёт SHA принятых sync/store/save prerequisites и невыданные за live UI fixtures → B получает клиентскую предпосылку T164. Далее каждый пакет передаётся сообщением/отчётом: ID, base и commit SHA, точные файлы/контракт, реально запущенные checks и paths evidence, ограничения, следующий зависимый шаг. Для ожидания второй сессии не создавать дополнительную автоматизацию.

## Объединение без третьего оркестратора

A также выполняет роль интегратора, последовательно со своей разработкой. Это две сессии, а не три. Ни один lane controller не публикует прямо в main. После каждого принятого среза оба push только в свою ветку согласно AGENTS.md; полная готовность задачи и веточная публикация — разные факты.

На чистом дереве **между** runs A получает законченный пакет B обычным merge из `origin/codex/plants-backend` (не переносит непроверенный рабочий diff). B публикует только подготовку или законченный ограниченный пакет и сообщает, какой SHA принят; если tip содержит более позднюю неподтверждённую подготовку, A берёт конкретный принятый SHA. Общий handoff объединять вручную по фактам, не выбирать без проверки `ours`/`theirs`; tasks сверять с картой ID и evidence. Не cherry-pick один и тот же пакет в обе стороны. Никакого rebase чужой опубликованной ветки, reset/clean/force push.

После объединения A повторяет проверки, зависящие от изменённого кода и контрактов: Deno/SQL для серверного diff, Swift persistence/build и нужный UI gate для клиента, schema/KB при их изменении. Старое успешное evidence не доказывает итоговый fingerprint. A сохраняет итоговый handoff/статусы, push своей ветки, затем выполняет обычное fast-forward/merge в main из отдельного чистого checkout **между** runs и push `origin/main`; при движении main сначала интегрирует изменения и повторяет затронутые проверки. В исходном checkout с чужой незавершённой работой интеграцию не выполнять. B подхватывает опубликованную интеграционную точку между своими runs; активный run не прерывать обновлением его HEAD/config.

## Условия готовности

- SQL: clean и seeded upgrade, история/расход/владельцы не потеряны, RLS A/B; гонки настоящими соединениями, для T163 — 20 конкурентных запросов, не последовательные fixtures.
- Swift: новые тесты включены в Xcode target **до** evidence; meaningful tests реально выполнены без skips. Legacy disk decode, pending/retry/lost response/restart/A-B проверены по сценарию.
- UI: build/welcome — baseline; catalogue save, cap/error, фото/result и care требуют своих gates. StoreKit Sandbox/реальный Auth/Storage/provider/физический iPhone указывать отдельно.
- `[X]` только при выполнении полного исходного ID. Accepted slice или успешная веточная публикация не закрывают T149/T155/T162/другие parents автоматически.
- При timeout без answer/patch — точная остановка и новый меньший manifest; не resume старый изменённый контракт. При commit/push failure сохранить фактический результат в handoff и сообщить пользователю.

T172–T174 распределены, но **отложены**: отдельные комнаты вне MVP, автоматически не запускать. Зависимости/контракт simple-rooms сохраняются.
