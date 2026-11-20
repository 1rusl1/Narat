# R2b2 unaccepted draft / actual Review findings

Base dfe5a7adf360c15ea675829e036b340baad3d3b0. Original run tester-care-reminder-worker-20261120-01 BLOCKED: Developer3 budget exhausted, Reviewer1 semantic FAIL. Source changes are NOT accepted. Raw malformed first patch preserved; Developer2 applied worker; Developer3 only exact-control Apia fixture expectations.

Actual gates: diff PASS0.049; Swift/build/welcome PASS140.212; xcresult407 total=404XCTest+3SwiftTesting, failures/skips0. Initial Swift FAIL157.175 (three expectations of skippedday also counted future2026routine), preserved. QA/MCP notrun.

[P1] CareReminderScheduler.swift:52–57,390: первый update с известным владельцем B, optedIn=true и state=nil не устанавливает cleanupRequired. Если после предыдущего запуска остались care-уведомления A, reconcile возвращает deferred без удаления, и чужое уведомление может сработать. При первом разрешении владельца очищайте чужие care pending/delivered до defer, сохраняя допустимые уведомления текущего владельца и Trial; добавьте регрессию с новым worker и заполненным inventory.

[P1] CareReminderScheduler.swift:291–298,410–416: корректный canonical ID с route=nil и отсутствующей receipt удаляется без долговременного blocker, если occurrence временно исключён из currentOccurrences, например из-за profileHourPending. Первый проход возвращает failed, но после снятия подавления следующий проход считает ID новым и выполняет add. Отличайте невозможную грамматику ID от временно отсутствующей canonical identity и сохраняйте консервативную блокировку перед очисткой. Добавьте cold-store регрессию: подавление → cleanup → восстановление eligibility → ноль новых add.

No Root/runtime/OS use; current patch is reviewable source only. After narrow repair require full candidate_base union acceptance from dfe before Root.
