// supabase/functions/_shared/http.ts
// T019: Shared HTTP helpers, error envelope, locale resolution, and auth extraction per contracts/api.md.

export type SupportedLocale = "pl" | "en";

export type ErrorCode =
  | "UNAUTHORIZED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "VALIDATION_ERROR"
  | "IDEMPOTENCY_CONFLICT"
  | "QUOTA_EXHAUSTED"
  | "QUOTA_REGISTRATION_REQUIRED"
  | "COLLECTION_LIMIT_REACHED"
  | "ENTITLEMENT_REQUIRED"
  | "PLANT_CONTEXT_STALE"
  | "PLAN_UNAVAILABLE"
  | "DIAGNOSIS_UNRESOLVED"
  | "DRAFT_EXPIRED"
  | "CONFLICT"
  | "PROVIDER_UNAVAILABLE"
  | "INTERNAL_ERROR";

export interface ApiErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    retryable: boolean;
    details?: Record<string, unknown>;
  };
}

export class ApiHttpError extends Error {
  readonly status: number;
  readonly code: ErrorCode;
  readonly retryable: boolean;
  readonly details?: Record<string, unknown>;

  constructor(
    status: number,
    code: ErrorCode,
    message: string,
    retryable = false,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "ApiHttpError";
    this.status = status;
    this.code = code;
    this.retryable = retryable;
    this.details = details;
  }
}

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-installation-credential, x-client-locale, x-operation-id",
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
};

export function resolveLocale(req: Request): SupportedLocale {
  const header = req.headers.get("x-client-locale")?.trim().toLowerCase() ??
    req.headers.get("accept-language")?.trim().toLowerCase() ?? "";
  if (header.startsWith("pl")) {
    return "pl";
  }
  return "en";
}

export function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

export function errorResponse(err: unknown, locale: SupportedLocale = "en"): Response {
  if (err instanceof ApiHttpError) {
    const payload: ApiErrorBody = {
      error: {
        code: err.code,
        message: err.message,
        retryable: err.retryable,
        ...(err.details ? { details: err.details } : {}),
      },
    };
    return jsonResponse(payload, err.status);
  }

  const fallbackMessage = locale === "pl"
    ? "Wystąpił nieoczekiwany błąd serwera."
    : "An unexpected server error occurred.";

  const payload: ApiErrorBody = {
    error: {
      code: "INTERNAL_ERROR",
      message: err instanceof Error && err.message ? err.message : fallbackMessage,
      retryable: true,
    },
  };
  return jsonResponse(payload, 500);
}

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function requireUuid(value: unknown, fieldName: string): string {
  if (typeof value !== "string" || !UUID_REGEX.test(value)) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      `Invalid or missing UUID for '${fieldName}'.`,
      false,
      { field: fieldName },
    );
  }
  return value.toLowerCase();
}

export interface RequestContext {
  ownerId: string | null;
  isAnonymous: boolean;
  accountState: "active" | "deleting" | "deleted" | null;
  installationCredential: string | null;
  locale: SupportedLocale;
  operationId: string | null;
}

export function extractBearerToken(req: Request): string | null {
  const auth = req.headers.get("authorization");
  if (!auth) return null;
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

export function requireActiveOwner(ctx: RequestContext): string {
  if (!ctx.ownerId) {
    throw new ApiHttpError(
      401,
      "UNAUTHORIZED",
      ctx.locale === "pl"
        ? "Wymagane jest zalogowanie do konta."
        : "Authentication is required.",
    );
  }
  if (ctx.accountState !== "active") {
    throw new ApiHttpError(
      403,
      "FORBIDDEN",
      ctx.locale === "pl"
        ? "Konto jest w trakcie usuwania lub niedostępne."
        : "Account is deleting or unavailable.",
    );
  }
  return ctx.ownerId;
}
