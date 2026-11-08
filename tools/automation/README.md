# Проверка окружения Narat

Этап 1: Python 3.11+, только стандартная библиотека. Запуск из обычного Terminal:

```sh
cd /Users/ruslansabirov/Documents/ChatGPT/Plants
python3 tools/automation/doctor.py
python3 tools/automation/doctor.py --check-models --check-ios
```

Первый запуск проверяет окружение и возвращает `INCOMPLETE`: запросы моделям и сборка требуют явных флагов. Второй выполняет по одному реальному запросу Developer/QA, сборку и один существующий welcome XCUITest (EN). Запросы используют квоту текущей авторизации Codex. Смена моделей и симулятора:

```sh
python3 tools/automation/doctor.py --check-models --check-ios \
  --developer-model gpt-6.1-sol --qa-model gpt-6-astra \
  --simulator 32009F39-32EF-426B-A91E-31B368D6C27E
```

CLI ищется в PATH, затем внутри `/Applications/ChatGPT.app`; можно указать `--codex /абсолютный/путь/codex`. Глобальная установка и правки shell-конфигурации не требуются. Нужна предварительная авторизация `codex login`; doctor не читает и не копирует credentials. Для CoreSimulator и загрузки SPM нужен обычный доступ macOS/сети; внутри песочницы Codex запуск может потребовать разрешённого выполнения вне неё.

Каждый запуск создаёт новый `docs/validation/automation/runs/<run-id>/`: `summary.json`, команды, stdout/stderr, ответы моделей и `welcome.xcresult`. Каталог исключён из Git: логи могут содержать локальные данные. Проверенные краткие отчёты публикуются отдельно в `docs/validation/automation/`. DerivedData/SPM сохраняются в игнорируемом `DerivedData/Automation/`. Системные кэши Xcode/Simulator и авторизация Codex используют штатные каталоги macOS.

Модели работают в двух новых ephemeral сессиях с read-only sandbox, без пользовательской конфигурации и desktop MCP. Это проверка связи, не полноценные агенты Developer/QA. Doctor не выбирает задачи, не обновляет handoff/tasks, не делает commit/push и не устанавливает инструменты. Welcome smoke проверяет только запуск и две кнопки, не подтверждает backend, диагностику, OAuth, камеру или PL-сценарии. Для этой сборки параметры Supabase/Google принудительно очищаются через build settings: это исключает фоновый anonymous sign-in из welcome. Перед запуском UI doctor проверяет эти поля в собранном Info.plist; при непустой конфигурации останавливается с FAIL. Local xcconfig и исходники сохраняются; сборка для обычной разработки использует свои параметры. Для PASS требуется один действительно прошедший тест без пропусков в xcresult.

Есть эксклюзивный lock, тайм-ауты, остановка дочерней группы по Ctrl-C/SIGTERM, промежуточный JSON. Повторного запуска стадий и автоматических retries нет. После прерывания запускайте новый run; существующий `--run-id` не перезаписывается. Возобновление рабочего цикла появится на этапе оркестратора. Коды выхода: `0` — выбранные проверки прошли (полный PASS только с обоими флагами), `1` — ошибка проверки, `2` — ошибка параметров/lock, `130` — прерывание. Итоговый статус читайте из `summary.json`.

Тесты инфраструктуры на тестовых данных:

```sh
python3 -m unittest discover -s tools/automation/tests -v
```

## Этап 2: управление Simulator через MCP

Установка и запуск из корня проекта (для текущего Mac Apple Silicon):

```sh
npm ci --prefix tools/automation --ignore-scripts --no-audit --no-fund --cache tools/automation/.cache/npm
python3 tools/automation/setup_mobile_agent.py
python3 tools/automation/simulator_smoke.py
```

Закреплены MobileBuildMCP 2.7.1 и Mobile MCP 1.0.16, транзитивные зависимости — в `package-lock.json`. Внешний UI-агент devicekit-ios 0.0.36 закреплён отдельно в `mobile-agent.lock.json`: setup скачивает официальный GitHub Release asset через API, проверяет SHA256 и устанавливает только на выбранный локальный iOS Simulator. Причина отдельного setup: штатный загрузчик mobilecli вернул HTTP 504. Уже установленная совпадающая версия повторно не устанавливается; другая версия требует разбора. Глобальная установка Node-пакетов и изменения shell-конфигурации не нужны.

`simulator_smoke.py` под общим lock последовательно:

1. Запускает два stdio MCP-сервера, проверяет initialize/tools/list и выбранный UDID.
2. Собирает Plants через MobileBuildMCP с пустой backend-конфигурацией, проверяет собранный Info.plist, устанавливает приложение.
3. Подготавливает UI-агент, запускает Narat и через Mobile MCP проверяет welcome-элементы.
4. Сохраняет `welcome.png`, нажимает `welcome.intent.care` по свежему native ref и проверяет `care.method.title/scan/catalogue`.
5. Сохраняет `care-method.png`, accessibility JSON, команды/ответы MCP, build log и итоговый `summary.json` в новом `docs/validation/automation/runs/<run-id>/`.

Можно задать `--simulator <UDID>` и `--run-id <новое-имя>`. Это ограниченный локальный UI smoke; он не принимает диагностику, каталог, OAuth или локализацию. Исходники приложения и продуктовые задачи не меняются. Пропущенная стадия/ошибка RPC/инструмента/локатора не даёт PASS. Первый запуск UI-агента может вывести SpringBoard: smoke подготавливает его до запуска Narat и принимает только ожидаемые элементы приложения.

`mcp_client.py` использует Python stdlib и MCP JSON-RPC stdio, с тайм-аутами и завершением серверов. Кэши npm/мобильного helper находятся в игнорируемом `tools/automation/.cache/`; телеметрия серверов отключена. MobileBuildMCP 2.7.1 жёстко задаёт свою папку логов в home. Поэтому `run_build_mcp.mjs` перед запуском перенаправляет её в проект через экспортированный внутренний override; версия проверяется строго, при обновлении этот адаптер нужно пересмотреть. Пакет и HOME не изменяются. Сам Simulator/Xcode используют штатные служебные каталоги macOS; mobilecli daemon работает в `.cache/mobilecli` и автоматически простаивает/завершается по своему жизненному циклу.

Глобальный MCP config Codex не изменяется. Подключение этих инструментов к независимому Astra QA и проверка ограничений записи — этап 3; оркестратор и автоматическая очередь ещё впереди. Пара моделей остаётся Sol + Astra.

Основание CLI-флагов: [Codex exec](https://learn.chatgpt.com/docs/non-interactive-mode), [CLI reference](https://learn.chatgpt.com/docs/cli/reference). MCP: [MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP), [Mobile MCP](https://github.com/mobile-next/mobile-mcp), [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). Текущий статус — существующий handoff.
