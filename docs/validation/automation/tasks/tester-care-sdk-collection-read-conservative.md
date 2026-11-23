# tester-care-sdk-collection-read-conservative

Remove rejected SDK cause attribution; full two-file A union uses conservative in-flight signedOut supersession and stable-new-request login only. Root/UI deferred.

Подготовлен патч: любой signedOut во время чтения возвращает superseded; новый запрос при стабильном отсутствии сессии возвращает loginRequired.

Изменённые файлы: ios/Plants/Features/Catalogue/GuestCatalogueView.swift, ios/PlantsTests/CatalogueConnectionTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 368.16 с, проверки — 298.79 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.02 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01/tester-care-sdk-collection-read-conservative/check-1-diff-check/stdout.log`.
- automation-tests — PASS (fixture, exit 0, 50.98 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01/tester-care-sdk-collection-read-conservative/check-2-automation-tests/stdout.log`.
- care-release-compile — PASS (local, exit 0, 68.93 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01/tester-care-sdk-collection-read-conservative/check-3-care-release-compile/stdout.log`.
- ios-tests — PASS (local, exit 0, 145.62 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01/tester-care-sdk-collection-read-conservative/check-4-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 33.23 с). Лог `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01/tester-care-sdk-collection-read-conservative/check-5-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Удалены TaskLocal, идентификаторы атрибуции и provesTerminalCleanup; сохранены immutable ticket, disruptive barrier и одно свежее строгое чтение.", "Просмотрен полный diff двух файлов относительно 1caab1aedc27a5922784598590611c4d3f495889. После патча добавлено 130 production-строк.", "Программно подтверждена побайтовая сохранность исходного тестового файла вне добавленного блока. Все шесть новых тестовых методов и регрессии режимов 5/6 сохранены.", "Файлы и Git не изменялись. Обязательные проверки выполняет контроллер; PASS означает готовность патча к проверкам.", "Root/UI остаются открытыми; живые интеграции не запускались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-tester-care-20261119/docs/validation/automation/runs/orchestrator-tester-care-sdk-collection-read-conservative-20261123-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
