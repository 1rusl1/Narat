// The pinned 2.7.1 runtime has no production setting for its log/state root.
// Its exported test seam redirects these files without changing HOME or the package.
// Fail closed if the pinned internal API changes. See package-lock.json.
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const runtime = join(directory, "node_modules/mobilebuildmcp");
const version = JSON.parse(readFileSync(join(runtime, "package.json"))).version;
if (version !== "2.7.1") throw new Error("Review log redirection before changing MobileBuildMCP version");
const paths = await import(pathToFileURL(join(runtime, "build/utils/log-paths.js")));
const state = join(directory, ".cache/mobilebuildmcp");
mkdirSync(state, { recursive: true, mode: 0o700 });
paths.setMobileBuildMCPAppDirOverrideForTests(state);
const entry = join(runtime, "build/cli.js");
process.argv = [process.execPath, entry, "mcp"];
await import(pathToFileURL(entry));
