# Задание для сессии A — iOS и объединение

**Приоритет 11 ноября:** следовать [критическому пути MVP](../../specs/001-plants-ios-mvp/critical-path.md). Прежняя очерёдность ниже сохранена для зависимостей; новые пользовательские проверки только на EN.

Ты — первый из двух управляющих чатов Plants/Narat. Работай в отдельном Worktree на ветке `codex/plants-ios`. Выполняй работу, а не только планируй. Используй существующий Python-оркестратор с его Developer/Reviewer/QA для узких пакетов. Второй чат ведёт backend/SQL/KB; на старте не создавай дополнительные деревья подагентов. Правила AGENTS.md обязательны: русский, короткий ответ, handoff после этапа, commit/push своей ветки, секреты/артефакты не публиковать.

Сначала прочитай `AGENTS.md`, `docs/parallel/README.md`, свои ID в `docs/parallel/allocation.json`, текущий верх `docs/handoff_status.md`, Project State и `specs/001-plants-ios-mvp/tasks.md`. Общие правила worktree, веточного config, ресурсов и интеграции находятся в README. Нельзя запускать default config с publish в main. Стартовые runtime-checkbox 14/151 планированием не менялись. После полной fixture-приёмки T162 `532984c` — 15/151; текущий источник статусов tasks/handoff.

## Результат и границы

Твоя область: `ios/**`, клиентские DTO/repository/outbox/sync, EN/PL UI, Simulator/UI tests, StoreKit-клиент/локальные reminders, CI и сквозная приёмка. Изначально A назначены 59 открытых ID; после T162 осталось 58; точный список и вклад B в смешанные ID — allocation.json. Единолично управляешь закрытием tasks и объединением в main по фактическим доказательствам. SQL/TS/KB/машинные контракты сам не правишь: передавай точное требование B и продолжай независимую клиентскую работу. Условия ухода/лимиты не выдумывай на клиенте.

Уже приняты, не переделывать: T161 server cap/retired slots, fail-closed auth `9551807`, production sync `c26a4e0` и catalogue create `88345ed`; typed create receipt `e8a12fe` (кандидат `cf084e3`), 35 фактических PlantsTests, включая 6 CollectionWireTests. Endpoint ещё не означает UI save: typed method не подключён к outbox/UI. `t162-client-sync-wire` завершился timeout900s без answer.json/patch — не реализован. Старые run-01/run-02 evidence и manifests не переписывать и не resume с новым контрактом.

## Первый этап: два узких sync-пакета

До реализации подготовь **новый** manifest `tools/automation/tasks.parallel-ios-sync-transport.json`; затем отдельный зависимый `tasks.parallel-ios-sync-store.json`. Это замена слишком большого следующего шага, не повторная приёмка receipt. Branch config — игнорируемый `docs/validation/automation/runs/parallel-ios.config.json`, publish только `codex/plants-ios`. Выполни `prepare` и сохрани новые входы пакета локальным коммитом. Engine опубликует его при приёмке. Используй новые уникальные run IDs `parallel-ios-sync-transport-...` и `parallel-ios-sync-store-...`. Внешние предпосылки уже принятых SHA запиши в constraints/files; `depends_on` внутри JSON ссылается только на задачи этого manifest.

**A1, DTO/transport (без engine/store/UI):**

- Read: `contracts/collection-http.md`, текущие `APIModels.swift`, `PlantsAPIClient.swift`, `CollectionWireTests.swift`, `SyncEngine.swift` и SQL `202611090004_retire_free_slots.sql` только для сверки wire.
- Write: только `ios/Plants/Data/Remote/{APIModels,PlantsAPIClient}.swift`, `ios/PlantsTests/CollectionWireTests.swift`. По возможности расширять уже включённый test file; новый Swift-файл требует controller XcodeGen/pbxproj до evidence.
- Отдельный canonical SyncWire DTO/transport method: `until/has_more/last_cursor/next_since/profile/entitlement/changes`, nested JSON data и tombstone null. Explicit owner из authenticated session; не придумывать response owner/default UUID. Старый fetchSyncPage/DTO/публичные initializers до A2 не ломать.
- Сохранить точные timestamp strings с микросекундами/offset для outgoing since/until/cursor; helper SQL timestamp уже есть после receipt. Не округлять в Date→ISO. Согласованно проверять окно, cursor, next_since и malformed envelope; ошибки не превращать в пустой успех.
- Проверки actual APIClient с mock transport: реальные SQL-shaped JSON, пустая страница с profile/entitlement, nested/tombstone, fractions/offset, параметры запроса/заголовки, invalid pagination и transport/auth/503. Не заявлять checkpoint/restart по одному decode fixture.
- Gates: `diff-check`, `ios-tests` (все существующие 35 и новые действительно выполнены, без skips), `simulator-smoke`; независимая приёмка по реальному risk. Это local/fixture transport, не live/UI acceptance.

**A2, engine/disk (только после принятого A1):**

- Write: `SyncEngine.swift`, `LocalStore.swift`, `CollectionWireTests.swift` и только необходимые remote файлы A1. Оставить существующий outbox/sync; не создавать второй framework.
- Подключить canonical pages, точные `since/until/last_cursor/next_since` через disk checkpoint/restart; legacy Date checkpoint читается совместимо, новые границы не переупаковываются с потерей точности.
- Все страницы одного окна staged; ошибка/некорректная/непродвигающаяся страница сохраняет прежний cache/checkpoint/outbox. Profile/entitlement не теряются даже при пустом changes; retired slots/rooms не оживают. Отмена/смена сессии A→B не применяет данные/commands A с токеном B.
- Meaningful tests: APIClient→engine→реальный disk LocalStore, две страницы/точный outgoing cursor, failed page atomicity, restart и следующий запрос с исходным next_since, legacy disk, tombstones, owner switch/session change. Обязательны те же build/unit/Simulator gates.

После приёмки используй опубликованный отчёт engine и сводку `summary`. Укажи следующий шаг. Полный T162/T025/T026/T149 пока не закрывать. Передай B принятые SHA sync/store prerequisites; полный T164 всё ещё ждёт T162/T163.

## Следующие пакеты

1. Repository над существующим outbox + catalogue→login/cancel→save→card: server-confirmed plant ID/receipt, cap до операции и server rejection, отсутствие ложного локального успеха, stable operation/payload, lost response/pending/restart/A-B. Удалить оставшиеся FreeSelection writers; legacy decode сохранить. Отдельные UI gates Free/paid/cap/error, не один welcome. T149 не закрывать до T148/T159 и требуемой live приёмки.
2. По переданным контрактам B: T036 квоты/remaining/reset, guest seven-day/cache/claim T023/T046, фото/identification/единый результат T037–039/T100/T101/T150/T170. Сохранять ввод при отмене/ошибке, никакого deleted-draft fallback/фиктивной диагностики.
3. Billing/client paywall/resume/trial reminders и expiry; care/card/history/record/undo/reminders. T164/T171 выполнять по совместным server/client gates, не активировать автоматику после expiry ручной записью. Прочие твои ID и зависимости — allocation/tasks.
4. Интегрировать законченные серверные пакеты B **между** runs, сохранять обе ветки handoff, проверять итоговый fingerprint. CI и T096/T097/T126/T146/T155/T098/T099 вести по README; StoreKit Sandbox/Auth/Storage/AI/physical camera не выдавать за fixture PASS. Если доступ отсутствует — зафиксировать точный оставшийся gate, продолжать доступную работу.

Владение Simulator только у тебя; B не запускает эти gates. Общие tools config/engine не менять одновременно: необходимое исправление согласовать и передать B отдельным завершённым пакетом. Публикация в main — только интеграционный шаг, не CLI publish lane config. T173/T174 комнаты оставлены отдельным расширением: в текущий MVP run не включать.
