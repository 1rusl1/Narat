import { createCareOverviewHandler } from "./handler.ts";

export { createCareOverviewHandler } from "./handler.ts";

if (import.meta.main) {
  Deno.serve(createCareOverviewHandler());
}
