from pathlib import Path
import re
R=Path(__file__).resolve().parents[2]
s=(R/'supabase/functions/_shared/ProtocolResolver.ts').read_text()
for obsolete in ['DecisionStateDTO','DecisionResolutionInputState','decisionState','decision_state']:
    assert obsolete not in s, obsolete
assert not re.search(r'confidence\s*(?:>=|<=|>|<)|gap\s*(?:>=|<=|>|<)',s)
s=(R/'ios/Plants/Data/Remote/APIModels.swift').read_text()
for obsolete in ['DiagnosticQuestionOptionDTO','DiagnosticQuestionDTO','DiagnosticAnswerDTO','DiagnosticResolutionState','DiagnosticDecisionDTO']:
    assert obsolete not in s,obsolete
print('PASS: no score routing/decision-question machinery in resolver/Swift DTO; semantic behavior checked by Deno/Swift.')
