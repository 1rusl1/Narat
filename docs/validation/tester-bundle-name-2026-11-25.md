# CFBundleName — static acceptance, 25.11.2026

Private commit `5afe8ee80b510fe8248c78513113525be3bf25bd`, base `916109231f000127716a3145660a37d5f322630b`. Только `ios/Configuration/Info.plist`: CFBundleName `$(PRODUCT_NAME)` → `Narat`. Полный sourcefileSHA `3be3a901ad55b0fa867268484a37b282d37ea4a591c8f5a705109531c5a7b508`; patchSHA `eed701543883b088c83ee81db4d244956f48a464f56bc5a2b1599f3e1233bc1b`.

Developer28.502s / Reviewer22.538s / QA27.648s — PASS, findings0. Фактические diff-check, plutil-lint и точный raw+parsed preservation guard — PASS. Raw state `/private/tmp/narat-bundle-name-20261125/docs/validation/automation/runs/orchestrator-nov25-bundle-name-01/state.json`; WAITING/publish = отключённый publish.

Native/Xcode/Simulator/UI/backend0. Это только source/static acceptance; embedded runtimeName PENDING доordinarybuild. PBX/xcstrings/ProductName/executable/bundleID/URLschemes/signing untouched. Root интегрирует единственный plist-патч и свой handoff/commit/push; privatehandoff целиком не переносится.

## Последующий ordinary probe6

Реальная сборка25ноября показала: compiled CFBundleName всё ещё Plants, хотя исходный Info.plist содержит Narat. Строгий build guard FAIL, системный Google-диалог также показывает Plants. Статическая приёмка выше не была доказательством runtime; имя исправляется отдельным generated-metadata пакетом. [Live report](tester-google-catalogue-live-2026-11-25.md).

## Принятое продолжение

[Generated metadata source2](tester-generated-bundle-name-2026-11-25.md) дал actual compiled Name/DisplayName Narat с сохранением всех остальных37значений и ENPL strings. Runtime AS-диалог ждёт ordinary7; прежний FAIL не переписан.
