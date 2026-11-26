"""Guard the SDK logic / Demo real-media boundary and preserve existing cases."""
import json
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
from test_inventory import selectors
import unittest

ROOT = Path(__file__).resolve().parents[1]

class TestArchitecture(unittest.TestCase):
    def test_every_original_case_has_an_executable_owner(self):
        inventory = json.loads((ROOT / 'Tests/test-migration.json').read_text())
        cases = inventory['cases']
        identities = [(row['old_file'], row['class'], row['name']) for row in cases]
        self.assertEqual(len(identities), len(set(identities)))
        self.assertEqual(len(cases), 806)
        owners = selectors()
        for case in cases + inventory.get('added_cases', []):
            self.assertEqual(owners.get((case['class'], case['name'])), {case['target']}, 'Missing or duplicated case: ' + case['name'])
            source = (ROOT / case['file']).read_text()
            self.assertRegex(source, r'\bfunc\s+' + re.escape(case['name']) + r'\s*\(')
            self.assertTrue(case['file'].startswith('SDK/FTPlayerTests/' if case['target'] == 'FTPlayerTests' else 'Demo/Tests/Playback/'))

    def test_sdk_units_never_open_media_or_use_demo_helpers(self):
        units = list((ROOT / 'SDK/FTPlayerTests').rglob('*.swift'))
        self.assertTrue(units)
        forbidden = r'\b(?:PlaybackSession|PlaybackTestCase|FixtureHTTPServer|RemoteFixtureStore|FTFormatContext|avformat_open_input)\b|\b(?:fixture|http|assertPlayback)\s*\(|\bURLSession\s*\.\s*(?:shared|dataTask|downloadTask)|\b(?:NWListener|NWConnection|FTAudioManager)\s*\(|\.\s*(?:open|setupSync|setupAsync)\s*\('
        for file in units:
            self.assertIsNone(re.search(forbidden, file.read_text()), str(file))
            self.assertIsNone(re.search(r'FTIndependentHLS\s*\([^)]*cache:\s*true', file.read_text()), str(file) + ': HLS cache constructor starts a TCP proxy')
        decoder_owners = [p for p in units if re.search(r'FTDecoder\s*\(contentURL:', p.read_text())]
        self.assertEqual(decoder_owners, [ROOT / 'SDK/FTPlayerTests/Playback/FTPlayerControlTests.swift'])
        self.assertFalse((ROOT / 'SDK/Tests').exists())

    def test_sdk_unit_target_has_no_app_host(self):
        project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'SDK/FTPlayer.xcodeproj/project.pbxproj')]))
        objects = project['objects']
        target = next(obj for obj in objects.values() if obj.get('isa') == 'PBXNativeTarget' and obj['name'] == 'FTPlayerTests')
        self.assertEqual(target['productType'], 'com.apple.product-type.bundle.unit-test')
        for config in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[config]['buildSettings']
            self.assertEqual(settings.get('TEST_HOST', ''), '')
            self.assertEqual(settings.get('BUNDLE_LOADER', ''), '')
        self.assertNotIn('FTPlayerDemo', (ROOT / 'SDK/project.yml').read_text())

    def test_demo_has_real_xcui_tests_and_no_bundled_video_source(self):
        project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Demo/FTPlayerDemo.xcodeproj/project.pbxproj')]))
        targets = [obj for obj in project['objects'].values() if obj.get('isa') == 'PBXNativeTarget']
        ui = next(obj for obj in targets if obj['name'] == 'FTPlayerDemoUITests')
        self.assertEqual(ui['productType'], 'com.apple.product-type.bundle.ui-testing')
        spec = (ROOT / 'Demo/project.yml').read_text()
        self.assertNotIn('path: Fixtures', spec)
        self.assertNotIn('../SDK/Tests', spec)
        source = (ROOT / 'Demo/Tests/UITests/FTPlayerDemoUITests.swift').read_text()
        self.assertIn('XCUIApplication()', source)
        self.assertIn('--play-url=', source)

if __name__ == '__main__':
    unittest.main()
