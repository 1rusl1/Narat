from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[2]
EXPECTED={'condition-profile.schema.json': '6db2a4709c3606967e3f560332d3eab47e71dfd6d321062e8a9d052bc1302830', 'plant-profile.schema.json': 'a2fd4831227a3ee241d92030dc455e284f3a85e1a68106ec6be17a3efe395030'}
for name,digest in EXPECTED.items():
    s=json.loads((R/'specs/001-plants-ios-mvp/contracts'/name).read_text())
    assert hashlib.sha256(json.dumps(s,sort_keys=True,separators=(',',':')).encode()).hexdigest()==digest,name
print('PASS: exact schema reduction for one-source/manual review without weakening other facts/rights constraints.')
