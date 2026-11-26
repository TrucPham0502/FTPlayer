"""Require executed cases and real near-target output, not a green empty suite."""
import csv
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
summary = Path(sys.argv[1])
attachments = Path(sys.argv[2])
registry = json.loads((root / 'Tests/RegressionArchive/registry.json').read_text())
expected = {('FTPlayerCapturedMediaRegressionTests', item['name']) for item in registry['restored_source_cases']}
expected.update({('FTPlayerDemoTests', name) for name in [
    'testResolvedRecordingURLPlaysHLSWithoutMetadataAPI',
    'testBackFromResolvedRecordingReleasesPlayerAndKeepsRoot',
]})
expected.update({('FTPlayerHLSTests', name) for name in [
    'testPartialAudioPacketPressureDoesNotOscillateBuffering',
    'testSeekPartialAudioPacketPressureDoesNotOscillateBuffering',
    'testEmptyAudioTrackHLSStartsCached', 'testEmptyAudioTrackHLSStartsWithoutCache',
    'testEmptyAudioTrackFileFinishesAtVideoTail', 'testEmptyAudioPeriodKeepsLaterAudioAndFinishes',
]})
rows = list(csv.DictReader(summary.open()))
actual = {(row['suite'], row['test'].removesuffix('()')) for row in rows}
if actual != expected or any(row['result'] != 'Passed' for row in rows):
    raise SystemExit('Restored regression cases were missing, skipped or failed')
measurements = []
for path in attachments.rglob('*.json'):
    try:
        report = json.loads(path.read_text())
    except (ValueError, UnicodeError):
        continue
    if isinstance(report, dict):
        measurements.extend(item for item in report.get('measurements', []) if item.get('operation') == 'captured-source-seek')
if len(measurements) != 12:
    raise SystemExit('Expected three actual seeks per captured playback case')
for item in measurements:
    if not (item['completed'] and item['duration'] > 1000 and item['nearTargetFrames'] >= 10 and
            abs(item['clock'] - item['target']) <= 4):
        raise SystemExit('A captured-source seek did not meet the original output/timeline assertions')
print('Verified 17 executed tests, 12 completed seeks and real near-target frames; no skips counted as PASS')
