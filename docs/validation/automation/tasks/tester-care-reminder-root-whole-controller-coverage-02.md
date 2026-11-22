# Whole02: raw results retained; NOT_ACCEPTED_FOR_NONFIRST_COVERAGE

22 ноября 2026. Controller finding, не новая product bug и не переписывание model verdict.

Raw terminal: `COMPLETED`. Проверки:
- diff-check: PASS, 0.024с.
- automation-tests: PASS, 43.287с.
- care-release-compile: PASS, 74.638с.
- ios-tests: PASS, 129.469с.
- tester-consent-ui: PASS, 598.087с.
- tester-notification-routing-ui: PASS, 144.734с.
- tester-result-save-ui: PASS, 59.23с.
- simulator-smoke: PASS, 25.747с.
- tester-care-ui: PASS, 496.532с.
- tester-today-ui: PASS, 200.045с.
- actual reviewer: protocol PASS, 224.85с; semantic answer оставлен без изменений.
- actual qa: protocol PASS, 236.704с; semantic answer оставлен без изменений.

Exact-target/modal/one-shot/per-event foreground подтверждены actual fixtures. NONFIRST НЕ доказан: выбирался max(notification identifier), тогда как actual Store сортирует только updatedAt и CollectionRepository reverses; все3 timestamp равны. Initial-list actual order/PNG отсутствует в положительном case. Метод с NonFirst в названии сам по себе доказательством не является. Reviewer verdict не редактировался после независимого finding; healthy run доведён до terminal.

Следующий узкий actual Developer: только routing-only DEBUG timestamp -2/-1/0 <=Self.time(tick0), IDs/names/owner/anchor сохраняются; cardProjection originalindex<2, Fixture3/noneligible latest. Третий NEW routing UI method captures actualfirst visible list ID/label/frameY и initialPNG+JSON mapping, selectedtarget!=actualfirst, then exactcard/duplicateone-shot. Existing2 routing +old8/13/Today bodies unchanged, no production changes.

После фактического Developer безопасный checkpoint до iOS, реальная provenance/patch/hash; fresh read-only WHOLE candidate_basecc74041 включает7 source paths, strictV4 actual3tests/3namespaces/PNG+JSON+nonfirst +full494Swift/149/Release/MCP/old8/4/13/6/highReviewQA. RawWhole01/V2contractFAIL и все предыдущиеFAIL retained. ParentRoot остаётсяcc, live ещё запрещён.

Private live/read-only proof/build/known-recovery helpers syntax and pure/pastAX checked only; no build/install/API/App/OS/domain writes. Actual knowncleanup ONLY reviewed G1/G2/no-delivery STOP/no ambiguous domain inflight/outbox; not universal early record/hour recovery. OrdinarySystem delivery/tap/cleanup and final Personal/dSYM remain open. Hard50/soft48/no reset.
