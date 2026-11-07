from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'pipeline'))
from export_pilot import export


class PilotExportTests(unittest.TestCase):
    def setup_data(self, root):
        media=root/'knowledge-base/raw/media/example.jpg'
        media.parent.mkdir(parents=True);media.write_bytes(b'photo-fixture')
        asset={'plant_id':'example_species','local_path':str(media.relative_to(root)),
               'sha256':hashlib.sha256(media.read_bytes()).hexdigest(), 'license':'CC0-1.0','author':'Fixture author'}
        manifest=root/'media.json';manifest.write_text(json.dumps({'assets':[asset]}))
        database=root/'catalogue.sqlite'
        with closing(sqlite3.connect(database)) as db, db:
            db.execute('CREATE TABLE catalogue_drafts(plant_id TEXT PRIMARY KEY,payload_json TEXT)')
            record={'plant_id':'example_species','scientific_name':'Example species','labels':{'pl':'Example PL','en':'Example EN'},'wikidata_id':'Q1','source_revision':123,'care':None,'safety':{'cat':'unknown','dog':'unknown'}}
            db.execute('INSERT INTO catalogue_drafts VALUES (?,?)',('example_species',json.dumps(record)))
        return media,manifest,database,asset

    def test_export_uses_local_files_and_retains_license_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);_,manifest,database,_=self.setup_data(root)
            with patch('urllib.request.urlopen',side_effect=AssertionError('Network forbidden')):
                export(database,manifest,root/'output',root=root)
                result=export(database,manifest,root/'output',root=root)
            self.assertEqual(result['plant_count'],1);self.assertEqual(result['media_count'],1)
            data=json.loads((root/'output/plants.json').read_text())
            self.assertEqual(data['plants'][0]['media'][0]['license'],'CC0-1.0')
            self.assertIsNone(data['plants'][0]['care'])
            with closing(sqlite3.connect(database)) as db, db:
                self.assertEqual(db.execute('SELECT count(*) FROM catalogue_media').fetchone()[0],1)

    def test_corrupt_photo_does_not_produce_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);media,manifest,database,_=self.setup_data(root)
            media.write_bytes(b'corrupted')
            with self.assertRaises(ValueError):export(database,manifest,root/'output',root=root)
            self.assertFalse((root/'output').exists())

    def test_unknown_license_does_not_produce_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);_,manifest,database,asset=self.setup_data(root)
            asset['license']='unknown';manifest.write_text(json.dumps({'assets':[asset]}))
            with self.assertRaises(ValueError):export(database,manifest,root/'output',root=root)
            self.assertFalse((root/'output').exists())


if __name__=='__main__':unittest.main()
