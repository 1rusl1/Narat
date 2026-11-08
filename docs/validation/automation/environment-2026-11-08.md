# Этап 1 — окружение и терминальный smoke, 2026-11-08

Результат: **PASS для этапа 1**. Это проверка инструментов, двух CLI-сессий и стартового экрана; продуктовые задачи не закрывались.

## Реальные прогоны

```sh
python3 tools/automation/doctor.py --check-models --check-ios --run-id stage1-20261108-final
```

Команда завершилась с exit 0; `summary.json` — PASS. Локальные доказательства:

- `runs/stage1-20261108-final/summary.json`: команды, результаты, длительности и пути stdout/stderr.
- `runs/stage1-20261108-final/model-{developer,qa}.stdout.log`: JSONL двух независимых новых сессий; корректные ответы с уникальными nonce, завершённые turns, без зафиксированных command/file/MCP/web items.
- `runs/stage1-20261108-final/ios-build.stdout.log`: `build-for-testing`, exit 0, 12,84 с на прогретом кэше.
- `runs/stage1-20261108-final/welcome.xcresult` и `welcome-result.stdout.log`: **1 passed, 0 failed, 0 skipped**, result Passed. Тест `PlantsUITests/PlantsUITests/testWelcomeScreenDisplaysBothEqualIntents` действительно запустил приложение и проверил заголовок/две кнопки.
- `local-ui-configuration-verified`: PASS, перед UI проверены пустые параметры Supabase/Google в собранном Info.plist. Никакие значения credentials не включались в отчёт.

Финальные model session IDs:

| Роль | Явно выбранная модель | Session ID |
| --- | --- | --- |
| Developer connectivity | `gpt-6.1-sol` | `01a1ba58-7f24-77f3-ac78-b98f9a36970c` |
| QA connectivity | `gpt-6-astra` | `01a1ba58-a348-7513-a099-bc51e9a94a5f` |

CLI `0.166.0-alpha.6`, вход через ChatGPT; Xcode 26.3 (17C529), XcodeGen 2.45.3, Python 3.14.5, Node 26.12.0, npm 11.20.0. Simulator: iPhone 17 Pro, runtime iOS 26.3; xcresult сообщает OS 26.3.1, UDID `32009F39-32EF-426B-A91E-31B368D6C27E`.

В запуске `stage1-20261108-terminal` очищены desktop-переменные и PATH ограничен стандартными системными/Homebrew-путями. Инвентаризация прошла (exit 0); CLI найден через встроенный путь ChatGPT.app. Bare `codex` в login shell отсутствует. Итог INCOMPLETE ожидаем: без флагов запросы моделям и iOS пропускаются. Это проверка эквивалентного shell-окружения, окно Terminal автоматически не открывалось.

Первый `stage1-20261108-first` остановлен управляющим агентом через SIGTERM до UI, чтобы отключить фоновый anonymous auth, обнаруженный в штатном welcome. Зафиксированы interrupted/FAIL и exit 130. Следующий `stage1-20261108-isolated` прошёл (холодная сборка 350,15 с, welcome 1/1); после добавления автоматической проверки Info.plist выполнен финальный полный прогон выше. Ни один неуспешный запуск не перезаписывался.

## Проверки на тестовых данных

`python3 -m unittest discover -s tools/automation/tests -v` — **10/10 PASS**. Проверены отказ от перезаписи/выхода за каталог, эксклюзивный lock, ненулевой exit/missing executable, остановка по timeout, сохранение ошибочного состояния, отсутствие полного PASS для inventory, проверка nonce/роли, отказ принять skipped/failed/пустой xcresult и непустую конфигурацию backend.

`git diff --check` — exit 0. `git check-ignore` подтверждает исключение сырых запусков и DerivedData. Изменений продуктовых исходников и tasks.md нет.

## Ограничения и следующий шаг

Запросы к моделям и загрузка публичных SPM-зависимостей были реальными. Backend/Auth/Storage/AI Narat не принимались; UI smoke использовал пустую конфигурацию. Он не подтверждает PL/EN локализацию, диагностику, постоянный вход, сохранение, реальную камеру или полный T152. Параметр тестового языка — `en`, проверки текста перевода отсутствуют. Выделенные PNG-скриншоты ещё не создавались.

MobileBuildMCP, Mobile MCP, Maestro/idb не устанавливались. Независимый QA с ограничениями записи, orchestrator/retries/resume и очередь задач ещё не реализованы. Точный следующий шаг — этап 2: закрепить версии двух MCP локально в проекте, проверить handshake, закреплённый Simulator, запуск приложения, accessibility/tap и сохранение screenshot. Продуктовая очередь по tasks.md по-прежнему начинается с T152.

Сырые доказательства остаются локально в игнорируемом `runs/`; этот краткий отчёт предназначен для Git. Системные каталоги Xcode/Simulator и существующая авторизация Codex используют штатные пути macOS.
