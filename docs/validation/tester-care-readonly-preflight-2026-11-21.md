# Живой backend: проверка только на чтение — 21 ноября 2026

READ_ONLY_PREFLIGHT_PASS: один обычный вход существующего тестового владельца,
profile/full raw sync/care overview/опубликованное правило. Domain writes0,
canonical rows и профиль до/после совпали. Это не care/System/UI-приёмка.

- Активное растение1; care entries6 (все VOID), reversals6. Связь — entry_id.
- Старый Ficus tombstone сохранён; активных care facts/controls/расписания нет.
- Подтверждённый час09:00, опубликованный интервал проверки грунта7дней.
- Membership включён, automation_allowed=true, verified_access_until=null (Free).

Backend допускает подготовку одного будущего water-cycle. Local outbox,
owner opt-in и реальные permission/pending/delivered iOS через HTTP не
проверялись. Готовность исполнения доставки не установлена. До первого
UI-write необходимы принятая сборка и local/System preflight; baseline и
правило при исполнении читаются заново. Записей ухода этот preflight не создавал.

[JSON](tester-care-readonly-preflight-2026-11-21.json). Сырые ответы, owner/plant
UUID и секреты остаются в private evidence вне Git.
