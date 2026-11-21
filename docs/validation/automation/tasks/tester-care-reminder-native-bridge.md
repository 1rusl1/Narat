# D2A native transport acceptance

## D2A типизированный мост уведомлений принят — 22 ноября 2026

Принят eaaef440eb46b43988391e528a86c86f5c15a239: CareReminderNotificationBridge.swift
и CollectionWireTests.swift, 319+/1-. Общий Debug/Release launch-policy блокирует все
старые/новые/повреждённые fixture families; bounded MainActor inbox сохраняет один tap,
не теряет его от foreground, подавляет повтор и stale consume. Inert NSObject bridge
синхронно разбирает payload, завершает native callback ровно один раз; через Task
передаётся только Sendable event. Оба optional SDK selectors проверены responds(to:).

Фактические PASS: 478 Swift (475 XCTest+3, missing0), build/welcome161.397с;
149automation41.789с, diff0.039с, MCP23.871с. Developer326.233с,
highReview82.103с/QA85.666с — protocol+semanticPASS/findings0.
Это unit/local/fixture transport и compiler witness, НЕ actual OS callbacks/регистрация/
SDK routing/доставка. Исторические FAIL/STOP и WholeB ограничения сохранены.

Далее D2B ранняя strong AppDelegate регистрация и тот же Inbox в Root, общая изоляция
Debug/Release, actual Release compile + affected legacy/new UI. Затем D3 immutable
SDK/lease/locale-bound one-shot canonical target и foreground local-only refresh;
ordinary System/SDK closed-app delivery+tap/cleanup и финальная signed сборка остаются
обязательными. ParentT075/T077/T080/T098 открыты, technical only; physical/external отложены.
Freshusage24/76, hard50soft48/reset запрещён. Root protected3 не тронуты.
