BEGIN;
SELECT no_plan();

INSERT INTO public.installation_access(id,credential_hash)
VALUES ('16300000-0000-4000-8000-000000000890',repeat('f',64)) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.notification_claims(id,owner_id,kind,period_key,installation_id,scheduled_at,state,updated_at)
VALUES ('16300000-0000-4000-8000-000000000891','16300000-0000-4000-8000-000000000001',
        'progress_report','2026-11','16300000-0000-4000-8000-000000000890',
        '2026-11-01','scheduled','2026-11-01') ON CONFLICT(id) DO NOTHING;

UPDATE public.profiles
SET report_notifications_enabled=true,trial_reminder_enabled=true
WHERE id='16300000-0000-4000-8000-000000000001';
INSERT INTO public.plants(id,owner_id,creation_source,display_name,created_at,updated_at)
VALUES ('16300000-0000-4000-8000-000000000894','16300000-0000-4000-8000-000000000001',
        'identification','First','2026-10-31','2026-10-31'),
       ('16300000-0000-4000-8000-000000000895','16300000-0000-4000-8000-000000000001',
        'identification','Second','2026-11-01','2026-11-01');

CREATE TEMP TABLE first_page AS SELECT public.fetch_sync_delta(
    '16300000-0000-4000-8000-000000000001','2026-10-30','2026-11-02',NULL,NULL,NULL,1) body;
SELECT ok((SELECT NOT (body->'profile' ? 'report_notifications_enabled') FROM first_page),
    'live profile omits the report preference');
SELECT is((SELECT body#>>'{profile,trial_reminder_enabled}' FROM first_page),'true','trial preference remains in the same profile');
SELECT is((SELECT body#>>'{changes,0,id}' FROM first_page),'16300000-0000-4000-8000-000000000894',
    'first live page retains its active change');
SELECT is((SELECT body#>>'{last_cursor,entity_type}' FROM first_page),'plants','new cursor points to an active row');

CREATE TEMP TABLE resumed_page AS SELECT public.fetch_sync_delta(
    '16300000-0000-4000-8000-000000000001','2026-10-30','2026-11-02',
    '2026-11-01','notification_claim_summaries','16300000-0000-4000-8000-000000000891',1) body;
SELECT is((SELECT body#>>'{changes,0,id}' FROM resumed_page),'16300000-0000-4000-8000-000000000895',
    'a saved claim cursor resumes with the live entity at the same timestamp');
SELECT is((SELECT body->>'has_more' FROM resumed_page),'false','retired rows do not inflate pagination');
SELECT is((SELECT (body->>'next_since')::timestamptz FROM resumed_page),'2026-11-02'::timestamptz,
    'resumed last page advances the original window');

CREATE TEMP TABLE whole_page AS SELECT public.fetch_sync_delta(
    '16300000-0000-4000-8000-000000000001','2026-10-30','2026-11-02',NULL,NULL,NULL,2) body;
SELECT is((SELECT jsonb_array_length(body->'changes') FROM whole_page),2,'only two active rows enter the page limit');
SELECT is((SELECT body->>'has_more' FROM whole_page),'false','a retired row between active changes never creates an extra page');
SELECT ok(NOT EXISTS (SELECT 1 FROM whole_page CROSS JOIN LATERAL jsonb_array_elements(body->'changes') e
    WHERE e->>'entity_type'='notification_claim_summaries'),'no archived claim is projected into live sync');

SELECT ok((SELECT report_notifications_enabled AND trial_reminder_enabled FROM public.profiles
    WHERE id='16300000-0000-4000-8000-000000000001'),'stored preferences remain intact');
SELECT is((SELECT state FROM public.notification_claims WHERE id='16300000-0000-4000-8000-000000000891'),
    'scheduled','stored claim remains intact');
SELECT ok(has_function_privilege('service_role','public.fetch_sync_delta(uuid,timestamptz,timestamptz,timestamptz,text,uuid,integer)','execute')
    AND NOT has_function_privilege('authenticated','public.fetch_sync_delta(uuid,timestamptz,timestamptz,timestamptz,text,uuid,integer)','execute'),
    'sync RPC remains service-only');

SELECT * FROM finish();
ROLLBACK;
