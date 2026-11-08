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

Основание CLI-флагов: [Codex exec](https://learn.chatgpt.com/docs/non-interactive-mode), [CLI reference](https://learn.chatgpt.com/docs/cli/reference). MCP и автоматический Developer → QA подключаются отдельными этапами согласно существующему handoff.
