# W0 — реальный unknown-контракт фотоанализа

Серверный полезный `unknown` (`succeeded`, `plant_id=null`, квота `consumed`) теперь проходит iOS wire-валидацию. `identified` по-прежнему требует `consumed`; `unknown` допускает `consumed` или `released`, но не `reserved`. Все прочие проверки job/schema/mode/phase/diagnosis сохранены.

Изменены только `APIModels.swift` и один существующий HTTP-тест `CollectionWireTests.swift`: несовместимый отрицательный пример `unknown+consumed` заменён на `unknown+reserved`, добавлен реальный положительный fetch с проверками job/result/plant/quota/status/mode. Остальные методы сохранены побайтно.

Основание: существующие production-path серверные тесты и FR-065 (`spec.md:165`: «Unknown сам по себе не выдаёт бесплатный повтор»). Политику квоты сервера не меняли. Provider `unusable` отдельно нормализуется в тот же wire `unknown` с `released`; качественное различие не передаётся явным reason-code. Диагностический `insufficient_data` — отдельная ветка, не identification-claim.

Реально выполнены: scope+Swift parse, diff-check, полный Swift 544/541 XCTest-метод/0 пропусков, 149 automation, Release, 8 неизменённых серверных identification production-path fixture-тестов. Все PASS. Developer 62.607 с; независимые Astra high Reviewer 66.203 с и QA 82.232 с, замечаний 0. Все шесть проверок выполнены заново на одном source fingerprint.

Это локальная контрактная приёмка. Живое фото unknown, пользовательский manual-claim, B2 UI и физическое устройство здесь не проверялись. Исторический runtime job не запрашивался; старое несовместимое правило сохранено как исходный снимок/тест, а не выдано за новый runtime FAIL.

Оркестратор штатно остановился в WAITING/publish: публикация lane отключена. Root переносит точные два исходника и этот отчёт отдельно, без WIP-цепочки. Следующий шаг: Root landing/push W0, затем B2 использует реальный PhotoAnalysisService с `succeeded/unknown/consumed`, сохраняя original job/photo/owner и отсутствие лишнего AI/upload.
