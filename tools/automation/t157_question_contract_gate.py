"""Independent scope gate for the first T157 question-bank cleanup slice."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
schema = json.loads((ROOT / "specs/001-plants-ios-mvp/contracts/condition-profile.schema.json").read_text())
# Exact semantic diff: only remove the cancelled question-bank requirement/property.
assert hashlib.sha256(json.dumps(schema, sort_keys=True, separators=(",", ":")).encode()).hexdigest() == "266e7e457db4cbddfa9d3515f5527e774fbbdc2c27cc677a1b01c31a235581c6", "Schema changed beyond the approved question-bank deletion"
source = (ROOT / "supabase/functions/_shared/KnowledgeTypes.ts").read_text()
for obsolete in ("diagnostic_disambiguation", "ClarifyingQuestion", "often_confused_with", "yes_weights_towards", "no_weights_towards"):
    assert obsolete not in source, f"Obsolete question machinery remains: {obsolete}"
print("PASS: exact schema cleanup; obsolete question types/validator removed. Runtime semantics verified by Deno tests separately.")
