-- ============================================================================
-- pgTAP Tests: supabase/tests/free_care.test.sql
-- Task: T131 (Free basic care up to 3 selected plants, 4th plant requires selection,
--             atomic free_care.select, paid->Free expiry fallback, plant deletion frees slot)
-- Coverage: SC-014, SC-021, V46, V50
-- ============================================================================

BEGIN;
SELECT plan(10);

DO $$
DECLARE
    v_owner UUID := '77777777-7777-4777-8777-777777777701';
    v_species UUID := '77777777-7777-4777-8777-777777777799';
    v_p1 UUID := '77777777-7777-4777-8777-777777777711';
    v_p2 UUID := '77777777-7777-4777-8777-777777777712';
    v_p3 UUID := '77777777-7777-4777-8777-777777777713';
    v_p4 UUID := '77777777-7777-4777-8777-777777777714';
BEGIN
    INSERT INTO public.profiles (id, locale) VALUES (v_owner, 'pl');
    INSERT INTO public.plant_species (id, plant_key, scientific_name, name_en, name_pl, care_profile_available)
    VALUES (v_species, 'monstera_test', 'Monstera deliciosa', 'Monstera', 'Monstera', true);

    INSERT INTO public.plants (id, owner_id, species_id, display_name, origin_intent, add_method)
    VALUES
        (v_p1, v_owner, v_species, 'P1', 'care', 'catalogue'),
        (v_p2, v_owner, v_species, 'P2', 'care', 'catalogue'),
        (v_p3, v_owner, v_species, 'P3', 'care', 'catalogue'),
        (v_p4, v_owner, v_species, 'P4', 'care', 'catalogue');

    PERFORM public.execute_basic_care_command(
        v_owner,
        '77777777-7777-4777-8777-000000000001',
        'basic_care.enable',
        jsonb_build_object('plant_id', v_p1)
    );
    PERFORM public.execute_basic_care_command(
        v_owner,
        '77777777-7777-4777-8777-000000000002',
        'basic_care.enable',
        jsonb_build_object('plant_id', v_p2)
    );
    PERFORM public.execute_basic_care_command(
        v_owner,
        '77777777-7777-4777-8777-000000000003',
        'basic_care.enable',
        jsonb_build_object('plant_id', v_p3)
    );
END $$;

-- 1..3: First 3 plants automatically get slots 1..3
SELECT is(
    (SELECT count(*)::int FROM public.basic_care_memberships
     WHERE owner_id = '77777777-7777-4777-8777-777777777701' AND free_slot BETWEEN 1 AND 3),
    3,
    'First 3 enabled plants occupy free_slot 1..3'
);

SELECT is(
    (SELECT free_selection_explicit FROM public.profiles WHERE id = '77777777-7777-4777-8777-777777777701'),
    false,
    'free_selection_explicit remains false before explicit selection'
);

-- 3: Enabling 4th plant without selection fails with free_limit_reached_select_required
SELECT throws_ok(
    $$SELECT public.execute_basic_care_command(
        '77777777-7777-4777-8777-777777777701',
        '77777777-7777-4777-8777-000000000004',
        'basic_care.enable',
        jsonb_build_object('plant_id', '77777777-7777-4777-8777-777777777714')
    )$$,
    '22023',
    'free_limit_reached_select_required',
    '4th plant requires explicit free_care.select on Free tier'
);

-- 4..7: Atomic free_care.select enables P4 and replaces P2
SELECT lives_ok(
    $$SELECT public.execute_basic_care_command(
        '77777777-7777-4777-8777-777777777701',
        '77777777-7777-4777-8777-000000000005',
        'free_care.select',
        jsonb_build_object('selected_plant_ids', jsonb_build_array(
            '77777777-7777-4777-8777-777777777711',
            '77777777-7777-4777-8777-777777777714',
            '77777777-7777-4777-8777-777777777713'
        ))
    )$$,
    'free_care.select atomically enables P4 and updates slots 1..3'
);

SELECT is(
    (SELECT free_selection_explicit FROM public.profiles WHERE id = '77777777-7777-4777-8777-777777777701'),
    true,
    'free_selection_explicit becomes true after free_care.select'
);

SELECT is(
    (SELECT free_slot FROM public.basic_care_memberships
     WHERE owner_id = '77777777-7777-4777-8777-777777777701'
       AND plant_id = '77777777-7777-4777-8777-777777777714'),
    2,
    'P4 receives free_slot = 2'
);

SELECT is(
    (SELECT free_slot FROM public.basic_care_memberships
     WHERE owner_id = '77777777-7777-4777-8777-777777777701'
       AND plant_id = '77777777-7777-4777-8777-777777777712'),
    NULL,
    'Excluded plant P2 has free_slot = NULL while keeping membership row'
);

-- 8..10: Soft-deleting P4 frees its slot
UPDATE public.plants
SET deleted_at = clock_timestamp()
WHERE id = '77777777-7777-4777-8777-777777777714';

SELECT is(
    (SELECT free_slot FROM public.basic_care_memberships
     WHERE owner_id = '77777777-7777-4777-8777-777777777701'
       AND plant_id = '77777777-7777-4777-8777-777777777714'),
    NULL,
    'Soft-deleting P4 frees its free_slot'
);

SELECT is(
    (SELECT count(*)::int FROM public.basic_care_memberships
     WHERE owner_id = '77777777-7777-4777-8777-777777777701' AND free_slot BETWEEN 1 AND 3),
    2,
    'Only 2 slots remain occupied after P4 deletion'
);

SELECT lives_ok(
    $$SELECT public.execute_basic_care_command(
        '77777777-7777-4777-8777-777777777701',
        '77777777-7777-4777-8777-000000000006',
        'free_care.select',
        jsonb_build_object('selected_plant_ids', jsonb_build_array(
            '77777777-7777-4777-8777-777777777711',
            '77777777-7777-4777-8777-777777777712',
            '77777777-7777-4777-8777-777777777713'
        ))
    )$$,
    'Re-selecting P2 into free_slot 2 succeeds'
);

SELECT * FROM finish();
ROLLBACK;
