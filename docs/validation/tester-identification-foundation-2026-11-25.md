# ID-A — внутренний фундамент идентификации, 25.11.2026

Принят компонент на базе `9b9eeebb89d384ee34b0e1cd39f281ff159e83d6`; private commit `b2b303cc445e7077285c1954939acf9ccd10d2dd`. Проверенный source fingerprint `ef2f43ac41a1881137ca8a1682a6612ea3ffcb13311758649b8aa750790fd71b`. Точный четырёхфайловый iOS-патч и SHA каждого файла: accepted-ID-A-source-manifest.json.

Сохранён независимый от AI-вида immutable источник: completed result/job, photo asset, owner, исходный request/JPEG/operation/flow/generation. Добавлен внутренний ticket для ручного published-выбора и отмены. Published scientific/common name, description и image/credit сохранены value projection из уже полученного DTO. Новый UI-маршрут не включён; прежний Confirm/Save сохранён.

Фактически: Developer PASS415.182s; full Swift/build/welcome PASS212.768s (519 total,516/516 XCTest,0 missing); Release PASS102.681s;149 automation PASS64.648s; diff PASS0.048s. High Reviewer PASS87.350s/0 findings, QA PASS82.220s/0 findings. Raw state — `/private/tmp/narat-identification-a-20261125/docs/validation/automation/runs/orchestrator-nov25-identification-A-01/state.json`. WAITING/publish означает отключённый автоматический publish.

Добавлены четыре модельных кейса: identified/unknown→manual/cancel, missing/foreign/changed photo и invalid card, stale/reselected/cancelled/newjob tickets, late old result after replacementphoto. Один wire-кейс отказов неправильного taxon/malformed/unpublished; существующий upload-replay кейс расширен published metadata/attribution. Это fixture/local proof; живое AI/фото/ручной UI/OAuth/physical не проверено.

Далее Root интегрирует четыре source/test файла и свой центральный handoff. ID-B UI/Confirm/Choose another запускается только на объединённой принятой базе ID-A+AUTHB+C1/C2. Продуктовый сценарий идентификации целиком ещё не принят.
