# D3A immutable tap resolution acceptance

## D3A исходная привязка tap и cache-only решение приняты — 22 ноября 2026

Принят 362ba8b974b0a5b02f6dfd5e946a9b010adbb8a6. CareReminderTapCoordinator.swift (167 строк) и CollectionWireTests.swift:
485+/1-, семь новых методов, старые482 проверки/assertions/helper defaults сохранены.
Generic Snapshot:Equatable в Root станет CatalogueSDKSnapshot; Source фиксирует исходные
connectionID/owner/snapshot/locale до await и проверяет original isCurrent. SAME intent
не перепривязывается к A2/новому языку, stale read/intent revision отбрасывается. Initial
unresolved HOLD, definite logout/anonymous/foreign DROP. Fresh injected now после cache
await и перед consume проверяет deadline. Exact consumeOpen требует текущую scope и
доступность показа; HOLD не поглощает tap. Навигации/OS/HTTP/domain effects здесь нет.

Фактические PASS:489Swift (486XCTest+3/missing0), build/welcome156.974с;
149automation42.193с,diff0.024с,MCP27.246с. Developer370.626с,
highReview97.592с/QA93.811с — semantic+protocolPASS/findings0.
Это injected generic epoch/cache fixture tests, НЕ actual Root SDK/native delivery.
Snapshot/wire state fixtures используют существующие typed helpers; OS/auth/transport0.

Далее D3B Root с реальным CatalogueSDKSnapshot/исходной authority, readonly SAME Core
clock/timeZone, currentOccurrences и canonical target. После modal HOLD обязательно
новое чтение, не сохранённый Resolution; definite epoch/logout обрабатывается inactive.
Native foreground только local inventory/cache, не consent.checkStatus/HTTP. Actual
Release + affected legacy/new/routing UI, затем ordinary System/Scheduler/SDK closed-app
доставка+tap/known cleanup/latest signed artifact обязательны. Parenttasks открыты;
technical only/physical+external отложены, fresh26/74/hard50soft48/noreset. Root user3 не тронуты.
