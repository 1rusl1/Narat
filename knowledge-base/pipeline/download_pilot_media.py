"""Original pilot media only. Per-file rights checked; no operator contact embedded in source."""
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.parse import urlencode
from datetime import datetime,timezone
import hashlib,json,time,html,re
import argparse
from rights import require_operations
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description="Fetch individually licensed pilot media; no runtime catalogue requests")
parser.add_argument('--user-agent',required=True)
parser.add_argument('--offline',action='store_true')
args=parser.parse_args()
AGENT=args.user_agent
registry=json.loads((ROOT/'knowledge-base/manifests/source-registry.json').read_text())
source=require_operations(registry,'wikimedia_commons_pilot_assets',['store_raw','download_media']+([] if args.offline else ['automated_fetch']))
if not args.offline and not re.search(r'https?://|[\w.+-]+@[\w.-]+',AGENT):
 raise ValueError('A real public operator contact is required')
items=[('monstera_deliciosa','Monstera deliciosa2.jpg','Raul654','CC-BY-SA-3.0','https://creativecommons.org/licenses/by-sa/3.0/'),('ficus_elastica','Da bup do.jpg','VuThiAnh','CC0-1.0','https://creativecommons.org/publicdomain/zero/1.0/'),('epipremnum_aureum','Epipremnum aureum 31082012.jpg','Joydeep','CC-BY-SA-3.0','https://creativecommons.org/licenses/by-sa/3.0/')]
manifest=[]
for plant_id,title,author,license_code,license_url in items:
 if title not in source['allowed_asset_titles']:raise ValueError('Unreviewed asset')
 query=urlencode({'action':'query','titles':'File:'+title,'prop':'imageinfo','iiprop':'url|extmetadata|timestamp|sha1|size','format':'json','formatversion':2})
 api='https://commons.wikimedia.org/w/api.php?'+query
 rawdir=ROOT/'knowledge-base/raw/commons';rawdir.mkdir(parents=True,exist_ok=True)
 cached=rawdir/(plant_id+'.metadata.json')
 if cached.exists():payload=cached.read_bytes()
 elif args.offline:raise ValueError('Missing cached image metadata')
 else:
  with urlopen(Request(api,headers={'User-Agent':AGENT,'Accept':'application/json'}),timeout=30) as r:payload=r.read()
 doc=json.loads(payload);page=doc['query']['pages'][0];info=page['imageinfo'][0]
 reported=info.get('extmetadata',{}).get('LicenseShortName',{}).get('value')
 expected='CC0' if license_code=='CC0-1.0' else 'CC BY-SA 3.0'
 if reported!=expected:raise ValueError('Asset license changed or is unknown; review required')
 full=info['url']
 if not full.startswith('https://upload.wikimedia.org/'):raise ValueError('Unexpected media host')
 rawdir=ROOT/'knowledge-base/raw/commons';rawdir.mkdir(parents=True,exist_ok=True)
 (rawdir/(plant_id+'.metadata.json')).write_bytes(payload)
 target=ROOT/'knowledge-base/raw/media'/f'{plant_id}.jpg';target.parent.mkdir(parents=True,exist_ok=True)
 if not target.exists():
  if args.offline:raise ValueError('Missing cached original media')
  with urlopen(Request(full,headers={'User-Agent':AGENT}),timeout=60) as response:binary=response.read(25000001)
  if len(binary)>25000000 or not binary.startswith(b'\xff\xd8'):raise ValueError('Unexpected media size/format')
  target.write_bytes(binary)
 else:binary=target.read_bytes()
 actual_sha1=hashlib.sha1(binary).hexdigest()
 if info.get('sha1') and actual_sha1!=info['sha1']:raise ValueError('Source SHA1 mismatch')
 entry={'plant_id':plant_id,'file_title':'File:'+title,'source_page':info['descriptionurl'],'source_url':full,'source_page_id':page['pageid'],'source_revision_timestamp':info['timestamp'],'api_metadata':str((rawdir/(plant_id+'.metadata.json')).relative_to(ROOT)),'api_metadata_sha256':hashlib.sha256(payload).hexdigest(),'local_path':str(target.relative_to(ROOT)),'license':license_code,'license_url':license_url,'author':author,'author_reported_by_api':info.get('extmetadata',{}).get('Artist',{}).get('value'),'attribution':f'{title} — {author} / Wikimedia Commons / {license_code}','modifications':'None; original file downloaded unchanged','sha256':hashlib.sha256(binary).hexdigest(),'sha1':actual_sha1,'width':info['width'],'height':info['height'],'bytes':len(binary),'retrieved_at':datetime.fromtimestamp(target.stat().st_mtime,timezone.utc).isoformat(),'verified_at':datetime.now(timezone.utc).isoformat(),'review_status':'pilot_asset_license_reviewed; species/photo suitability requires editorial confirmation'}
 manifest.append(entry)
 print(plant_id,len(binary),info['width'],info['height'],license_code,flush=True)
 if not args.offline:time.sleep(1)
p=ROOT/'catalogue/manifests/pilot-media.json';p.write_text(json.dumps({'schema_version':'1.0','assets':manifest},ensure_ascii=False,indent=2)+'\n')
