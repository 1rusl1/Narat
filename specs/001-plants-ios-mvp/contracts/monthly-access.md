# Месячный доступ — T163

Статус 2026-11-09: контракт подготовки B; реализация/приёмка фиксируются в handoff.
Основание: spec FR-005/017/065. `collection-http.md` не изменяется.

## Период и доступ

Anchor — UTC instant регистрации **постоянного** аккаунта; создание anonymous,
вход, bind/claim, покупка/trial→paid/restore/expiry его не меняют.
Окно полуоткрытое [start,end), вычисляется каждый раз от исходного anchor:
31 января 10:20 → 28/29 февраля 10:20 → 31 марта 10:20 UTC.
29 февраля → 29 марта; февраль следующего года сокращается до 28 числа.
Timezone сессии БД и DST не влияют; на точном end начинается следующее окно.

Starter identification и diagnosis независимы: по одному успешному результату.
Free сначала использует starter своего режима, затем общий месячный лимит 3.
Paid/trial использует только месячный лимит 100. Identification/diagnosis и
повторная диагностика используют один расход. Неизвестный результат сам по себе
не освобождает квоту; technical failure и явно non-billable input освобождают.
Успешный анализ рекомендаций/сохранение фото отдельно не оплачиваются.

Расход месяца общий, не две складываемые ёмкости. Например Free consumed=2 →
trial remaining=98 → paid remaining=98 → expiry Free remaining=1. После paid
consumed=7 Free remaining=0. Возврат в paid даёт 93, а не новый лимит 100.
Стартеры не сбрасываются и не служат fallback при exhausted paid.

## Хранение и перенос

Forward migrations: `202611090005_registration_quotas.sql` (anchor/окна),
`202611090006_registration_ledger.sql` (перенос учёта), затем
`202611090007_registration_state_guard.sql` (legacy permanent не может стать guest),
`202611090008_quota_reservation.sql` (reserve),
`202611090009_quota_settlement.sql` (finalize/bind). До последнего среза
старый admission не считается заменённым; выкатывать их вместе после приёмки.

`account_quota_anchors(owner_id,registered_at,source)` — отдельный внутренний
учёт, без изменения collection sync. Новые permanent INSERT и anonymous→permanent
получают серверное время регистрации (для INSERT серверный profiles.created_at).
Дата неизменяема. Исторический profiles.created_at может относиться к anonymous:
legacy без доказательства получает NULL, а не дату покупки/первого starter.
Service-only `set_registration_quota_anchor(owner,at,evidence)` разрешает один
проверенный импорт; повтор той же даты допустим, смена — конфликт. Подтверждённой
истории для live backfill пока нет: это ограничение развёртывания, не новый UI.

| Старые данные | Перенос и повтор |
| --- | --- |
| Monthly job с известным owner/created_at и quota_state | Одна строка `account_quota_usage` по job_id, окно на момент reserve (created_at), прежние owner/job/receipt/pointer сохранены. |
| Reserved job, включая running lease | Тот же job и исходное окно, без нового reserve. Finalize меняет ledger и старый monthly counter согласованно ровно раз. |
| Consumed job и соответствующий aggregate | Считается один раз по ledger, не ledger+aggregate. |
| Aggregate consumed/reserved больше восстанавливаемых jobs либо противоречие | `quota_legacy_reconciliation` сохраняет нераспределённый расход/флаг. Окна, пересекающие старый period, закрыты до расследования; ничего не обнулять. |
| Старые periods | Строки/расход остаются; непересекающийся текущий период не получает старый расход. |
| Starter/plan/исторический follow_up | Starter-маркеры и план без monthly расхода неизменны; исторический monthly follow_up учитывается как прежний расход, новый follow_up отвергается. |
| Нет доказательства registered_at | Monthly fail-closed `quota_registration_required`; starter доступен по прежним маркерам. |

Служебный `reconcile_registration_quota(owner)` идемпотентен; повтор не добавляет
расхода. История monthly_quotas/operation_receipts/leases не переписывается при
миграции. Неполные данные — явный `quota_history_unresolved`, не доступ с нуля.

## RPC и следующий API-пакет

Сигнатуры admit_analysis_quota(mode,owner,installation,job,now) и
finalize_analysis_quota(job,outcome,is_non_billable_result,now) сохраняются.
Временной параметр доступен только service role; клиент его не передаёт.
Admission требует существующий owner-scoped job c совпадающим mode, валидирует
installation и account; запись job+ledger атомарна. Тот же job/operation не
резервируется повторно, terminal replay не запускает новый анализ.
Lock order: owner → installation → job/ledger/legacy quota; owner update защищает
от stale snapshot; сеть вне транзакции. Provider daily budget и collection cap
сохраняются отдельно, quota admission их не отменяет.

API B2 читает authoritative SQL snapshot: modes identification/diagnosis,
activeQuotaKind, allowed, remaining, limit, inProgressJobId, nextResetAt,
registration anchor/period UTC. Remaining=max(0,limit-consumed-reserved),
nextResetAt=end регистрационного окна; гостю без monthly — null.
До B2 это целевая граница, текущий инъекционный TS adapter не production proof.
Exhaustion: free_monthly_exhausted / paid_monthly_exhausted, HTTP 429
QUOTA_EXCEEDED с remaining=0/reset; starter_in_progress — 409; missing verified
anchor/history — 503 QUOTA_UNAVAILABLE (EN/PL), без успешного fallback.
Identity/owner mismatch — 403, payload/operation mismatch — 409, invalid mode —400.

Готовность: trusted PG17 clean + seeded-upgrade, 20 одновременно наблюдаемых
соединений на последний остаток, replay/finalizeOnce/failure/A-B; затем Deno
handlers/production adapters и клиент A/T036. Fixtures не доказывают live Supabase,
Auth, Storage, provider или StoreKit. Полная T163 остаётся открытой.
