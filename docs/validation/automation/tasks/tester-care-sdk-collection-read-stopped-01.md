# A01 остановлен: conservative auth contract, кандидат НЕ принят

23 ноября 2026. Только GuestCatalogueView.swift и CatalogueConnectionTests.swift. Root/UI пока не менялись.

- Developer1 actual566.646с; два файла357+/1-. Diff0.046,149automation50.985,Release89.336,fullSwift/build/welcome222.734 PASS: total500/497XCTest/3SwiftTesting, missing[]. Это fixture/compiler, не live. Исходные494 проверки/старый testsource сохранены вставками.
- Reviewer1 protocolPASS/semanticFAIL191.751с: held refresh A→explicitlogout→terminalHTTP400 превращал sessionMissing в loginRequired из одиночного signedOut, обходя ancestry. RawFAIL не менялся. MCP/QA ещё не выполнялись.
- Developer2 actual173.243с предложил TaskLocal/readID attribution +2terminallogout vectors. Root этот подход явно ОТКЛОНИЛ, независимо от возможных SDK-testPASS. Новая причина из TaskLocal не является выбранным контрактом. Privatepatch SHA256 2e7879d36f9d52ec4af1afe3b96b5ce2c373bd708e89921aa98d5a3b0002caec; raw обеих ролей сохранены в orchestrator-tester-care-sdk-collection-read-20261123-01.
- Diff0.025/149automation51.538 для Dev2 PASS. Попытки stop в automation-окне не послали signal: сначала двойнойprocessmatch, затем gate уже Release. HealthyRelease child не прерывался; controller остановлен только после acquisition общего свободногоresource. Check7 результат engine не зафиксировал — PASS не заявляется. Exit130/WAITING/checks/inflightnil, resource released; Dev2Swift/MCP/Review2/QA не выполнены.

**Новый явный security contract:** любой неразличимый in-flight signedOut, включая собственный terminal cleanup, делает исходный запрос superseded. Только НОВЫЙ explicit read при стабильном missing/signedOut возвращает loginRequired. Никакого автоматического replacement user intent. Удалить TaskLocal/cause-attribution и provesTerminalCleanup. Допустимо исправить только новые Dev1terminal ожидания firstsuperseded→freshlogin; исходные494 assertions не ослаблять.

Следующий шаг: fresh bounded actualDeveloper repair в техже2files с компактным контекстом, затем все5 gates/highReviewQA ВСЕГО A-union от1caab1a. Root/B пока не изменены/не приняты. Этот локальный checkpoint НЕ публикация и НЕ acceptance TaskLocal. Live1371 delivery+canonicalcleanup scopedPASS/centerNOTVERIFIED остаётся отдельным source-доказательством; Personal3 готов. Soft48/hard50/no reset.
