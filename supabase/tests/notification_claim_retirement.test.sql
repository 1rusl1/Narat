BEGIN;
SELECT no_plan();

SELECT is(to_regprocedure('public.claim_notification_slot(uuid,uuid,text,text,text,timestamptz)'),
    NULL::regprocedure,'retired claim writer is unavailable');
SELECT is(to_regprocedure('public.cancel_notification_claim(uuid,text,text,timestamptz)'),
    NULL::regprocedure,'retired claim cancellation writer is unavailable');
SELECT throws_ok($q$SELECT public.claim_notification_slot(
    '16300000-0000-4000-8000-000000000001'::uuid,'16300000-0000-4000-8000-000000000893'::uuid,
    'monthly_report'::text,'2026-11'::text,'fixture'::text,now())$q$,
    '42883',NULL,'old direct claim RPC cannot create a row');
SELECT throws_ok($q$SELECT public.cancel_notification_claim(
    '16300000-0000-4000-8000-000000000001'::uuid,'trial_ending_24h'::text,'2026-11-12'::text,now())$q$,
    '42883',NULL,'old direct cancellation RPC cannot change history');

INSERT INTO public.installation_access(id,credential_hash)
VALUES ('16300000-0000-4000-8000-000000000890',repeat('f',64)) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.notification_claims(id,owner_id,kind,period_key,installation_id,scheduled_at,state,updated_at)
VALUES ('16300000-0000-4000-8000-000000000891','16300000-0000-4000-8000-000000000001',
        'progress_report','2026-11','16300000-0000-4000-8000-000000000890',
        '2026-11-01','scheduled','2026-11-01') ON CONFLICT(id) DO NOTHING;
INSERT INTO public.operation_receipts(owner_id,operation_id,command_name,payload_hash,response_payload)
VALUES ('16300000-0000-4000-8000-000000000001','16300000-0000-4000-8000-000000000892',
        'notification.claim','historical','{"granted":true}') ON CONFLICT(owner_id,operation_id) DO NOTHING;
SELECT is((SELECT state FROM public.notification_claims WHERE id='16300000-0000-4000-8000-000000000891'),
    'scheduled','stored notification claim remains available');
SELECT is((SELECT response_payload FROM public.operation_receipts WHERE
    owner_id='16300000-0000-4000-8000-000000000001' AND operation_id='16300000-0000-4000-8000-000000000892'),
    '{"granted":true}'::jsonb,'historical notification operation receipt remains intact');
SELECT ok(EXISTS (
    SELECT 1 FROM jsonb_array_elements(public.fetch_sync_delta(
        '16300000-0000-4000-8000-000000000001','2026-10-01',clock_timestamp(),NULL,NULL,NULL,500)->'changes') x
    WHERE x->>'entity_type'='notification_claim_summaries' AND x->'data'->>'kind'='progress_report'
),'older clients still read historical claims');

SELECT * FROM finish();
ROLLBACK;
