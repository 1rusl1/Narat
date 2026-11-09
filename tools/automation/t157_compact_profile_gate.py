"""Versioned compact profile contract gate; old v1 is immutable reference only."""
from pathlib import Path
import copy,hashlib,json,sys
R=Path(__file__).resolve().parents[2]
C=R/'specs/001-plants-ios-mvp/contracts'
LEGACY={'condition-profile.schema.json': 'e0e0843d48f8e104f43b71dd75ca0c1b6a0a766a515ba3be89fa96c0c4021d8f', 'plant-profile.schema.json': 'd27d4ab2a26fb1abadc7d560cc905c31956344ed24d4982303d111c977c2da5b'}

def source(name):
    path=C/'legacy'/name.replace('.schema.json','.v1.schema.json')
    assert hashlib.sha256(path.read_bytes()).hexdigest()==LEGACY[name], 'Legacy snapshot changed: '+name
    return json.loads(path.read_text())

def action_schema(old):
    props=old['properties']['treatment_plan']['properties']['steps']['items']['properties']
    keys=['action_code','purpose','prerequisite_check_ids','contraindication_check_ids','action_pl','action_en']
    fields={key:copy.deepcopy(props[key]) for key in keys}
    fields['action_id']=copy.deepcopy(props['step_id'])
    fields['next_check_interval_days']={'anyOf':[{'type':'integer','minimum':1,'maximum':90},{'type':'null'}]}
    fields['active_ingredients']=copy.deepcopy(props['active_ingredients'])
    return {'type':'object','additionalProperties':False,'required':['action_id',*keys,'next_check_interval_days'],'properties':fields}

def expected_condition():
    old=source('condition-profile.schema.json');props=old['properties']
    names=['schema_version','kb_release_id','record_version','provenance','condition_id','host_scope','visual_markers','contraindication_check_ids','condition_content_i18n']
    result={'type':'object','additionalProperties':False,'required':names+['first_help_action_id','actions'],'properties':{k:copy.deepcopy(props[k]) for k in names}}
    p=result['properties'];p['schema_version']={'const':'2.0'}
    p['first_help_action_id']=copy.deepcopy(props['first_help_step_id'])
    p['actions']={'type':'array','minItems':1,'items':action_schema(old)}
    for locale in ['en','pl']:
        content=p['condition_content_i18n']['properties'][locale]
        content['required']=['title','summary'];content['properties']={k:content['properties'][k] for k in ['title','summary']}
    return result

def expected_plant():
    old=source('plant-profile.schema.json');condition=source('condition-profile.schema.json')
    names=['schema_version','kb_release_id','record_version','provenance','plant_id','safety']
    result={'type':'object','additionalProperties':False,'required':['schema_version','kb_release_id','record_version','provenance','plant_id','actions'],'properties':{k:copy.deepcopy(old['properties'][k]) for k in names}}
    result['properties']['schema_version']={'const':'2.0'}
    result['properties']['actions']={'type':'array','items':action_schema(condition)}
    # A single care action or an independent safety fact, never a fake full profile.
    result['anyOf']=[{'properties':{'actions':{'minItems':1}}},{'required':['safety']}]
    return result

def main():
    mode=sys.argv[1]
    expected=expected_condition() if mode=='condition' else expected_plant()
    name='condition-profile.schema.json' if mode=='condition' else 'plant-profile.schema.json'
    assert json.loads((C/name).read_text())==expected,'Compact schema differs from approved technical format: '+name
    if mode=='condition':
        text=(R/'supabase/functions/_shared/KnowledgeTypes.ts').read_text()
        for obsolete in ['interface TreatmentStep','treatment_plan:','first_help_step_id:','repeat_count:','start_offset_days:']:
            assert obsolete not in text,obsolete
    print('PASS: exact compact '+mode+' profile v2; v1 snapshot preserved; behavior checked separately by Deno.')
if __name__=='__main__':main()
