"""Narrow T168 client retirement; behavioral proof is in PlantsTests/UI gates."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
sources = list((root / 'ios/Plants').rglob('*.swift'))
for source in sources:
    text = source.read_text()
    for symbol in ('LightingEstimateResult', 'LightingEstimating', 'applyEstimatedLighting'):
        assert not re.search(r'\b' + symbol + r'\b', text), f'Retired new-camera writer {symbol}: {source}'
model = (root / 'ios/Plants/Features/Analysis/AnalysisFlowModel.swift').read_text()
assert re.search(r'func selectLightLevel\(_ level: LightLevel\)', model), 'Manual input must not accept a caller-supplied camera source'
domain = (root / 'ios/Plants/Domain/PlantTypes.swift').read_text()
assert 'case cameraEstimate = "camera_estimate"' in domain, 'Historical light origin must remain decodable'
print('PASS: obsolete light-estimator writer/protocol removed; historical enum retained. Full server T168 remains separate.')
