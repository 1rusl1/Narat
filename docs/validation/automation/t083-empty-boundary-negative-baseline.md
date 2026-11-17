# T083: отрицательный контроль исправления024

17 ноября2026. Только локальная PostgreSQL17, синтетические fixtures.

Baseline: `fc15c074abe6f762f9ece83243735c658c634b6d` в
`/private/tmp/narat-empty-boundary-negative-20261117`. В этой отдельной
копии оставлена исходная024 и заменён только
`supabase/tests/auth_registration_profile.test.sql` точными новыми тестами run69.
Основной checkout не менялся во время проверки.

Команда из baseline checkout:

```sh
python3 tools/automation/parallel_backend_quota_gate.py --bind --installations --access --diagnosis-upload --diagnosis-jobs
```

Фактический результат: exit1, `Failed 9/2137 subtests` в clean:
2045–2046,2049–2050,2085–2086,2089–2091. Проверка2091
`024 foreign row unchanged complete/2`: have NULL, expected одна строка
с владельцем-соседом. Неправильная024 действительно удалила чужую строку
через FK на non-id unique ключ профиля. Также не прошли prepare/complete
HOLD и snapshot-проверки foreign target. Это ожидаемый отказ negative control,
не положительная продуктовая приёмка. Upgrade baseline после отказа не запускался.
Полный локальный лог: `/private/tmp/narat-empty-boundary-negative.log`.

SHA256:

- baseline SQL024: `530d1c2f7ee5fa3fa6b776ad1b8acd41b6ee9172cbdf9b30aeade19972b86ac4`
- исправленный SQL024: `9e62f21ef8d30679681c2c2d15f84e2c24a2b26eb6727060d2b69a9cf9b1fc1f`
- новые tests, одинаковые в обеих копиях: `aeecd100d85f41831ce6bd3ca8f5a27a96a5b1a6a687c44b6f4f3ac10638287d`

Положительный run69 с исправленной024 прошёл clean и seeded upgrade:
по2137 assertions auth_registration_profile, полный SQL regression и436Deno.
Лог: `/private/tmp/narat-backend-proof-20261117/docs/validation/automation/runs/orchestrator-t083-empty-account-boundary-link-repair-20261117-69/t083-empty-account-boundary-link-repair/check-4-parallel-backend-diagnosis-sql/stdout.log`.
Reviewer подтвердил код; QA69 остановился только из-за отсутствия этого
отрицательного контроля в переданных evidence. Его BLOCKED не заменён на PASS.
Auth/Admin live и полное удаление аккаунта не проверялись.
