from pathlib import Path
import hashlib
R=Path(__file__).resolve().parents[2]
s=(R/'ios/Plants/Data/Remote/APIModels.swift').read_text()
normalized='\n'.join(line.rstrip() for line in s.splitlines() if line.strip())
assert hashlib.sha256(normalized.encode()).hexdigest()=='76bc50b09d513e18e382049cd95b5f6cdf4a97605e5c9b722c14416c97956c06','Only remove the three unused structs and their obsolete section marker; other DTOs unchanged'
for name in ['RecoveryCheckDTO','TreatmentStepDTO','ConditionProfileDTO']:
    for p in (R/'ios').rglob('*.swift'):
        assert name not in p.read_text(),f'Obsolete DTO reference {name}: {p}'
print('PASS: unused profile/timeline/comparison DTOs removed; all other Swift DTO fields preserved.')
