"""Reject green-but-empty or skipped SDK unit / Demo UI test runs."""
import csv
from pathlib import Path
import re
import sys
from test_inventory import ROOT, selectors

mode = sys.argv[1]
rows = list(csv.DictReader(Path(sys.argv[2]).open()))
if mode == 'unit':
    expected = {case for case, targets in selectors().items() if 'FTPlayerTests' in targets}
elif mode == 'ui':
    expected = {('FTPlayerDemoUITests', name) for file in (ROOT / 'Demo/Tests/UITests').glob('*.swift')
                for name in re.findall(r'\bfunc\s+(test\w+)\(', file.read_text())}
else:
    raise SystemExit('Unknown test execution mode')
actual = {(row['suite'], row['test'].removesuffix('()')) for row in rows}
if not expected or actual != expected or any(row['result'] != 'Passed' for row in rows):
    raise SystemExit('Requested ' + mode + ' cases were missing, skipped or failed')
print('Verified ' + str(len(expected)) + ' ' + mode + ' cases executed and passed; no missing/skip counted as PASS')
