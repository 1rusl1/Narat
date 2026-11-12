BEGIN;

-- Filter the live delta before pagination. The historical rows and their owner view stay intact.
CREATE OR REPLACE FUNCTION public.fetch_sync_delta(
    p_owner_id UUID,
    p_since TIMESTAMPTZ DEFAULT NULL,
    p_until TIMESTAMPTZ DEFAULT NULL,
    p_cursor_updated_at TIMESTAMPTZ DEFAULT NULL,
    p_cursor_entity_type TEXT DEFAULT NULL,
    p_cursor_id UUID DEFAULT NULL,
    p_limit INT DEFAULT 200
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_profile RECORD;
    v_entitlement RECORD;
    v_until TIMESTAMPTZ;
    v_rows JSONB;
    v_count INT;
    v_last_updated_at TIMESTAMPTZ;
    v_last_entity_type TEXT;
    v_last_id UUID;
    v_has_more BOOLEAN := false;
BEGIN
    SELECT
        id,
        account_state,
        preferred_locale,
        reminder_hour_local,
        trial_reminder_enabled,
        updated_at
      INTO v_profile
      FROM public.profiles
     WHERE id = p_owner_id
       FOR UPDATE;

    IF NOT FOUND OR v_profile.account_state <> 'active' THEN
        RAISE EXCEPTION 'owner_forbidden' USING ERRCODE = '42501';
    END IF;

    v_until := COALESCE(p_until, v_profile.updated_at);

    SELECT
        product_id,
        state,
        offer_kind,
        valid_until,
        grace_until,
        trial_end_at,
        auto_renew_enabled
      INTO v_entitlement
      FROM public.entitlements
     WHERE owner_id = p_owner_id;

    WITH ordered_entries AS (
        SELECT
            e.entity_type,
            e.id,
            e.updated_at,
            e.deleted_at,
            e.data
        FROM public.owner_sync_entries e
        WHERE e.owner_id = p_owner_id
          AND e.entity_type <> 'notification_claim_summaries'
          AND (p_since IS NULL OR e.updated_at > p_since)
          AND e.updated_at <= v_until
          AND (
              p_cursor_updated_at IS NULL
              OR (e.updated_at, e.entity_type, e.id) > (p_cursor_updated_at, p_cursor_entity_type, p_cursor_id)
          )
        ORDER BY e.updated_at ASC, e.entity_type ASC, e.id ASC
        LIMIT (p_limit + 1)
    ),
    page_rows AS (
        SELECT * FROM ordered_entries LIMIT p_limit
    )
    SELECT
        COALESCE(jsonb_agg(
            jsonb_build_object(
                'entity_type', pr.entity_type,
                'id', pr.id,
                'updated_at', pr.updated_at,
                'deleted_at', pr.deleted_at,
                'data', pr.data
            )
        ), '[]'::jsonb),
        (SELECT count(*) FROM ordered_entries),
        (SELECT updated_at FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1),
        (SELECT entity_type FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1),
        (SELECT id FROM page_rows ORDER BY updated_at DESC, entity_type DESC, id DESC LIMIT 1)
    INTO v_rows, v_count, v_last_updated_at, v_last_entity_type, v_last_id
    FROM page_rows pr;

    v_has_more := v_count > p_limit;

    RETURN jsonb_build_object(
        'until', v_until,
        'has_more', v_has_more,
        'last_cursor', CASE WHEN v_has_more THEN jsonb_build_object(
            'since', p_since,
            'until', v_until,
            'updated_at', v_last_updated_at,
            'entity_type', v_last_entity_type,
            'id', v_last_id
        ) ELSE NULL END,
        'next_since', CASE WHEN v_has_more THEN NULL ELSE v_until END,
        'profile', jsonb_build_object(
            'preferred_locale', v_profile.preferred_locale,
            'reminder_hour_local', v_profile.reminder_hour_local,
            'trial_reminder_enabled', v_profile.trial_reminder_enabled
        ),
        'entitlement', CASE WHEN v_entitlement.product_id IS NULL THEN NULL ELSE jsonb_build_object(
            'product_id', v_entitlement.product_id,
            'state', v_entitlement.state,
            'offer_kind', v_entitlement.offer_kind,
            'valid_until', v_entitlement.valid_until,
            'grace_until', v_entitlement.grace_until,
            'trial_end_at', v_entitlement.trial_end_at,
            'auto_renew_enabled', v_entitlement.auto_renew_enabled
        ) END,
        'changes', v_rows
    );
END;
$$;

COMMIT;
