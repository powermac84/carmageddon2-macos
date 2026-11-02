#!/usr/bin/env python3
"""Negative-path checks use synthetic files, never original game binaries."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = pathlib.Path(os.environ.get('C2_IMPORT_HELPER', ROOT / 'build/Carmageddon II for Apple Silicon.app/Contents/Helpers/c2-data'))
TEMPLATE = ROOT / 'tools/data-loader.js.template'

class ImporterChecks(unittest.TestCase):
    def run_helper(self, *args):
        p = subprocess.run([str(HELPER), *map(str, args), '--loader-template', str(TEMPLATE)], capture_output=True, text=True)
        result = json.loads(p.stdout)
        self.assertFalse(result['success'])
        self.assertNotEqual(p.returncode, 0)
        return result

    def test_missing_arguments_return_json(self):
        self.assertIn('Usage', self.run_helper()['error'])

    def test_missing_manifest_is_not_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.run_helper('validate', '--source', tmp)

    def test_unknown_engine_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'Original'; target = root / 'GameData'
            source.mkdir(); (source / 'DATA').mkdir(); (source / 'CARMA2_HW.EXE').write_bytes(b'MZsynthetic-test')
            target.mkdir(); (target / 'keep.txt').write_text('existing data')
            result = self.run_helper('import', '--source', source, '--destination', target)
            self.assertIn('not a supported', result['error'])
            self.assertEqual((target / 'keep.txt').read_text(), 'existing data')
            self.assertFalse((root / '.c2-import-lock').exists())
            self.assertEqual(list(root.glob('.c2-import-*')), [])

    def test_overlapping_paths_are_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = pathlib.Path(tmp) / 'Original'; source.mkdir()
            result = self.run_helper('import', '--source', source, '--destination', source / 'DATA/GameData')
            self.assertIn('must be separate', result['error'])
            self.assertFalse((source / 'DATA').exists())

    def test_resolved_alias_overlap_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'Original'; source.mkdir()
            alias = root / 'Alias'; alias.symlink_to(source, target_is_directory=True)
            result = self.run_helper('import', '--source', source, '--destination', alias / 'GameData')
            self.assertIn('must be separate', result['error'])

    def test_legacy_traversal_and_selected_javascript_are_never_executed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / 'Wrapper'; source.mkdir()
            marker = root / 'must-not-exist'
            metadata = {'files': [{'filename': '/carma2/../../outside', 'start': 0, 'end': 4}], 'remote_package_size': 4}
            (source / 'carma2web.data.000').write_bytes(b'test')
            (source / 'carma2data.js').write_text('throw new Error("selected JS must not execute");\nloadPackage(' + json.dumps(metadata) + ');\nrequire("fs").writeFileSync(' + json.dumps(str(marker)) + ',"bad");')
            self.run_helper('import', '--source', source, '--destination', root / 'GameData')
            self.assertFalse(marker.exists())
            self.assertFalse((root / 'GameData').exists())

if __name__ == '__main__':
    unittest.main()
