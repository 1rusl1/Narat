"""Independent structural gate for new AI mode contraction; behavior checked by Deno/Swift."""
from pathlib import Path
import json
R=Path(__file__).resolve().parents[2]
s=json.loads((R/'specs/001-plants-ios-mvp/contracts/ai-result.schema.json').read_text())
assert set(s['properties']['mode']['enum']) == {'identification','diagnosis'}
assert 'comparison' not in s['properties'] and 'comparison' not in s['required']
assert 'follow_up' not in json.dumps(s) and 'comparison_unsuitable' not in json.dumps(s)
assert s.get('additionalProperties') is False
assert 'diagnostic_disambiguation' not in json.loads((R/'specs/001-plants-ios-mvp/contracts/condition-profile.schema.json').read_text())['properties']
for f in ['supabase/functions/_shared/AnthropicAdapter.ts','supabase/functions/analysis-worker/index.ts']:
    source=(R/f).read_text()
    assert 'comparisonTraitsHint' not in source and 'comparison_traits_hint' not in source,f
swift=(R/'ios/Plants/Data/Repositories/AnalysisAccessRepository.swift').read_text()
assert 'followUpQuota' not in swift
print('PASS: two-mode schema, no new comparison/hints/followUp quota; legacy behavior requires Deno/Swift tests.')
