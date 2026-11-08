# t152-api-persistence-unavailable

Первый ограниченный срез T152: убрать фиктивные подтверждения сохранения и пустой успешный sync из штатного plants-api, пока реальные persistence handlers не подключены. Это backend safety, не полная приёмка T152. Патч подготовлен Sol в run t152-api-001, остановленном из-за устаревшей static-команды. Провести независимую приёмку текущего кандидата целиком, включая новый regression test; отсутствие нового diff не заменяет чтение реализации.

Текущая реализация и новый regression test прочитаны целиком. Исправления не требуются; кандидат готов к проверкам контроллера.

Изменённые файлы: нет.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-api-002/t152-api-persistence-unavailable/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-api-002/t152-api-persistence-unavailable/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-api-002/t152-api-persistence-unavailable/check-3-deno-tests/stdout.log`
- t152-api-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-api-002/t152-api-persistence-unavailable/check-4-t152-api-tests/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Без handlers оба маршрута после requireActiveOwner возвращают 503 INTERNAL_ERROR с retryable=true и сообщениями EN/PL, не читая body и не создавая фиктивных подтверждений.", "Переданные handlers получают исходные параметры; их Response и существующая обработка ошибок сохранены.", "Новый тест охватывает три префикса, повторные команды, malformed body, guards, делегирование, ошибки, health и OPTIONS.", "Конституция и применимые разделы контрактов прочитаны. Проверки оставлены контроллеру; файлы и Git не изменялись.", "Fixtures не подтверждают deployed API, outbox или UI. Полная T152 остаётся открытой."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t152-api-002`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
