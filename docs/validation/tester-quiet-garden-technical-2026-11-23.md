# Narat: принята техническая версия Quiet Garden

23 ноября2026. Кандидат `a131e57d45fc0c597cba6a03ae4aaf7d4c6def51`, fingerprint `de92a2afa571cb2ce2c73cdb1d0051c5ae290e08d5e5dc98595540597f5b2c0f`. Принят для технической приёмки с перечисленными ограничениями. Все14 наборов реально выполнены заново; независимый Review PASS195.604с и QA PASS263.734с, замечаний0. Обе роли прочитали полный diff229243символа/36путей/24iOS и текущий отчёт Root44.

## Что изменено

Фирменный Quiet Garden: адаптивная палитра, SF Pro/Dynamic Type, кнопки, карточки, формы и статусы существующих экранов. В карточке сначала растение/фото/уход/журнал, затем правки. Декоративные иконки Home/Today ограничены24×24 и не мешают крупному тексту. [Карта исходников и визуального покрытия](../quiet-garden-coverage-2026-11-23.md).

Отдельно принят технический B: наблюдаемое открытие коллекции связано с текущим запросом и guards сессии/владельца/локали; позднее завершение не подменяет новое представление. SDK2 проверяет refresh/read и явный signout на локальном тестовом транспорте. Исходная живая причина transient-login не считается доказанной этим исправлением.

Точные24 iOS-пути/SHA перечислены в JSON:8 production UI/theme Swift +2 DEBUG fixture Swift +3 test Swift +11 цветовых JSON. PBX/xcstrings пользователя не включены. Root переносит bytes из принятого коммита, а не private WIP-историю. Полное ожидаемое iOS Git-дерево: `bcee2aea03537bce09138d5bcaf095b273c8a787`; staged/postcommit равенство фиксируется отдельно.

## Реально выполненные проверки

| Набор | Результат | Секунды |
|---|---|---:|
| diff-check | PASS | 0.024 |
| automation-tests | PASS | 46.402 |
| care-release-compile | PASS | 82.988 |
| ios-tests | PASS | 137.558 |
| simulator-smoke | PASS | 17.882 |
| tester-00-00-qg-ordinary-ui | PASS | 48.872 |
| tester-00-01-qg-visual-ui | PASS | 356.197 |
| tester-00-foreground-ui | PASS | 207.354 |
| tester-00-notification-routing-ui | PASS | 574.148 |
| tester-01-sdk-opening-ui | PASS | 55.224 |
| tester-consent-ui | PASS | 1619.715 |
| tester-result-save-ui | PASS | 63.093 |
| tester-care-ui | PASS | 514.892 |
| tester-today-ui | PASS | 207.978 |

149 automation — PASS. Swift508 — PASS, включая все505 XCTest-методов без пропусков; transport local/fixture, не live. Ordinary2 проверяет польский интерфейс и системный AccessibilityXXXL. Alias меняет только порядок исполнения ordinary/visual до длинных UI; scripts/assertions/timeouts/models не ослаблены.

Контроллер завершился exit1 в ожидаемой фазе WAITING/publish: публикация отключена, ошибок/активного check нет. Wrapper exit0. Root выполняет проверенный перенос/commit/push отдельно; это не productFAIL. После терминала engine сгенерировал два отчётных Markdown-пути в private lane; iOS-код и binarypins не изменены.

## Визуальная приёмка

Root фактически просмотрел все44 текущих PNG через12 контактных листов; care_sources независимо просмотрел22LIGHT и исходные проблемные кадры. SHA всех44 повторно совпали. P2L01 устранён в EN/PL и обеих темах. Новых блокеров нет; небольшой повтор заголовка настроек остаётся P3. Это representative PASS с ограничениями, а не полная QG7. Capture PASS сам по себе приёмкой не считался; [отклонённый предыдущий f352](tester-quiet-garden-visual-blocker-2026-11-23.md) сохранён.

## Ограничения и следующий шаг

- Приёмка техническая: локальные/fixture-сценарии и представительные снимки; новая живая/физическая/внешняя приёмка не проведена.
- Полная QG7-матрица всех состояний, VoiceOver, клавиатуры, узкого экрана и TodayXXXL остаётся открытой.
- Новые обычные подписанные сборки0.1.0(4) создаются следующим этапом; Personal3/source1371 — отдельные исторические доказательства.
- Покупки и расширение рекомендаций отложены; T075/T077/T080/T098 и полныйMVP не закрываются.

Следующий шаг: точное staged/postcommit iOS-tree equality, code commit/push, чистый checkout этого Root commit, обычные подписанные Simulator/Personal0.1.0(4), App/dSYM UUID+подписи+19DEBUG-exclusion, пакет и инструкция. Установку/новую native delivery/AI ради этого этапа не выполняли. [Машинные результаты и44SHA](tester-quiet-garden-technical-2026-11-23.json).
