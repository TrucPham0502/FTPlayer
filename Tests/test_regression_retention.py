"""Guard regression case retention separately from playback test execution."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = json.loads((ROOT / 'Tests/RegressionArchive/registry.json').read_text())

class RegressionRetentionTests(unittest.TestCase):
    def test_all_sdk_and_player_case_names_are_retained(self):
        missing = []
        for key in ['sdk_baseline', 'demo_player_baseline', 'restored_source_cases']:
            for item in REGISTRY[key]:
                path = ROOT / item['file']
                source = path.read_text() if path.exists() else ''
                if not re.search(r'\bfunc\s+' + re.escape(item['name']) + r'\s*\(', source):
                    missing.append(item['file'] + '::' + item['name'])
        self.assertEqual(missing, [], 'Regression cases were deleted instead of migrated')

    def test_payload_contracts_remain_executable(self):
        for item in REGISTRY['restored_payload_cases']:
            path = ROOT / item['file']
            self.assertTrue(path.exists(), 'Missing offline payload regression suite')
            self.assertIn(item['name'], path.read_text())

    def test_demo_does_not_reintroduce_business_api_or_resolver(self):
        for path in (ROOT / 'Demo/Sources').rglob('*.swift'):
            self.assertIsNone(re.search(r'URLSession|URLRequest|WKWebView|CamPlaybackClient|CamPlaybackViewController', path.read_text()), str(path))

if __name__ == '__main__':
    unittest.main()
