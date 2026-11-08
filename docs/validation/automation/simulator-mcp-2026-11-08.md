# Этап 2 — Simulator через MCP, 2026-11-08

**PASS ограниченного smoke:** сборка/установка/запуск через MobileBuildMCP, чтение UI/нажатие/скриншоты через Mobile MCP. Это не приёмка продуктовых задач и не работа независимого QA.

## Закреплённое окружение

- `mobilebuildmcp@2.7.1`, `@mobilenext/mobile-mcp@1.0.16`, Node 26.12.0. Установка `npm install --prefix tools/automation --ignore-scripts --no-audit --no-fund --cache tools/automation/.cache/npm` завершилась успешно; установлен 201 пакет, включая зависимости. Последующее воспроизведение — `npm ci` по lock.
- Native mobilecli 1.0.22 из npm и devicekit-ios 0.0.36 для ARM64 Simulator. SHA256 агента сверён с release metadata и исходником `mobile-next/mobilecli` tag `1.0.22`.
- iPhone 17 Pro / iOS 26.3, UDID `32009F39-32EF-426B-A91E-31B368D6C27E`; реальный iPhone не использовался.
- MCP initialize согласовал protocol `2025-06-18`; схемы tools/list сохранены. Серверы сообщают версии 2.7.1 / 1.0.16.

## Реально выполнено

```sh
python3 tools/automation/setup_mobile_agent.py --run-id stage2-agent-setup-final-20261108
python3 tools/automation/simulator_smoke.py --run-id stage2-mcp-final-20261108
python3 -m unittest discover -s tools/automation/tests -v
```

Setup на уже установленном агенте: exit 0, версия 0.0.36 подтверждена без переустановки. Холодная установка выполнена ранее из того же проверенного архива командой native CLI `apps install`; отчёт `runs/stage2-agent-api-install-20261108/`.

Полный smoke: exit 0, `summary.json` — PASS. Доказательства в `runs/stage2-mcp-final-20261108/`:

- `build.initialize.json`, `mobile.initialize.json`, `*.tools.json`, `*.rpc.jsonl`, stderr и отдельные tool responses.
- `xcodebuild.log`: успешная сборка через `build_sim`, изолированный Info.plist проверен до установки/запуска.
- `welcome.elements.json` / `care-method.elements.json`: реальные accessibility ID, labels и refs.
- `welcome.png` / `care-method.png`: **1206×2622**, разные SHA256; файлы визуально просмотрены. Первый показывает welcome с двумя намерениями, второй — выбор сканирования/каталога после нажатия ухода. В этом прогоне выбран English; PL-приёмка не выполнялась.
- `unittest.log`: **22/22 PASS** на тестовых данных, включая исходные 10 doctor checks, stdio handshake/error/EOF/ID/timeout/pagination, запрет ложного успеха, локаторы и контрольные суммы/целостность артефактов. После усиления проверки PNG оба реальных файла повторно проверены этим валидатором.

Первая UI-проба остановилась на загрузке агента: штатный загрузчик и один повтор дали HTTP 504; прямая GitHub download-ссылка также дала 504. Официальный GitHub Releases API вернул тот же архив (asset `696608047`, SHA256 `f7ce6b8f496e4fb7abb4917f4492152d8629aa61f6cb98ab50f2000f5c07cf5c`), он проверен и установлен. Эти ошибки сохранены в отдельных runs, не превращены в PASS. Первое чтение после старта агента увидело SpringBoard; финальный smoke учитывает и проверяет фактическую навигацию приложения.

## Файлы и границы

Добавлены npm manifest/lock, `mcp_client.py`, `run_build_mcp.mjs`, lock/setup UI-агента, `simulator_smoke.py` и два набора тестов. Обновлены `.gitignore`, README и handoff. Исходники Plants, схемы и tasks.md не менялись; T152 остаётся открытой.

Логи/скриншоты/сборка/кэши локальны и исключены из Git; публикуется эта сводка. Два MCP stdio процесса завершаются после smoke. Локальный native daemon/Simulator имеют собственный штатный жизненный цикл. MobileBuildMCP перенаправлен в `.cache/mobilebuildmcp` через внутренний version-pinned override: его совместимость проверена этим прогоном, обновление пакета требует пересмотра launcher. Предварительные пробы до launcher создали служебные логи в стандартном `~/Library/Developer/MobileBuildMCP`; они не используются как финальные доказательства.

Проверка приложения — локальная smoke-сборка с отключёнными Supabase/Google-параметрами. Живые backend/Auth/Storage/AI Narat, диагностика, сохранение, PL-покрытие, камера и полный UX не принимались. Sol/Astra в этом этапе не вызывались; проверен транспорт/управление MCP, отдельного QA пока нет.

Следующий шаг — этап 3: независимая Astra CLI-сессия, которая получает требования и build evidence, использует ограниченный набор UI tools, не меняет исходники/handoff/tasks и возвращает проверяемый JSON с PASS/FAIL. Затем — Python-оркестратор, один срез T152 и очередь.
