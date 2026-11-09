# t019-auth-profile-fail-closed

Малый prerequisite T019/T162: закрыть fail-open defaultResolveRequestContext при отсутствующем/ошибочном profile; отдельно от command/sync и client save.

Подготовлен fail-closed auth/profile resolver и HTTP-тесты с подменённым транспортом Supabase.

Изменённые файлы: supabase/functions/_shared/tests/auth_profile_test.ts, supabase/functions/plants-api/index.ts.

Проверки:

- deno-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t019-auth-profile-20261109-01/t019-auth-profile-fail-closed/check-1-deno-check/stdout.log`
- diff-check: PASS, local, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t019-auth-profile-20261109-01/t019-auth-profile-fail-closed/check-2-diff-check/stdout.log`
- deno-tests: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t019-auth-profile-20261109-01/t019-auth-profile-fail-closed/check-3-deno-tests/stdout.log`
- t019-auth-profile: PASS, fixture, exit 0; log `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t019-auth-profile-20261109-01/t019-auth-profile-fail-closed/check-4-t019-auth-profile/stdout.log`

Review и QA подтвердили критерии manifest; это не автоматическое закрытие полной продуктовой задачи.

Решения: ["Изучены конституция 5.0.0, FR-040/FR-041 и границы API. Допускается профиль с active и булевым anonymous; owner берётся из проверенного Auth user.", "Ошибки lookup дают общий EN/PL ответ 503 INTERNAL_ERROR с retryable=true; отсутствующий/некорректный профиль — 403. Маршруты, явные обработчики и fallback T152 сохранены.", "Тесты используют настоящий Supabase client с подменённым fetch; resolveRequestContext не заменяется. Покрытие ограничено fixtures, live auth/save не проверяются.", "Файлы и Git не изменялись. Проверки не запускались: патч готов для обязательных проверок контроллера."].

Ограничения: подтверждены только явно указанные режимы и критерии. State/metrics: `/Users/ruslansabirov/Documents/ChatGPT/Plants/docs/validation/automation/runs/orchestrator-t019-auth-profile-20261109-01`.
Следующий шаг: следующая независимая задача manifest; ошибки публикации смотреть в state.json.
