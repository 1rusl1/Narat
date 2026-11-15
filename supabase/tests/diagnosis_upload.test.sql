BEGIN;
SELECT plan(13);

CREATE TEMP TABLE upload_fixture AS
SELECT public.create_diagnosis_upload(
    '16300000-0000-4000-8000-000000000002', '16310000-0000-4000-8000-000000000001',
    'image/jpeg', 4, repeat('a',64)
) AS ticket;
SELECT is((SELECT ticket->>'state' FROM upload_fixture), 'initialized', 'ticket creates pending photo');
SELECT ok((SELECT (ticket->>'expires_in_seconds')::int BETWEEN 59 AND 60 FROM upload_fixture), 'ticket expires in 60 seconds');
SELECT is((SELECT ticket->>'storage_path' FROM upload_fixture),
    (SELECT (ticket->>'owner_id') || '/' || (ticket->>'photo_asset_id') FROM upload_fixture), 'owner-scoped object key');
SELECT is(public.create_diagnosis_upload(
    '16300000-0000-4000-8000-000000000002','16310000-0000-4000-8000-000000000001',
    'image/jpeg',4,repeat('a',64))->>'photo_asset_id',
    (SELECT ticket->>'photo_asset_id' FROM upload_fixture), 'same operation reuses asset');
SELECT throws_ok($q$SELECT public.create_diagnosis_upload('16300000-0000-4000-8000-000000000002',
    '16310000-0000-4000-8000-000000000001','image/jpeg',5,repeat('a',64))$q$,
    '23505','IDEMPOTENCY_CONFLICT','changed payload conflicts');
SELECT is(public.read_diagnosis_upload('16300000-0000-4000-8000-000000000001',
    (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture)), NULL::jsonb, 'foreign photo hidden');
SELECT throws_ok($q$SELECT public.mark_diagnosis_upload_ready('16300000-0000-4000-8000-000000000002',
    (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture),repeat('b',64))$q$,
    'P0002','PHOTO_NOT_FOUND','different hash cannot mark ready');
SELECT is(public.mark_diagnosis_upload_ready('16300000-0000-4000-8000-000000000002',
    (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture),repeat('a',64))->>'state',
    'ready','verified object becomes ready');
CREATE TEMP TABLE before_ready AS SELECT uploaded_at FROM public.photo_assets
WHERE id = (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture);
SELECT public.mark_diagnosis_upload_ready('16300000-0000-4000-8000-000000000002',
    (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture),repeat('a',64));
SELECT is((SELECT uploaded_at FROM public.photo_assets WHERE id =
    (SELECT (ticket->>'photo_asset_id')::uuid FROM upload_fixture)),
    (SELECT uploaded_at FROM before_ready), 'ready retry preserves upload timestamp');
SELECT ok(NOT has_function_privilege('authenticated','public.create_diagnosis_upload(uuid,uuid,text,integer,text)','execute'), 'client cannot mint tickets directly');
SELECT ok(NOT has_function_privilege('authenticated','public.mark_diagnosis_upload_ready(uuid,uuid,text)','execute'), 'client cannot mark unverified photo ready');
SELECT ok(NOT has_table_privilege('authenticated','public.diagnosis_upload_tickets','select'), 'ticket data is private');
SELECT ok((SELECT NOT public AND file_size_limit = 10485760 FROM storage.buckets WHERE id='analysis-inputs'), 'migration creates private bounded bucket');
SELECT * FROM finish();
ROLLBACK;
