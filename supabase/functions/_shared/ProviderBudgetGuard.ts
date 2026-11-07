// supabase/functions/_shared/ProviderBudgetGuard.ts
// T034: Daily provider budget guard (cap <= $10.00 USD / 1,000,000 micro-USD per UTC day).
// Called ONLY for Vision classification modes (identification, diagnosis, follow_up).
// Plan generation is 100% deterministic and never calls the provider or touches provider budget.

export const DAILY_PROVIDER_BUDGET_CAP_MICRO_USD = 10_000_000; // $10.00 USD
export const ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD = 5_000; // $0.005 USD reserve per call

export type ProviderEligibleMode = "identification" | "diagnosis" | "follow_up";

export interface DailyBudgetRecord {
  budgetDateUtc: string;
  capMicroUsd: number;
  spentMicroUsd: number;
  reservedMicroUsd: number;
  circuitOpen: boolean;
}

export interface ProviderBudgetStorageAdapter {
  reserveDailyBudget(params: {
    budgetDateUtc: string;
    reserveMicroUsd: number;
    maxCapMicroUsd: number;
  }): Promise<{ allowed: boolean; record: DailyBudgetRecord }>;

  settleDailyBudget(params: {
    budgetDateUtc: string;
    reservedMicroUsd: number;
    actualSpentMicroUsd: number;
  }): Promise<DailyBudgetRecord>;
}

export class ProviderBudgetGuard {
  static assertModeUsesProvider(mode: string): asserts mode is ProviderEligibleMode {
    if (
      mode !== "identification" &&
      mode !== "diagnosis" &&
      mode !== "follow_up"
    ) {
      throw new Error(
        `Mode '${mode}' is deterministic and must NEVER invoke the LLM provider or consume provider budget.`,
      );
    }
  }

  static currentUtcDateKey(now: Date = new Date()): string {
    return now.toISOString().slice(0, 10);
  }

  static async acquireReservation(
    mode: string,
    adapter: ProviderBudgetStorageAdapter,
    now: Date = new Date(),
    reserveMicroUsd: number = ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD,
  ): Promise<{ allowed: boolean; budgetDateUtc: string; reservedMicroUsd: number }> {
    ProviderBudgetGuard.assertModeUsesProvider(mode);
    const budgetDateUtc = ProviderBudgetGuard.currentUtcDateKey(now);
    const res = await adapter.reserveDailyBudget({
      budgetDateUtc,
      reserveMicroUsd,
      maxCapMicroUsd: DAILY_PROVIDER_BUDGET_CAP_MICRO_USD,
    });
    return {
      allowed: res.allowed && !res.record.circuitOpen &&
        res.record.capMicroUsd <= DAILY_PROVIDER_BUDGET_CAP_MICRO_USD,
      budgetDateUtc,
      reservedMicroUsd: res.allowed ? reserveMicroUsd : 0,
    };
  }

  static async settleReservation(params: {
    budgetDateUtc: string;
    reservedMicroUsd: number;
    actualSpentMicroUsd: number;
    adapter: ProviderBudgetStorageAdapter;
  }): Promise<DailyBudgetRecord> {
    return await params.adapter.settleDailyBudget({
      budgetDateUtc: params.budgetDateUtc,
      reservedMicroUsd: params.reservedMicroUsd,
      actualSpentMicroUsd: Math.max(0, params.actualSpentMicroUsd),
    });
  }
}
