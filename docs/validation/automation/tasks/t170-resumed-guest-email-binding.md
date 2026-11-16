# t170-resumed-guest-email-binding

Check the ordinary email auth binding after cold resume of a guest diagnosis draft.

Подготовлена точечная регрессия email-входа после восстановления гостевого черновика во втором соединении.

Изменённые файлы: ios/PlantsTests/CatalogueConnectionTests.swift.

Вызовы — developer 1, reviewer 1, qa 1. Модели — 209.29 с, проверки — 406.21 с. Повторы моделей — 0, тайм-ауты моделей — 0, тайм-ауты проверок — 0.

Проверки:

- diff-check — PASS (local, exit 0, 0.04 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-resumed-guest-email-binding-ios-codex-20261116-31/t170-resumed-guest-email-binding/check-1-diff-check/stdout.log`.
- ios-tests — PASS (local, exit 0, 238.78 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-resumed-guest-email-binding-ios-codex-20261116-31/t170-resumed-guest-email-binding/check-2-ios-tests/stdout.log`.
- simulator-smoke — PASS (local, exit 0, 167.38 с). Лог `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-resumed-guest-email-binding-ios-codex-20261116-31/t170-resumed-guest-email-binding/check-3-simulator-smoke/stdout.log`.

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Production-код не изменён: дефект исполнения пока не воспроизведён. По коду устаревший scope отклоняется до password HTTP, включая refresh того же владельца.", "Регрессия проверяет Cancel, восстановление SQLite/UserDefaults во втором CatalogueConnection, свежий scope после refresh, отказ устаревшему scope, чужого владельца и ABA; журнал и очереди сохраняются без повторного создания draft.", "SDK сохраняется между соединениями: реальный cold launch, Keychain, Release v33 и живой вход остаются непроверенными.", "Проверки не запускались согласно контракту: полный Swift/EN/PL набор и simulator gates выполняет controller. PASS означает готовность patch к этим проверкам.", "Файлы, handoff/tasks и Git не изменялись; внешние сервисы не использовались."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/private/tmp/narat-ios-initial-context-20261116/docs/validation/automation/runs/orchestrator-t170-resumed-guest-email-binding-ios-codex-20261116-31`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
