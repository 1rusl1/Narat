# Care overview: изолированная выкладка и живой HTTP

19 ноября 2026. Серверный срез этапа2 принят; экран «Сегодня» ещё в разработке.
SQL принят `25a5e92`, HTTP `0aff69f`; root integration `d3ba202`.

## Применено на staging

- Ровно `202611190001_care_overview_read.sql`: CREATE нового read-only RPC и
  INSERT его version/name выполнены одной транзакцией. Прежние92 записи
  migration history сохранены, итог93. Другие pending migrations не применялись.
- Readback подтвердил точный SHA256 `pg_proc.prosrc`, STABLE, SECURITY DEFINER,
  пустой search_path, UTC и API EXECUTE для service_role, без PUBLIC/anon/authenticated.
- Новый `care-overview` ACTIVE v1, verify_jwt=false: bearer проверяется через
  getUser, permanent/active owner повторно проверяет SQL. Из immutable `0aff69f`
  собраны только новый slug, три shared-модуля, две схемы и import map/lock.
  Компиляция этого изолированного entrypoint прошла.

| Функция | Версия | SHA256 deployed bundle |
| --- | --- | --- |
| care-overview | 1 | bb8d2a54471b33fbdfad67320e01eec429ae00a5918d04c9b0445473fb79802c |
| plants-api | 33 | 8ce745d95be02097417c5058cc87b63799765e13065fabd10f68849fd4fbc739 |
| analysis-worker | 9 | 31ea088a5962017d8c053188b68cc81e033310bcffc3ce849fde032f0de006df |

Полные metadata двух прежних функций до/после совпали. Их не перевыкладывали.
Local refactor старого card handler не меняет уже действующий plants-api33.

## Что реально проверено

Fixtures до выкладки: 4×140 overview pgTAP на full-current и exact92 local
clean/upgrade; 446 Deno (436 прежних +10 новых),149 automation, три реально
существующие Edge entrypoint compile, независимые Review/QA — PASS.

Отдельный local PG17 операторский прогон:14 assertions, включая точный CREATE/
ACL/history93 и полный rollback новой функции при отказе history INSERT.
Care RPC в этом операторском прогоне не вызывался; это не повторная функциональная
приёмка. Cluster остановлен, собственный PG data удалён.

Живой HTTP на существующей отдельной обычной Free-учётке: один принадлежащий
ей Monstera, EN и PL, полный `care_recommendation` по всем JSON-значениям
совпал с прежним card response. У этого растения сейчас next_check=null,
first_aid_controls=[]; новый датированный сценарий этим прогоном не доказан.
Семь отрицательных проверок: owner input/duplicate limit/zero limit→400,
unknown subpath→404, POST→405, missing/invalid bearer→401. Все новые ответы
private,no-store. Canonical sync data до/после чтения совпали по SHA256.
Новых растений, фактов ухода, диагнозов и AI-расхода прогон не создавал.

Первый metadata preflight остановился только на другом порядке двух строк
function list; field-by-field сравнение показало полное совпадение. Сравнение
исправлено на сортировку по slug, свежий preflight прошёл ДО любых DDL.
Исходные FAIL/logs сохранены; слепых повторов SQL/deploy не было.

## Границы и следующий шаг

Пагинация205 растений, два owner, dated routine/firstaid, malformed/access/expiry
проверены fixtures; live здесь только один owner/одно растение с null date.
UI, offline/cold cache, физический iPhone и доставка уведомлений ещё не приняты.
External registry-only change инвалидирует generation, но не вводит новую
temporal rights policy поверх принятой source authority056/029.

Следом NativeA: DTO/sibling transport/coherent paging; затем durable owner cache,
Today UI, напоминания и физическая матрица B01–B11. Родительские задачи открыты.
[Sanitized result](tester-care-overview-live-2026-11-19.json).
Raw metadata/checkpoints/logs находятся в
`/private/tmp/narat-care-overview-live-deploy-20261119/`; секреты туда не выводились.
