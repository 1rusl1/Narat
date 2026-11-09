# Задание для сессии B — backend, данные и контракты

Ты — второй из двух управляющих чатов Plants/Narat. Работай в отдельном Worktree на ветке `codex/plants-backend`. Выполняй работу, а не только планируй. Используй существующий Python-оркестратор с его Developer/Reviewer/QA для узких пакетов. Первый чат владеет iOS и объединением; на старте не создавай дополнительные деревья подагентов. Правила AGENTS.md обязательны: русский, короткий ответ, handoff после этапа, commit/push своей ветки, секреты/артефакты не публиковать.

Сначала прочитай `AGENTS.md`, `docs/parallel/README.md`, свои ID в `docs/parallel/allocation.json`, текущий верх `docs/handoff_status.md`, Project State и `specs/001-plants-ios-mvp/tasks.md`. Перед run создай игнорируемый `docs/validation/automation/runs/parallel-backend.config.json` с publish только `codex/plants-backend` и явно используй `--config`. Default publish в main запрещён. Runtime-продуктовые checkbox сейчас 14/151; планирование их не меняло.

## Результат и границы

Твоя область: `supabase/**`, SQL clean/upgrade/RLS/concurrency, Edge API/worker/billing, контракты/schema, каталог/KB/evals. 78 открытых ID и обязательные вклады A — allocation.json. Swift/pbxproj/xcstrings не правишь; передаёшь A точный контракт/fixtures/принятый SHA. Handoff обновляешь только в своей ветке; tasks закрывает A после интеграции и всех необходимых gates. Не объявлять mixed parent выполненным по серверной половине.

Уже приняты, не повторять: T161 cap/slots (`b5f2c8f`, `01ba170`, `eb58c03`), fail-closed auth `9551807`, production sync `c26a4e0`, catalogue plant.create `88345ed`. В A продолжаются canonical sync DTO/transport, затем engine/disk и save UI. На время первой волны текущий `collection-http.md` — стабильная граница: менять wire только отдельным согласованным пакетом; квоты не должны ломать sync.

## Первый этап: T163, серверные квоты

T163 зависит от принятой T161, не от завершённой T162. Он выполняется параллельно клиентскому sync. Не брать целиком большой T158/T163 в один timeout900s. Сначала перечитать FR-065 и текущие определения RPC/таблиц, затем подготовить следующие ограниченные пакеты:

**B0, контракт перехода и trusted gate:**

- Read: `spec.md` FR-005/017/065, access/billing contracts, `supabase/migrations/202610200001_ownership_sync.sql`, `202610200007_analysis_quota.sql`, `202610200012_quota_operations.sql`, последние переопределения в `202611090001_analysis_mode_guard.sql`, `_shared/AnalysisAccess.ts`, `plants-api/{installations,analysis-access,analysis}.ts`, quota/analysis SQL и Deno tests.
- Зафиксировать небольшой контракт `specs/001-plants-ios-mvp/contracts/monthly-access.md`: anchor регистрации постоянного аккаунта, UTC instant/короткие месяцы/29–31 число/високосный год; два starter и режимы по spec; Free=3, paid/trial=100; переходы trial→paid/restore/expiry без refill; API remaining/reset/error. Не подменять правила spec новым предположением; явную неразрешённую неоднозначность передать владельцу, продолжать независимые части.
- Таблица переноса существующих consumed/reservations/ledger: считать сохранённый расход ровно раз, active leases/старые periods/retry не выдавать повторно. Неопределимый расход не обнулять молча. Применённые миграции не переписывать.
- Controller-owned подготовка: новый `tools/automation/parallel_backend_quota_gate.py`, независимый temp PostgreSQL17/pgTAP clean/seeded-upgrade и **20 реальных одновременных соединений** на последний остаток, независимые IDs + same-operation replay/finalize/technical failure. Не заменять этот gate старым cap runner или наличием SQL файла. Проверить, что gate действительно ловит старые правила, без объявления ожидаемого провала успешной продуктовой приёмкой.
- Создать новый точный manifest `tools/automation/tasks.parallel-backend-quota-sql.json` и branch config с отдельным check ID в **этой копии config**, не менять общий default config. Записать argv/mode/timeout и hash config в отчёте подготовки. Внешние принятые SHA — constraints, `depends_on` только для ID того же manifest. Validate/context/diff-check, handoff, commit/push подготовки перед run.

**B1, SQL и расход:**

- Write scope: новая forward migration `supabase/migrations/<следующая-свободная-версия>_registration_quotas.sql`, конкретные quota SQL tests/seed. До выбора версии проверить текущий HEAD и существующие migration names; не переиспользовать применённый номер.
- Реализовать registration anchor/Free=3/paid=100/два starter и безопасный upgrade, atomic reserve/finalize/release/retry/owner isolation. Сохранить owner lock, provider budget и T161 collection cap. Коллекционный cap и месячная quota — разные ограничения.
- Acceptance: clean и populated upgrade с неизменностью владельцев/истории/ledger; конец месяца/граница/високосный день; переход тарифа без reset/двойного счёта; реальные 20 concurrent admission, replay/finalizeOnce/technical failure, A/B. Deno regression/typecheck и diff-check также обязательны. SQL fixture/concurrency evidence — не live Supabase.

**B2, API/access mapping (после принятой B1):**

- Новый небольшой manifest `tasks.parallel-backend-quota-api.json`: только необходимые `_shared/AnalysisAccess.ts`, `plants-api/{analysis-access,installations,analysis}.ts`, связанные Deno tests, worker лишь при реальной необходимости и отдельном bounded scope. Не переписывать unrelated auth/collection handlers.
- Реальный production adapter/RPC args, серверные remaining/reset/стартеры/ошибки; purchase/restore/claim не меняют anchor/расход. Подготовить EN/PL error mapping и canonical fixtures, без фиктивного успеха.
- Gate: actual handlers/adapter с mocked HTTP transport, Deno typecheck/full tests + SQL regression, независимые Review/QA по риску. Подготовку сохранить отдельно, запуск из чистого дерева с новым run-id.

После каждого пакета: handoff, commit/push своей ветки; A передать ID, принятый SHA, контракт/fixtures, выполненные проверки/paths и ограничения. **Полный T163 остаётся открытым до проверки клиентского remaining/reset A (T036).** До этого B может продолжать независимую серверную работу. Simulator/iOS gates не запускай: они принадлежат A.

## Следующие пакеты и зависимости

1. T166 после серверных предпосылок T161/T163: узко prepare/proof/TTL → media/copy/commit → cleanup/race; семь дней от success, cap, lost response/replay, no local_fallback, реальные RPC signatures и photo ownership. Судьбу analysis_receipt решать после поиска всех consumers; operation receipts/claim proof сохранять. Для полного ID нужен клиент A и отдельный live API/Storage gate. Параллельно не поднимать общий Supabase stack, использовать изолированные fixtures.
2. Независимые T165/T167/T168 server: убрать report/server notification claim, product/SKU/timer dependence и camera-light writers, сохранив historical read/applicability. Trial reminder реализует A по verified trial date. Уже принятый `dadfcb1` client light cleanup не повторять; полный T168 ждёт SQL/API guards/legacy resubmission.
3. T148 реальная редактура 606 карточек/медиа/import и компактная KB: T108/T109→T111→T112/T113→T115/T021/T116; rights/EN/PL/unknown/rollback. Принятые Condition2/Plant2 и schema cleanup T157 не переписывать. AI только classification; советы выбирает resolver из проверенных карточек. T118 протокол **до** T093/T094 публичного eval.
4. Classification/jobs/media T005/T029/T031–034/T153, billing T012/T050/T052–054, RLS/deletion T015/T016/T082/T083 и upgrade T154 — по своим ID/предпосылкам. Серверные части смешанных T069/T105/T106/T132/T134 передавать A; ownership всех исходных задач единственный в allocation.
5. T169 после T166/T168. Полный T164 ждёт T162/T163; затем T171 ждёт T164/T165/T167/T169 и пригодных опубликованных данных. Один SQL ScheduleCalculator; ручные record/undo/backdate не возобновляют paused/expired автоматику. Связанные проверки/первую помощь/историю синхронизировать с A.
6. Передавать A принятые backend commits между runs. A интегрирует и публикует main; после согласованного интеграционного SHA обычным merge обновляй свою ветку между собственными runs. Не делать force push/rebase/reset и не менять HEAD/config активной очереди.

В ожидании внешнего артефакта выбирать независимый свой пакет, не обходить зависимость фиктивными данными. Недоступные live OAuth/StoreKit/Storage/provider/публичную разметку честно фиксировать; fixture PASS их не заменяет. T172 комнаты распределена тебе, но отложена как отдельное расширение: в текущую MVP-очередь не включать. Подробные общие границы/интеграция/готовность — `docs/parallel/README.md`.
