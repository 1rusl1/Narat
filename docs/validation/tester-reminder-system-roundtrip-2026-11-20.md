# Реальный System adapter: синтетический roundtrip — 20 ноября 2026

PASS для неизменённых production `SystemCareReminderNotifications` и
`CareReminderNotificationFactory` из `fe0b99e4b965cc5d31045139a9789fbf79acac2e`.
На собственном Simulator iPhone 17 Pro / iOS 26.3, в отдельном диагностическом
bundle: один явный native Allow → add → OS pending → trusted route с тем же
attempt/candidate и равными DateComponents → удаление точной заявки.

Календарный trigger не повторяется; синтетическое время было через час.
Pending0→0 после очистки, other pending0→0. Диагностическое приложение удалено.
Доставка, нажатие уведомления и реальный SDK-владелец не проверялись.

## Граница доказательства

В отдельном frozen worktree заменена только точка входа App на
[синтетический View](fixtures/care-reminder-system-diagnostic.swift). Factory и
System adapter не менялись. Root/Core не запускались; локальная конфигурация
backend не копировалась. Это не ordinary Release и не проверка полного
пользовательского сценария согласия. Тестовый View не входит в target приложения.

Первое чтение authorization после завершения request вернуло
`notDetermined`; следующий guard `.authorized` прошёл, после него
заявка добавлена и проверена. Значение второго чтения не логировалось отдельно:
его подтверждает прохождение guard в сохранённом fixture. Немедленный путь
production worker после первого разрешения требует отдельной проверки.

Первая попытка оператора — сохранённый FAIL: native-диалог был на русском,
обработчик искал английский Allow/Plants. Allow0, до add не дошло. Исправлен
только тестовый обработчик на наблюдавшиеся Narat/«Разрешить»; повтор
использовал тот же диагностический бинарник, новая сборка не выполнялась.
Бинарный SHA-256: `2ddbdc19369fbd09479f91c011a2dc8e0288ca806821cc9a3ec9cbadb7d633aa`.
Исходный FAIL не переписан.

[Машиночитаемый результат](tester-reminder-system-roundtrip-2026-11-20.json).
Private evidence: `/private/tmp/narat-system-os-diagnostic-evidence-20261120-fe0b99e-a2`.

## Дополнительная проверка delayed permission readback

Tests-only8086558:425 Swift/build/welcome, Review/QA PASS. Два теста с fake OS
и real Store подтвердили оба случая: первое post-prompt чтение ещё
notDetermined, внутреннее ужеauthorized — pending1 при старом published
authorization; либо обаnotDetermined — pending0 до следующего trigger.
Один retry после обновления OS-статуса вооружает ту же будущую occurrence
без нового prompt/дубля. Product/helper/PBX и прежние423 assertions сохранены.
Это не проверка actual Scheduler+Store/OS; она остаётся следующим техническим
шагом после UI согласия. [Приёмка тестов](automation/tasks/tester-care-permission-readback.md).
