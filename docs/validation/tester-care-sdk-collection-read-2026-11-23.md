# A: строгий collection-opening read — 23 ноября 2026

**Срез A проверен; Root/UI-сценарий пока открыт.** Изменены только `GuestCatalogueView.swift` и `CatalogueConnectionTests.swift`. Полный двухфайловый diff проверен относительно `1caab1a`, не только последний repair.

Новый read допускает одну свежую строгую попытку при доказанной цепочке tokenRefreshed той же identity. Старые snapshot/model/lease остаются недействительными. Любой in-flight signedOut даёт superseded; только новый explicit read стабильного missing/signedOut даёт loginRequired. TaskLocal и попытки приписать событию причину удалены. Базовые sessionSnapshot/validate/bind и494 assertions сохранены; Root/SDK pin/config/backend не менялись.

Реальные проверки final candidate: diff0.024с;149automation50.984с; ordinaryRelease68.932с; fullSwift/build/welcome145.617с (500total,497/497XCTest,3SwiftTesting,missing[]); MCP33.235с — PASS. Developer109.610с, независимые highReview116.633с и highQA141.915с — semanticPASS, findings[]. Роли проверили весь A-union от1ca. Это изолированные SDK/HTTP/SQLite fixtures и compiler/MCP, не новая живая интеграция.

История сохранена: первоначальный Developer566.646с и его отдельные проверки PASS; Review191.751с FAIL на heldrefresh→explicitlogout→terminal400, не retroPASS. Developer173.243с предложил TaskLocal, отклонённый Root. Controlledstop130 выполнен после освобождения ресурса без прерывания healthyXcode; исходный run WAITING/checks. Поздний Release result engine не зафиксировал, PASS ему не приписывается. Локальный WIP с TaskLocal не публикуется.

Final conservative run намеренно WAITING/publish, exit1: все5 checks и Review/QA прошли, commit/push отключены. Это не ошибка проверки и не заявление о публикации. Точные проверенные filehashes/patchhash и durations — в JSON. Root перенёс только эти два проверенных файла и отчёты поверх1ca с точным совпадением проверенных SHA256, без WIP-ancestor.

Ограничения: Root My plants ещё использует прежний try?; UI исправление и actualrendered regressions относятся к B. Причина наблюдавшегося живого false-login неизвестна. Реальная доставка/cleanup на1371 — отдельный scopedPASS; финальный Notification Center visual не проверен. Personal3/dSYM уже готовы для1371. Parent tasks/physical/external/fullMVP открыты.

Следующий шаг: fresh usage и отдельный B: весь A+B union, реальный refresh внутри My plants, current-request/locale fences, signedOut negative и необходимые старые UI gates/highReviewQA. Последний usage39%; soft48/hard50, reset запрещён.
