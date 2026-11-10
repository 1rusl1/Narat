// B2 canonical database quota metadata. Validation never predicts/reset quotas.
export type AnalysisQuotaKind =
  | "starter_identification"
  | "starter_diagnosis"
  | "free_monthly"
  | "paid_monthly";
export interface StarterLedgerState {
  starterIdentificationConsumed: boolean;
  starterDiagnosisConsumed: boolean;
  starterIdentificationJobId: string | null;
  starterDiagnosisJobId: string | null;
  firstStarterSuccessAt: string | null;
}
export interface ModeAccessSummary {
  mode: "identification" | "diagnosis";
  allowed: boolean;
  activeQuotaKind: AnalysisQuotaKind;
  remaining: number;
  limit: number;
  inProgressJobId: string | null;
  nextResetAt: string | null;
  reason?:
    | "starter_in_progress"
    | "starter_exhausted"
    | "free_monthly_exhausted"
    | "paid_monthly_exhausted"
    | "quota_registration_required"
    | "quota_history_unresolved";
}
export interface AnalysisAccessSnapshotResponse {
  owner_id: string;
  is_guest: boolean;
  starter: {
    identification_remaining: number;
    diagnosis_remaining: number;
    identification_in_progress_job_id: string | null;
    diagnosis_in_progress_job_id: string | null;
    first_starter_success_at: string | null;
  };
  monthly: {
    quota_kind: "free_monthly" | "paid_monthly" | null;
    registered_at: string | null;
    period_start: string | null;
    period_end: string | null;
    limit: number | null;
    consumed: number | null;
    reserved: number | null;
    remaining: number | null;
    status:
      | "ready"
      | "registration_required"
      | "history_unresolved"
      | "not_applicable";
  };
  modes: { identification: ModeAccessSummary; diagnosis: ModeAccessSummary };
}
export async function hashInstallationCredential(
  rawCredential: string,
): Promise<string> {
  const bytes = new TextEncoder().encode(rawCredential.trim());
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
  )
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}
function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const id = (value: unknown): value is string =>
  typeof value === "string" && uuid.test(value);
const nullableId = (value: unknown) => value === null || id(value);
const count = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
// Compare at PostgreSQL precision, retaining original strings in returned DTOs.
// Calendar validation is syntax validation, not calculation of quota periods.
function timestamp(value: unknown): bigint | null {
  if (typeof value !== "string") return null;
  const m = value.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/,
  );
  if (!m) return null;
  const [, year, month, day, hour, minute, second, fraction, zone] = m;
  const y = Number(year), mo = Number(month), d = Number(day);
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (
    y < 1 || mo < 1 || mo > 12 || d < 1 || d > days[mo - 1] ||
    Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59 ||
    (zone !== "Z" &&
      (Number(zone.slice(1, 3)) > 15 || Number(zone.slice(4)) > 59))
  ) return null;
  const millis = Date.parse(
    `${year}-${month}-${day}T${hour}:${minute}:${second}${zone}`,
  );
  return Number.isFinite(millis)
    ? BigInt(millis) * 1000n + BigInt((fraction ?? "").padEnd(6, "0"))
    : null;
}
const nullableTimestamp = (value: unknown) =>
  value === null || timestamp(value) !== null;
export function parseStarterLedger(value: unknown): StarterLedgerState | null {
  if (
    !record(value) ||
    typeof value.starter_identification_consumed !== "boolean" ||
    typeof value.starter_diagnosis_consumed !== "boolean" ||
    !nullableId(value.starter_identification_job_id) ||
    !nullableId(value.starter_diagnosis_job_id) ||
    !nullableTimestamp(value.first_starter_success_at)
  ) return null;
  return {
    starterIdentificationConsumed: value.starter_identification_consumed,
    starterDiagnosisConsumed: value.starter_diagnosis_consumed,
    starterIdentificationJobId: value.starter_identification_job_id as
      | string
      | null,
    starterDiagnosisJobId: value.starter_diagnosis_job_id as string | null,
    firstStarterSuccessAt: value.first_starter_success_at as string | null,
  };
}
export function parseAnalysisAccessSnapshot(
  value: unknown,
  ownerId: string,
  isGuest: boolean,
): AnalysisAccessSnapshotResponse | null {
  if (
    !record(value) || !id(value.owner_id) || value.owner_id !== ownerId ||
    value.is_guest !== isGuest ||
    !record(value.starter) || !record(value.monthly) || !record(value.modes) ||
    Object.keys(value.modes).sort().join(",") !== "diagnosis,identification"
  ) return null;
  const s = value.starter, m = value.monthly;
  if (
    ![0, 1].includes(s.identification_remaining as number) ||
    ![0, 1].includes(s.diagnosis_remaining as number) ||
    !nullableId(s.identification_in_progress_job_id) ||
    !nullableId(s.diagnosis_in_progress_job_id) ||
    !nullableTimestamp(s.first_starter_success_at) ||
    (s.identification_remaining === 1 &&
      s.identification_in_progress_job_id !== null) ||
    (s.diagnosis_remaining === 1 && s.diagnosis_in_progress_job_id !== null)
  ) return null;
  const limit = m.quota_kind === "paid_monthly" ? 100 : 3;
  if (isGuest) {
    if (
      m.status !== "not_applicable" ||
      [
        m.quota_kind,
        m.registered_at,
        m.period_start,
        m.period_end,
        m.limit,
        m.consumed,
        m.reserved,
        m.remaining,
      ].some((v) => v !== null)
    ) return null;
  } else {
    if (m.quota_kind !== "free_monthly" && m.quota_kind !== "paid_monthly") {
      return null;
    }
    if (!nullableTimestamp(m.registered_at)) return null;
    if (m.status === "registration_required") {
      if (m.period_start !== null || m.period_end !== null) return null;
    } else if (m.status === "ready" || m.status === "history_unresolved") {
      const anchor = timestamp(m.registered_at),
        start = timestamp(m.period_start),
        end = timestamp(m.period_end);
      if (
        anchor === null || start === null || end === null || start < anchor ||
        end <= start
      ) return null;
    } else return null;
    if (m.status === "ready") {
      if (
        m.limit !== limit || !count(m.consumed) || !count(m.reserved) ||
        !count(m.remaining) ||
        !Number.isSafeInteger(m.consumed + m.reserved) ||
        m.remaining !== Math.max(0, limit - m.consumed - m.reserved)
      ) return null;
    } else if (
      [m.limit, m.consumed, m.reserved, m.remaining].some((v) => v !== null)
    ) return null;
  }
  for (const mode of ["identification", "diagnosis"] as const) {
    const v = value.modes[mode];
    if (
      !record(v) || v.mode !== mode || typeof v.allowed !== "boolean" ||
      !count(v.remaining) || !count(v.limit) ||
      !nullableId(v.inProgressJobId) || !nullableTimestamp(v.nextResetAt)
    ) return null;
    const starterRemaining = s[mode + "_remaining"],
      pointer = s[mode + "_in_progress_job_id"];
    if (v.activeQuotaKind === "starter_" + mode) {
      if (
        m.quota_kind === "paid_monthly" || v.limit !== 1 ||
        v.nextResetAt !== null
      ) return null;
      if (starterRemaining === 1) {
        if (
          v.allowed !== true || v.remaining !== 1 ||
          v.inProgressJobId !== null || v.reason !== undefined
        ) return null;
      } else {
        if (v.allowed !== false || v.remaining !== 0) return null;
        if (isGuest && v.reason === "starter_exhausted") {
          if (v.inProgressJobId !== null) {
            return null;
          }
        } else if (pointer !== null) {
          if (
            v.inProgressJobId !== pointer || v.reason !== "starter_in_progress"
          ) return null;
        } else return null;
      }
    } else if (!isGuest && v.activeQuotaKind === m.quota_kind) {
      if (m.quota_kind === "free_monthly" && starterRemaining === 1) {
        return null;
      }
      const remaining = m.remaining ?? 0;
      if (
        v.limit !== limit || v.remaining !== remaining ||
        v.allowed !== (m.status === "ready" && (remaining as number) > 0) ||
        v.inProgressJobId !== null || v.nextResetAt !== m.period_end
      ) return null;
      const reason = m.status === "registration_required"
        ? "quota_registration_required"
        : m.status === "history_unresolved"
        ? "quota_history_unresolved"
        : remaining === 0
        ? m.quota_kind + "_exhausted"
        : undefined;
      if (v.reason !== reason) return null;
    } else return null;
  }
  return value as unknown as AnalysisAccessSnapshotResponse;
}
