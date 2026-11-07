-- ============================================================================
-- pgTAP Test Suite: rls_boundary.test.sql
-- Tasks: T016 [P]
-- Coverage: FR-041, SC-009 (Account A/B isolation, deleting account revocation, full_body protection)
-- ============================================================================

BEGIN;

SELECT plan(8);

-- Setup test users A (active), B (active), C (deleting)
INSERT INTO public.profiles (id, account_state, anonymous, preferred_locale)
VALUES
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'active', false, 'pl'),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'active', false, 'en'),
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'deleting', false, 'pl');

INSERT INTO public.plants (id, owner_id, creation_intent, add_method, personal_name, creation_source)
VALUES
    ('11111111-aaaa-4aaa-8aaa-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'problem', 'scan', 'Monstera A', 'analysis'),
    ('22222222-bbbb-4bbb-8bbb-222222222222', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'care', 'scan', 'Ficus B', 'identification'),
    ('33333333-cccc-4ccc-8ccc-333333333333', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'problem', 'scan', 'Deleting C', 'analysis');

-- Simulate authenticated session as Owner A
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claim.sub" = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

SELECT is(
    (SELECT count(*)::int FROM public.plants),
    1,
    'Owner A sees only their own 1 plant'
);

SELECT is(
    (SELECT count(*)::int FROM public.plants WHERE owner_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
    0,
    'Owner A cannot read Owner B plants'
);

SELECT is(
    (SELECT count(*)::int FROM public.care_profiles),
    0,
    'Authenticated client cannot directly read server-only Golden Record care_profiles'
);

SELECT is(
    (SELECT count(*)::int FROM public.condition_profiles),
    0,
    'Authenticated client cannot directly read server-only Golden Record condition_profiles'
);

SELECT is(
    (SELECT count(*)::int FROM public.care_plans),
    0,
    'Authenticated client cannot directly query raw care_plans table containing full_body'
);

-- Simulate authenticated session as Owner B
SET LOCAL "request.jwt.claim.sub" = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

SELECT is(
    (SELECT personal_name FROM public.plants LIMIT 1),
    'Ficus B',
    'Owner B sees only Ficus B'
);

-- Simulate authenticated session as Deleting Owner C (still holding an unexpired JWT)
SET LOCAL "request.jwt.claim.sub" = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

SELECT is(
    (SELECT count(*)::int FROM public.plants),
    0,
    'Deleting account C is immediately blocked from reading plants even with valid JWT'
);

SELECT is(
    (SELECT count(*)::int FROM public.profiles),
    0,
    'Deleting account C is immediately blocked from reading profile'
);

SELECT * FROM finish();

ROLLBACK;
