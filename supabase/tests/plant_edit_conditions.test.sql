BEGIN;
SELECT no_plan();

CREATE TEMP TABLE condition_edit AS
SELECT gen_random_uuid() AS owner,gen_random_uuid() AS plant,gen_random_uuid() AS sibling,
    gen_random_uuid() AS snapshot,gen_random_uuid() AS sibling_snapshot,gen_random_uuid() AS operation;
INSERT INTO public.profiles(id,anonymous) SELECT owner,false FROM condition_edit;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT id,owner,'identification','Fixture' FROM condition_edit,LATERAL (VALUES(plant),(sibling)) p(id);
INSERT INTO public.condition_snapshots(id,owner_id,plant_id,light_code,light_source,light_confirmed,watering_code,season_override)
SELECT id,owner,target,'low','camera_estimate',true,'weekly','winter'
FROM condition_edit,LATERAL (VALUES(snapshot,plant),(sibling_snapshot,sibling)) s(id,target);
UPDATE public.plants p SET current_condition_snapshot_id=s.id
FROM public.condition_snapshots s,condition_edit f WHERE p.id=s.plant_id AND p.owner_id=f.owner;
INSERT INTO public.basic_care_memberships(owner_id,plant_id)
SELECT owner,id FROM condition_edit,LATERAL (VALUES(plant),(sibling)) p(id);

CREATE TEMP TABLE condition_plans AS
SELECT target, snap, gen_random_uuid() AS plan_id, gen_random_uuid() AS rule_id
FROM condition_edit,LATERAL (VALUES (plant,snapshot),(sibling,sibling_snapshot)) p(target,snap);
INSERT INTO public.care_plans(id,operation_id,owner_id,plant_id,locale,plan_kind,access_tier,
    source_kind,snapshot_id,kb_release_id,context_revision,full_body)
SELECT plan_id,gen_random_uuid(),owner,target,'en','routine','basic','catalogue',snap,k.id,1,'{}'
FROM condition_plans CROSS JOIN condition_edit CROSS JOIN public.kb_releases k WHERE k.state='published';
INSERT INTO public.task_rules(id,plan_id,owner_id,plant_id,access_class,action_code,condition_code,interval_days)
SELECT rule_id,plan_id,owner,target,'basic_care','check_soil','check_soil_first',7
FROM condition_plans CROSS JOIN condition_edit;
INSERT INTO public.care_tasks(owner_id,plant_id,rule_id,occurrence_key,action_code,due_local_date,state,reminder_eligible)
SELECT owner,target,rule_id,status,'check_soil',current_date+1,status,status='open'
FROM condition_plans CROSS JOIN condition_edit CROSS JOIN (VALUES('open'),('completed')) t(status);
INSERT INTO public.first_aid_followups(owner_id,plant_id,origin_analysis_id,kb_release_id,action_code,first_action_snapshot,state)
SELECT owner,plant,gen_random_uuid(),k.id,'check_soil','{}',t.status
FROM condition_edit CROSS JOIN public.kb_releases k CROSS JOIN (VALUES('active'),('completed')) t(status)
WHERE k.state='published';

CREATE TEMP TABLE condition_photo AS
SELECT (public.create_diagnosis_upload(owner,gen_random_uuid(),'image/jpeg',4,repeat('a',64))
    ->>'photo_asset_id')::uuid AS id FROM condition_edit;
SELECT public.mark_diagnosis_upload_ready(owner,id,repeat('a',64)) FROM condition_edit CROSS JOIN condition_photo;
CREATE TEMP TABLE condition_job AS
SELECT (public.create_plant_diagnosis_job(owner,gen_random_uuid(),id,NULL,'en',true,plant)#>>'{job,job_id}')::uuid AS id
FROM condition_edit CROSS JOIN condition_photo;
SELECT public.finalize_analysis_quota(id,'succeeded',false,clock_timestamp()) FROM condition_job;
UPDATE public.diagnosis_job_runtime r SET projection='{"fixture":"original diagnosis"}'
FROM condition_job j WHERE r.job_id=j.id;
INSERT INTO public.analysis_results(
    origin_analysis_id,mode,job_id,origin_job_id,owner_id,plant_id,source_photo_id,source_snapshot_id,
    locale,kb_release_id,classification,identification,result_hash,analysis_receipt)
SELECT gen_random_uuid(),'diagnosis',j.id,j.id,f.owner,f.plant,p.id,f.snapshot,'en',k.id,
    '{"fixture":"classification"}','{"fixture":"identification"}','fixture','fixture'
FROM condition_edit f CROSS JOIN condition_job j CROSS JOIN condition_photo p CROSS JOIN public.kb_releases k
WHERE k.state='published';
UPDATE public.photo_assets a SET plant_id=f.plant FROM condition_edit f,condition_photo p WHERE a.id=p.id;
UPDATE public.plants a SET main_photo_id=p.id FROM condition_edit f,condition_photo p WHERE a.id=f.plant;

CREATE TEMP TABLE condition_prior AS
SELECT to_jsonb(s) AS snapshot_row,
    public.read_diagnosis_job(f.owner,j.id) AS diagnosis,
    (SELECT to_jsonb(t) FROM public.care_tasks t WHERE t.plant_id=f.plant AND t.state='completed') AS completed,
    (SELECT to_jsonb(c) FROM public.first_aid_followups c WHERE c.plant_id=f.plant AND c.state='completed') AS completed_control
FROM condition_edit f JOIN public.condition_snapshots s ON s.id=f.snapshot CROSS JOIN condition_job j;

CREATE FUNCTION pg_temp.edit_conditions(payload JSONB, fresh BOOLEAN DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.execute_plant_edit_command(owner,CASE WHEN fresh THEN gen_random_uuid() ELSE operation END,plant,payload)
  FROM condition_edit
$$;
SELECT throws_ok($q$SELECT pg_temp.edit_conditions('{"conditions":{"light_code":"camera_estimate"}}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','camera code is invalid');
SELECT throws_ok($q$SELECT pg_temp.edit_conditions('{"conditions":{"watering_code":null}}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','unknown is explicit and null is invalid');
SELECT throws_ok($q$SELECT pg_temp.edit_conditions('{"conditions":{"drainage_code":"yes"},"taxon_id":null}')$q$,
    '22023','INVALID_PLANT_EDIT_INPUT','mixed taxon and conditions fail atomically');

-- Keep the same fixture executable at earlier migration cutoffs.
CREATE TEMP TABLE condition_sync_version AS
SELECT coalesce(obj_description('public.owner_sync_entries'::regclass, 'pg_class')
    = 'owner-sync:season-override-retired:057', false) AS retired;
CREATE TEMP TABLE condition_since AS
SELECT public.advance_owner_watermark(owner) AS ts FROM condition_edit;

CREATE TEMP TABLE condition_result AS
SELECT pg_temp.edit_conditions('{"conditions":{"drainage_code":"yes","pot_type":"terracotta"}}') AS receipt;
SELECT ok((SELECT s.version=2 AND s.watering_code='weekly' AND s.drainage_code='yes'
    AND s.pot_type='terracotta' AND s.light_code='low' AND s.light_source='camera_estimate'
    AND s.light_confirmed AND s.season_override='winter'
    FROM public.condition_snapshots s JOIN condition_result r ON s.id=(r.receipt->>'condition_snapshot_id')::uuid),
    'new snapshot changes explicit values and retains omitted historical conditions');
SELECT ok((SELECT p.revision=2 AND p.care_revision=2 AND p.personal_name='Fixture'
    AND p.main_photo_id=h.id AND p.current_snapshot_id=p.current_condition_snapshot_id
    FROM condition_edit f JOIN public.plants p ON p.id=f.plant CROSS JOIN condition_photo h),
    'only plant context and revision move to the new snapshot');
SELECT is((SELECT to_jsonb(s) FROM public.condition_snapshots s JOIN condition_edit f ON s.id=f.snapshot),
    (SELECT snapshot_row FROM condition_prior),'old snapshot remains byte-identical');
SELECT is((SELECT public.read_diagnosis_job(f.owner,j.id) FROM condition_edit f CROSS JOIN condition_job j),
    (SELECT diagnosis FROM condition_prior),'original diagnosis remains readable');
SELECT ok((SELECT a.context_state='stale' AND a.source_snapshot_id=f.snapshot AND a.source_care_revision=1
    AND a.classification='{"fixture":"classification"}'::jsonb AND a.analysis_receipt='fixture'
    FROM public.analysis_results a JOIN condition_edit f ON a.plant_id=f.plant),
    'summary is stale with its original snapshot, classification and receipt');
SELECT ok((SELECT public.read_owned_plant_photo(f.owner,f.plant)->>'photo_asset_id'=p.id::text
    FROM condition_edit f CROSS JOIN condition_photo p),'main photo is retained and readable');
SELECT ok((SELECT r.rule_state='paused' AND NOT t.reminder_eligible AND t.inactive_reason='plan_superseded'
    FROM condition_edit f JOIN public.task_rules r ON r.plant_id=f.plant
    JOIN public.care_tasks t ON t.rule_id=r.id AND t.state='open'),'obsolete future rule and reminder are paused');
SELECT ok((SELECT r.rule_state='active' AND t.reminder_eligible
    FROM condition_edit f JOIN public.task_rules r ON r.plant_id=f.sibling
    JOIN public.care_tasks t ON t.rule_id=r.id AND t.state='open'),'sibling future remains eligible');
SELECT is((SELECT to_jsonb(t) FROM public.care_tasks t JOIN condition_edit f ON t.plant_id=f.plant WHERE t.state='completed'),
    (SELECT completed FROM condition_prior),'completed history is unchanged');
SELECT is((SELECT to_jsonb(t) FROM public.first_aid_followups t JOIN condition_edit f ON t.plant_id=f.plant WHERE t.state='completed'),
    (SELECT completed_control FROM condition_prior),'completed first aid is unchanged');
SELECT ok((SELECT count(*)=1 FROM public.first_aid_followups t JOIN condition_edit f ON t.plant_id=f.plant WHERE t.state='superseded'),
    'only the obsolete active control is superseded');

SELECT ok((SELECT (public.read_plant_care_profile(owner,plant)->>'calendar_eligible')::boolean IS FALSE
    FROM condition_edit),'care recommendation stops offering a next automatic check');
SELECT is((SELECT p.updated_at FROM public.plants p JOIN condition_edit f ON p.id=f.plant),
    (SELECT s.updated_at FROM public.condition_snapshots s JOIN condition_result r
     ON s.id=(r.receipt->>'condition_snapshot_id')::uuid),'new snapshot and plant share one watermark');

-- Exercise the canonical service feed, rather than an alternative projection.
CREATE TEMP TABLE condition_feeds AS
SELECT 'full'::text AS mode, public.fetch_sync_delta(f.owner,NULL,
    (r.receipt->>'watermark')::timestamptz) AS body
FROM condition_edit f CROSS JOIN condition_result r
UNION ALL
SELECT 'delta', public.fetch_sync_delta(f.owner,b.ts,
    (r.receipt->>'watermark')::timestamptz)
FROM condition_edit f CROSS JOIN condition_since b CROSS JOIN condition_result r;
CREATE TEMP TABLE condition_feed_rows AS
SELECT mode,e.value AS entry FROM condition_feeds,
    LATERAL jsonb_array_elements(body->'changes') e
WHERE e.value->>'entity_type'='condition_snapshots';
SELECT is((SELECT count(*) FROM condition_feed_rows WHERE mode='full'),3::bigint,
    'full feed includes historical, sibling and new snapshots');
SELECT is((SELECT count(*) FROM condition_feed_rows WHERE mode='delta'),1::bigint,
    'delta includes only the newly created snapshot');
SELECT is((SELECT entry->>'id' FROM condition_feed_rows WHERE mode='delta'),
    (SELECT receipt->>'condition_snapshot_id' FROM condition_result),
    'delta uses the edited snapshot identity');
SELECT ok((SELECT bool_and((e.entry->'data') =
    (jsonb_build_object('id',s.id,'plant_id',s.plant_id,'version',s.version,
        'light_code',s.light_code,'light_source',s.light_source,'light_confirmed',s.light_confirmed,
        'watering_code',s.watering_code,'drainage_code',s.drainage_code,'pot_type',s.pot_type,
        'created_at',s.created_at)
     || CASE WHEN v.retired THEN '{}'::jsonb
        ELSE jsonb_build_object('season_override',s.season_override) END))
    FROM condition_feed_rows e JOIN public.condition_snapshots s ON s.id=(e.entry->>'id')::uuid
    CROSS JOIN condition_sync_version v),
    'full and delta preserve every snapshot key and historical confirmed light except retired season');
SELECT ok((SELECT bool_and(s.season_override='winter')
    FROM public.condition_snapshots s JOIN condition_edit f ON s.owner_id=f.owner),
    'old and edited snapshots still store winter');

CREATE TEMP TABLE condition_other AS SELECT gen_random_uuid() AS owner;
INSERT INTO public.profiles(id,anonymous) SELECT owner,false FROM condition_other;
SELECT is((SELECT jsonb_array_length(public.fetch_sync_delta(owner,NULL,
    (SELECT (receipt->>'watermark')::timestamptz FROM condition_result))->'changes')
    FROM condition_other),0,'another owner receives none of the fixture history');
SELECT ok(has_function_privilege('service_role',
    'public.fetch_sync_delta(uuid,timestamptz,timestamptz,timestamptz,text,uuid,integer)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
    'public.fetch_sync_delta(uuid,timestamptz,timestamptz,timestamptz,text,uuid,integer)','EXECUTE')
    AND NOT has_table_privilege('authenticated','public.owner_sync_entries','SELECT')
    AND NOT has_table_privilege('anon','public.owner_sync_entries','SELECT'),
    'canonical sync stays service-only');
GRANT SELECT ON public.condition_snapshots TO authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT owner::text FROM condition_other),true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.condition_snapshots),0::bigint,
    'cross-owner direct snapshot reads remain blocked');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',(SELECT owner::text FROM condition_edit),true);

SELECT public.reconcile_owner_basic_care(owner) FROM condition_edit;
SELECT public.execute_manual_care_command(owner,gen_random_uuid(),plant,'care.record',
    '{"action_code":"water","occurred_at":"2025-10-01T00:00:00Z","timezone":"UTC"}') FROM condition_edit;
SELECT ok((SELECT r.rule_state='paused' AND NOT t.reminder_eligible
    FROM condition_edit f JOIN public.task_rules r ON r.plant_id=f.plant
    JOIN public.care_tasks t ON t.rule_id=r.id AND t.state='open'),'reconciliation and manual care do not resume stale future');
SELECT is(pg_temp.edit_conditions('{"conditions":{"drainage_code":"yes","pot_type":"terracotta"}}'),
    (SELECT receipt FROM condition_result),'exact replay preserves original receipt');
SELECT is(pg_temp.edit_conditions('{"conditions":{"drainage_code":"yes"}}',true),
    (SELECT receipt FROM condition_result),'effective no-op keeps the current revision');
SELECT ok((pg_temp.edit_conditions('{"conditions":{"light_code":"low"}}',true)->>'care_revision')::int=3,
    'explicit manual confirmation replaces the camera source');
SELECT ok((SELECT s.light_source='manual' AND s.light_confirmed FROM public.plants p
    JOIN condition_edit f ON p.id=f.plant JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'explicit light edit derives manual source');

-- Reproduce the post-claim rename followed by a light-only edit, including
-- genuine historical watering context and a plant without a prior snapshot.
CREATE TEMP TABLE watered_edit AS
SELECT label,watered,gen_random_uuid() AS owner,gen_random_uuid() AS plant,
    gen_random_uuid() AS snapshot,gen_random_uuid() AS operation
FROM (VALUES ('claim','unknown'),('known','yes'),('historical','within_7_days'),('no_snapshot',NULL)) c(label,watered);
INSERT INTO public.profiles(id,anonymous) SELECT owner,false FROM watered_edit;
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT plant,owner,'identification','Before rename' FROM watered_edit;
INSERT INTO public.condition_snapshots(id,owner_id,plant_id,light_code,light_source,light_confirmed,
    drainage_code,last_watered)
SELECT snapshot,owner,plant,'low','manual',true,'no',watered FROM watered_edit WHERE watered IS NOT NULL;
UPDATE public.plants p SET current_condition_snapshot_id=f.snapshot
FROM watered_edit f WHERE p.id=f.plant AND f.watered IS NOT NULL;
CREATE TEMP TABLE watered_old AS
SELECT s.id,to_jsonb(s) AS body FROM public.condition_snapshots s
JOIN watered_edit f ON s.id=f.snapshot;
SELECT public.execute_plant_edit_command(owner,gen_random_uuid(),plant,
    '{"personal_name":"Renamed"}') FROM watered_edit;
CREATE TEMP TABLE watered_result AS
SELECT label,public.execute_plant_edit_command(owner,operation,plant,
    '{"conditions":{"light_code":"bright_indirect"}}') AS receipt FROM watered_edit;
SELECT is((SELECT count(*) FROM watered_result),4::bigint,'all last-watered cases execute');
SELECT ok((SELECT bool_and(s.last_watered=coalesce(f.watered,'unknown')
    AND s.drainage_code=CASE WHEN f.watered IS NULL THEN 'unknown' ELSE 'no' END
    AND s.light_code='bright_indirect' AND s.light_source='manual' AND s.light_confirmed
    AND s.version=CASE WHEN f.watered IS NULL THEN 1 ELSE 2 END)
    FROM watered_edit f JOIN watered_result r USING(label)
    JOIN public.condition_snapshots s ON s.id=(r.receipt->>'condition_snapshot_id')::uuid),
    'light-only edit preserves unknown and historical last-watered independently of known drainage');
SELECT ok((SELECT bool_and(p.personal_name='Renamed' AND p.revision=3 AND p.care_revision=2)
    FROM watered_edit f JOIN public.plants p ON p.id=f.plant),
    'rename then light edit changes only the expected revisions');
SELECT ok((SELECT bool_and(to_jsonb(s)=o.body) FROM watered_old o
    JOIN public.condition_snapshots s ON s.id=o.id),
    'light-only edits leave every original snapshot byte-identical');
CREATE TEMP TABLE watered_after AS
SELECT f.label,to_jsonb(p) AS plant_row,to_jsonb(s) AS snapshot_row
FROM watered_edit f JOIN public.plants p ON p.id=f.plant
JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id;
SELECT ok((SELECT bool_and(public.execute_plant_edit_command(f.owner,f.operation,f.plant,
    '{"conditions":{"light_code":"bright_indirect"}}')=r.receipt)
    FROM watered_edit f JOIN watered_result r USING(label)),
    'light-only exact replay returns each original receipt');
SELECT ok((SELECT bool_and(public.execute_plant_edit_command(f.owner,gen_random_uuid(),f.plant,
    '{"conditions":{"light_code":"bright_indirect"}}')=r.receipt)
    FROM watered_edit f JOIN watered_result r USING(label)),
    'light-only effective no-op returns each unchanged revision');
SELECT ok((SELECT bool_and(to_jsonb(p)=a.plant_row AND to_jsonb(s)=a.snapshot_row)
    FROM watered_edit f JOIN watered_after a USING(label)
    JOIN public.plants p ON p.id=f.plant
    JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'replay and no-op preserve the entire current plant and snapshot');
SELECT is((SELECT count(*) FROM public.condition_snapshots s
    JOIN watered_edit f ON s.plant_id=f.plant),7::bigint,
    'replay and no-op create no duplicate snapshots');

-- Canonical unknown must remain independent of yes/no and date-code history.
CREATE TEMP TABLE watered_unknown AS
SELECT label,gen_random_uuid() AS operation FROM watered_edit;
CREATE TEMP TABLE watered_unknown_result AS
SELECT f.label,public.execute_plant_edit_command(f.owner,u.operation,f.plant,
    '{"conditions":{"drainage_code":"unknown"}}') AS receipt
FROM watered_edit f JOIN watered_unknown u USING(label);
SELECT ok((SELECT bool_and(s.last_watered=coalesce(f.watered,'unknown')
    AND s.drainage_code='unknown')
    FROM watered_edit f JOIN public.plants p ON p.id=f.plant
    JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'explicit unknown drainage preserves each independent watering context');
CREATE TEMP TABLE watered_unknown_after AS
SELECT f.label,to_jsonb(p) AS plant_row,to_jsonb(s) AS snapshot_row
FROM watered_edit f JOIN public.plants p ON p.id=f.plant
JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id;
SELECT ok((SELECT bool_and(public.execute_plant_edit_command(f.owner,u.operation,f.plant,
    '{"conditions":{"drainage_code":"unknown"}}')=r.receipt)
    FROM watered_edit f JOIN watered_unknown u USING(label)
    JOIN watered_unknown_result r USING(label)),
    'explicit unknown exact replay returns the original receipt');
SELECT ok((SELECT bool_and(public.execute_plant_edit_command(f.owner,gen_random_uuid(),f.plant,
    '{"conditions":{"drainage_code":"unknown"}}')=r.receipt)
    FROM watered_edit f JOIN watered_unknown_result r USING(label)),
    'explicit unknown is an effective no-op after selection');
SELECT ok((SELECT bool_and(to_jsonb(p)=a.plant_row AND to_jsonb(s)=a.snapshot_row)
    FROM watered_edit f JOIN watered_unknown_after a USING(label)
    JOIN public.plants p ON p.id=f.plant
    JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'unknown replay and no-op preserve the entire plant and snapshot');
SELECT is((SELECT count(*) FROM public.condition_snapshots s
    JOIN watered_edit f ON s.plant_id=f.plant),10::bigint,
    'unknown replay and no-op create no duplicate snapshots');
SELECT public.execute_plant_edit_command(owner,gen_random_uuid(),plant,
    '{"conditions":{"light_code":"low"}}') FROM watered_edit;
SELECT ok((SELECT bool_and(s.last_watered=coalesce(f.watered,'unknown')
    AND s.drainage_code='unknown' AND s.light_code='low')
    FROM watered_edit f JOIN public.plants p ON p.id=f.plant
    JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'later light edits preserve unknown drainage and historical watering independently');
UPDATE public.condition_snapshots s SET deleted_at=clock_timestamp()
FROM watered_edit f,public.plants p
WHERE p.id=f.plant AND s.id=p.current_condition_snapshot_id;
SELECT ok((SELECT bool_and(s.last_watered=coalesce(f.watered,'unknown')
    AND s.drainage_code='unknown' AND s.deleted_at IS NOT NULL)
    FROM watered_edit f JOIN public.plants p ON p.id=f.plant
    JOIN public.condition_snapshots s ON s.id=p.current_condition_snapshot_id),
    'unrelated soft-delete preserves an independent pair');
SELECT ok((SELECT bool_and(to_jsonb(s)=o.body) FROM watered_old o
    JOIN public.condition_snapshots s ON s.id=o.id),
    'all historical snapshots remain byte-identical');
SELECT ok(coalesce(current_setting('narat.independent_snapshot_watered',true),'')<>'on',
    'canonical function restores the caller setting');
SELECT ok((SELECT prosecdef AND proconfig @> ARRAY['search_path=""',
    'narat.independent_snapshot_watered=on']::text[]
    FROM pg_proc WHERE oid='public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)'::regprocedure),
    'canonical edit retains empty search path and the scoped setting');
SELECT ok(has_function_privilege('service_role',
    'public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
    'public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)','EXECUTE')
    AND NOT has_function_privilege('anon',
    'public.execute_plant_edit_command(uuid,uuid,uuid,jsonb)','EXECUTE'),
    'canonical edit retains service-only execution');
-- Legacy writes below execute after the canonical function returns.
CREATE TEMP TABLE watered_legacy AS
SELECT gen_random_uuid() AS plant,gen_random_uuid() AS snapshot,
    gen_random_uuid() AS alias_snapshot,owner FROM watered_edit WHERE label='claim';
INSERT INTO public.plants(id,owner_id,creation_source,personal_name)
SELECT plant,owner,'identification','Legacy snapshot fixture' FROM watered_legacy;
INSERT INTO public.condition_snapshots(id,owner_id,plant_id,drainage_code)
SELECT snapshot,owner,plant,'yes' FROM watered_legacy;
INSERT INTO public.condition_snapshots(id,owner_id,plant_id,version,last_watered)
SELECT alias_snapshot,owner,plant,2,'over_7_days' FROM watered_legacy;
SELECT ok((SELECT s.last_watered='yes' FROM watered_legacy f
    JOIN public.condition_snapshots s ON s.id=f.snapshot),
    'legacy drainage-only writers still populate last-watered');
SELECT ok((SELECT s.drainage_code='over_7_days' FROM watered_legacy f
    JOIN public.condition_snapshots s ON s.id=f.alias_snapshot),
    'legacy last-watered-only writers still populate drainage');
SELECT * FROM finish();
ROLLBACK;
