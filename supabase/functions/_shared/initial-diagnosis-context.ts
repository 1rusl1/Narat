// Closed contract shared by Edge admission and leased workers.
export interface InitialDiagnosisContext {
  light: "low" | "medium" | "bright_indirect" | "direct_sun" | "unknown";
  watering_frequency: "frequent" | "moderate" | "sparse" | "unknown";
  drainage: "yes" | "no" | "unknown";
}

export function validInitialContext(value: unknown): value is InitialDiagnosisContext {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const context = value as Record<string, unknown>;
  return Object.keys(context).length === 3 &&
    Object.hasOwn(context, "light") &&
    Object.hasOwn(context, "watering_frequency") &&
    Object.hasOwn(context, "drainage") &&
    typeof context.light === "string" &&
    ["low", "medium", "bright_indirect", "direct_sun", "unknown"].includes(context.light) &&
    typeof context.watering_frequency === "string" &&
    ["frequent", "moderate", "sparse", "unknown"].includes(context.watering_frequency) &&
    typeof context.drainage === "string" &&
    ["yes", "no", "unknown"].includes(context.drainage);
}
