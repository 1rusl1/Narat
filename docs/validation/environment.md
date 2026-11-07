# Validation: Environment & Toolchains (G01 / T001)

**Date**: 2026-11-01  
**Task**: `T001`  
**Gate**: `G01 Environment` (Partial — iOS & Python toolchains ready; Docker/Supabase/Deno pending local install & physical iPhone pending G03/G07)

## 1. Проверенные инструменты на рабочей станции

| Компонент | Статус | Версия / Детали | Примечание |
| --- | --- | --- | --- |
| **macOS / Архитектура** | Доступен | `arm64-apple-macosx26.0` | Apple Silicon |
| **Xcode** | Доступен | `Xcode 26.3` (`Build version 17C529`) | Проверено через `xcodebuild -version` |
| **Swift** | Доступен | `Apple Swift version 6.2.4` (`swiftlang-6.2.4.1.4`) | Поддерживает режим языка `Swift 6` |
| **XcodeGen** | Доступен | `2.45.3` (`/opt/homebrew/bin/xcodegen`) | Используется для воспроизводимой генерации `ios/Plants.xcodeproj` |
| **iOS Build (`build-for-testing`)** | Проверен | `** TEST BUILD SUCCEEDED **` (`Plants`, `PlantsTests`, `PlantsUITests`) | Команда: `xcodebuild -project ios/Plants.xcodeproj -scheme Plants -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PlantsDerivedData MODULE_CACHE_DIR=/tmp/swift-module-cache build-for-testing` |
| **CoreSimulatorService** | Доступен | Подключён (`xcrun simctl list runtimes/devices`) | Доступны рантаймы `iOS 17.0 (21A328)`, `iOS 26.3 (23D8133)`, `iOS 26.4 (23E244)` |
| **Симуляторы iOS 17.0 (min target)** | Доступны | `iPhone 15 Pro` (`6239A7D9-8779-45E9-B073-A462D023AA1E`), `iPhone 15`, `iPhone SE (3rd gen)` | Позволяют проверять минимальный таргет `iOS 17.0` |
| **Симуляторы iOS 26.3 (latest)** | Доступны | `iPhone 17 Pro` (`32009F39-32EF-426B-A91E-31B368D6C27E`), `iPhone 17`, `iPhone 16e` | Позволяют проверять актуальную ОС |
| **Python / uv (Offline KB pipeline)** | Доступны | `Python 3.14.5`, `uv 0.13.1` (`/opt/homebrew/bin/uv`) | Для выполнения офлайн-контура Golden Records (`T108`–`T115`) |
| **PostgreSQL (локальные утилиты)** | Доступны | `postgresql@14` (`14.19_1` в `/opt/homebrew/bin`) | Клиентские утилиты доступны |
| **Deno** | Доступен | `deno 2.9.8` (`v8 15.0.245.2`, `typescript 6.0.3`, `/opt/homebrew/bin/deno`) | Lockfile `supabase/functions/deno.lock` зафиксирован; тесты `G02` (`runtime_compatibility_test.ts`) пройдены (`6 passed, 0 failed`) |
| **Supabase CLI** | Доступен | `2.122.0` (`/opt/homebrew/bin/supabase`) | Установлен из `supabase/tap/supabase` |
| **SPM Dependencies (`Package.resolved`)** | Зафиксированы | `Supabase 2.55.6`, `GoogleSignIn 8.0.0`, `swift-crypto 4.5.2` | Зафиксированы в `ios/Plants.xcodeproj/.../Package.resolved` и `Package.resolved` |
| **Docker Runtime** | Не установлен | Не найден в `PATH` | Требуется Docker Desktop / OrbStack / Colima для запуска контейнеров `supabase start` |

## 2. Статус Gate G01 и G02

- **iOS Build & Simulator**: **READY** — Xcode 26.3, Swift 6.2.4, SPM-пакеты (`Supabase 2.55.6`, `GoogleSignIn 8.0.0`) и симуляторы `iOS 17.0` / `iOS 26.3` полностью работоспособны.
- **Deno & Gate G02 (SDK / Schema 3.0)**: **PASS (Local Edge Runtime)** — `deno test` в `supabase/functions/_shared/tests/runtime_compatibility_test.ts` успешно проверил каноническую JSON Schema Draft 2020-12 (`ai-result.schema.json` v3.0), `@anthropic-ai/sdk@0.32.1` (`claude-haiku-5-5`, `maxRetries=0`) и `@apple/app-store-server-library@1.5.0` (`SignedDataVerifier`, отклонение поддельного JWS).
- **Offline KB Pipeline (Python)**: **READY** — Python 3.14.5 и `uv` готовы к работе.
- **Local DB Container Runtime (Docker)**: **PENDING DOCKER DAEMON** — `supabase` CLI (`2.122.0`) установлен; для живого прогона `supabase start` / `supabase test db` потребуется запущенный демон Docker (Docker Desktop / OrbStack / Colima).
- **Physical iPhone (Camera G03 / Native Sign-In)**: **PENDING DEVICE** — калибровка `LightingProbe` (`T087`) и проверка нативного входа на реальном устройстве выполняются при подключении физического iPhone.
