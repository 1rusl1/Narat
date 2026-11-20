# iPhone: проверка сборки и подписи — 20 ноября 2026

**PASS только build/signature/archive.** Изолированный clean source
`efa9ddcab22987baccf8a62a15fcbaa0a24f51a6` (принятый R1b1, без R1b2/R2/R3).
Обычная configuration Personal, `iphoneos`, bundle `app.narat.plants.personal`,
версия0.1.0/build1. Бинарник SHA-256:
`e811fb8bd5fb1b2ace75f45536116644922c31c1f84462d456a1b2c81e60da36`.

Реально выполнены xcodebuild (BUILD SUCCEEDED), codesign strict/deep до и после
архива, проверка embedded provisioning profile для назначенного iPhone и команды,
actual bundle/backend, выключенного Apple sign-in и исключения DEBUG fixtures.
Существующий профиль истекает **24 ноября2026,19:19:31MSK**; срок финальной
сборки необходимо сверить заново. Apple portal/provisioning updates не выполнялись.
Рабочий root с пользовательскими изменениями не использовался как source.

Установка/запуск/интерфейс на телефоне и доставка уведомлений НЕ проверены.
Это ранняя проверка доступности подписи, не финальный артефакт тестировщика.
После R3 нужна новая обычная сборка по окончательному accepted SHA, установка
и scoped physical/handoff. Логи, device inventory, embedded profile и подписанный
архив остаются private; удалены только собственные build intermediates после
сверки архива. Shared package cache и свидетельства проверок сохранены.

[Машинный отчёт](tester-iphone-signing-preflight-2026-11-20.json).
