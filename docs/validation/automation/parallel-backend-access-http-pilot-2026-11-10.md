# Plants B — один GET acceptance pilot, 10 ноября 2026

**COMPLETED / Verified and published**, `88a8ea87de6b3ef2d41c1d66f4eb038835638609`,
origin/codex/plants-backend. Единственный разрешённый run `parallel-backend-access-http-pilot-20261110-01` завершён exit0.
**Пилот остановлен; следующего run/пакета/main promotion/CI не было.**
Принят текущий production GET `/analysis/access` в local/mock transport scope.
Код GET/fixtures/protected gate не менялся отa151427; Developer не вызывался.
T163/T036/live остаются открытыми; installation HTTP/worker/alias не добавлялись.

## Подготовка и время UTC

|Событие|UTC10 ноября 2026|
|---|---|
|Первое зафиксированное получение задания|20:00:29.000|
|Перенос/config/gate-input preflight завершён|20:04:39.000|
|Prep commit/push завершён (e4473b9)|20:05:51.843|
|Старт фактического единственного run|20:05:51.859|
|Конец run после commit/push принятия|20:10:01.582|

Подготовка до preflight **250.000с**; до опубликованного prep checkpoint
**322.843с (5мин22.843с)**. Runtime по monotonic **249.722с (4мин9.722с)**.
Из runtime: модельные процессы **167.640с**, семь checks **74.120с**,
прочее **7.962с** (неразложенный overhead запуска/preflight/orchestration/
публикации). Это elapsed/wall, не CPU time; prepare не смешан с runtime.

## Engine/config/предварительные проверки

Обычный merge принятого `25a5830ca5447a3b25e7abd37350759e3e0841f3`
с ancestor cf5a6b1 →`2d1b374de8bc2eec5cd20f09be375fc4ac7015dd`, backend-only push.
Конфликт только handoff: обе истории сохранены, без blanket ours/theirs.
ORCHESTRATOR.md/parallel README прочитаны. Engine source совпадает с принятым 25a5830.

Config SHA256 `0a7d0752cfa4a36d65c8cf0c7df630cb641adfdeabfb272bdf33e1bde608d632`. Изменены только context discovery6/read16000
и preflight; checks/providers/budgets/publish своей ветки побайтно сохранены по JSON compare.
Engine fingerprint `3e69b5df091a1786e5765c85f75584be817d1bacdb5a47ee44d519d8623a1bd1`: SHA256 отсортированных
path+NUL+bytes+NUL всех orchestration/*.py +orchestrator.py (список в JSON/timing).
Manifest `tools/automation/tasks.parallel-backend-access-http-pilot.json`,1 task,
write_files=[], high risk, split Astra, **явный full snapshot audit без candidate_base**.
Пустой сравнительный diff не предъявлялся как доказательство минимальности;
accepted engine/docs — переданный prerequisite, не отдельная бизнес-приёмка repo.

Validate (1 task), context full_snapshot и input preflight PASS:16 inputs / 2 evidence непусты,
5 concrete script paths/executables/testdirs/PG17/pgTAP доступны. Swift inputs нет:
Xcode Sources N/A, configured pbxproj существует; Xcode/Simulator B не запускала.
Ошибок, найденных preflight, — **0**; дополнительных внешних циклов приёмки не было.

## Все модельные вызовы пилота

|Роль|Provider/model|Effort|Elapsedс|Status|Retry|Error category|Prompt kind|Session|
|---|---|---|---:|---|---:|---|---|---|
|reviewer|codex/gpt-6-astra|high|93.515|PASS|0|null|full|01a1c712-52be-7e91-8c58-5cacc2676865|
|qa|codex/gpt-6-astra|high|74.125|PASS|0|null|full|01a1c713-c17d-7b33-8d1d-464b5f558b41|

Developer 0 / Reviewer 1 / QA 1; repair 0 / re-review 0 / retry 0 / fallback 0 / timeouts 0.
Оба prompt full/fresh, resumed_session=null. Prompt bytes Reviewer 26142 / QA 25854.
Использование complexity route Developer и timeout replan guard этим read-only
пилотом **не проверялось**: ни Developer, ни timeout не возникали.

## Фактические checks — один проход каждого

|Check|Mode|Status/exit|Пилотс|Oldrun08с|
|---|---|---|---:|---:|
|deno-check|local|PASS/0|0.138|0.831|
|diff-check|local|PASS/0|0.023|0.020|
|automation-tests|fixture|PASS/0|47.151|38.781|
|deno-tests|fixture|PASS/0|1.822|2.826|
|parallel-backend-access-http|fixture|PASS/0|0.194|0.831|
|parallel-backend-cap-regression|fixture|PASS/0|5.773|6.056|
|parallel-backend-quota-access|fixture|PASS/0|19.019|20.279|

Current suite: **147 automation / 0 failed**, **336 Deno / 0 failed**, **39 protected HTTP / 0 failed**.
SQL clean/seeded-upgrade по**511 pgTAP** (55+49+78+89+113+36+91),12 UTC cases,
preexisting public rows byte-equal. Перед каждым из 6 раундов 20 реальных одновременно
ожидающих соединений — 99 actual admit+finalize; replay/lastslot/failure/exactlyonce PASS.
Cap отдельно — 55+131 pgTAP clean/upgrade+4 real races PASS. Только privatePG/synthetic
identities и actualproduction/Supabase-client **mock** transport; не deploy/live
Auth/Supabase/Storage/provider/StoreKit. Ни критерии, ни risk, ни tests не ослаблены.

## Ближайший baseline и ограничения сравнения

Old run `parallel-backend-quota-access-http-20261110-08`: тот же GET behavior и39 HTTP / 336 Deno / 511 SQL / cap, но writable
confirmation task (Developer вернул patch 0), старый engine/preflight,123 automation,
QA прервана владельцем. Все его вызовы:

|Роль|Model|Effort¹|Process elapsedс|State / process|Retry|State error / process error|Prompt kind|Session|
|---|---|---|---:|---|---:|---|---|---|
|developer|gpt-6.1-sol|high|68.111|PASS / process PASS|0|null / none|full|01a1c3b6-f24e-70f3-bb6d-4c76a20d729f|
|reviewer|gpt-6-astra|high|77.672|PASS / process PASS|0|null / none|full|01a1c3b9-1738-7eb2-8e1c-6b236b1d49fc|
|qa|gpt-6-astra|high|28.559|STARTED / process FAIL|0|null / interrupted|full|unknown|

¹Legacy state не записывал reasoning_effort; high подтверждён argv каждогоprocess.json.
У old QA state elapsed=null/STARTED, process.json фиксирует 28.559 с и interrupted; state
не переписывался. Old QA не была принята. Точный полный oldruntime отсутствует;
completed state model elapsed145.783 с и raw process observed 174.342 с (включая
прерванную QA) — разные представления, не два суммируемых расхода. Checks69.624 с.
Старых timeout 0; interruption 1 — **не timeout**. Повторов/repair/re-review0.

Удалён лишний Developer-вызов, который в старом подтверждении готового кода занял
68.111 с. Но read-only checks-first уже существовал до нового engine: это выбор
workflow, а не доказательство эффекта новой complexity routing. Reviewer нового
пилота **93.515 с против 77.672 с**, prompt 26142 против 22843 bytes (+3299 bytes).
Discovery 6 не обрезает явные пути; snapshot/preflight/контекст отличаются.
Automation увеличилась123 → 147 и заняла47.151 с против 38.781 с.

Quality contracts **не совпадают**:
- old:`90557079f2a7c4b00241dd29413734937c73bea6898adcc3dfecb03c58904862`;
- pilot:`5eb586012da3411ff4a3838f7f066cb5656d6903855d5b589e3efa9c533161f4`.

Три AC и mandatorycheckspecs сохранены, но write_files/description/constraints/files/
preflight/snapshot scope изменились; baseline не имеет принятойQA. Автоматическое
сравнение не нашло matching quality contract, старый per-accepted denominator 0.
**Причинное ускорение не доказано; процент ускорения не рассчитывается.**
CLI input/output/cache counters не суммировались, в процент квоты не переводились.

## Артефакты и остановка

[Структурированные измерения](parallel-backend-access-http-pilot-2026-11-10.json),
[подготовка](parallel-backend-access-http-pilot-prep-2026-11-10.md),
[task report](tasks/parallel-backend-t163-access-http-pilot.md).
Локальные ignored raw evidence:
- `docs/validation/automation/runs/orchestrator-parallel-backend-access-http-pilot-20261110-01/state.json` иmetrics.jsonl;
- `runs/parallel-backend-access-http-pilot-timing.json`;
- `runs/parallel-backend-access-http-pilot-preflight.json`;
- `runs/parallel-backend-access-http-pilot-comparison.json` (CLI metrics compare).

После terminal проверен process inventory: активных B controller/model processes — 0.
Сейчас только сохранение report/handoff commit/push своей ветки; product runs
**ровно 1**, следующий не запускается. Ждать оценки владельца и новой явной команды.
GitHub Actions/T006/main promotion/полная интеграционная приёмка/installation HTTP/
worker/alias вне пилота; продуктовые checkbox B не закрывала.
