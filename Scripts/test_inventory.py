"""Locate preserved tests after separating SDK unit tests from Demo playback."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def source_text(path):
    path = Path(path)
    text = path.read_text()
    if path.suffix != '.swift' or 'Demo/Tests/Playback/' not in path.as_posix():
        return text
    origin = 'SDK/Tests/' + path.name
    cases = json.loads((ROOT / 'Tests/test-migration.json').read_text())['cases']
    units = sorted({r['file'] for r in cases if r['old_file'] == origin and r['target'] == 'FTPlayerTests'})
    return text + '\n' + '\n'.join((ROOT / unit).read_text() for unit in units)

def selectors():
    result = {}
    for target, folder in [('FTPlayerTests', ROOT / 'SDK/FTPlayerTests'),
                           ('FTPlayerPlaybackTests', ROOT / 'Demo/Tests')]:
        for file in folder.rglob('*.swift'):
            if 'UITests' in file.parts:
                continue
            current = None
            for line in file.read_text().splitlines():
                cls = re.match(r'(?:(?:private|final)\s+)*class\s+(\w+)', line)
                if cls:
                    current = cls[1]
                method = re.match(r'\s+(?:@objc\s+)?func\s+(test\w+)\(', line)
                if method and current:
                    result.setdefault((current, method[1]), set()).add(target)
    return result

def route(arguments):
    available = selectors()
    output = []
    for argument in arguments:
        if not argument.startswith(('-only-testing:', '-skip-testing:')):
            output.append(argument)
            continue
        flag, selection = argument.split(':', 1)
        parts = selection.split('/')
        if parts[0] not in {'FTPlayerSmokeTests', 'FTPlayerPlaybackTests'}:
            output.append(argument)
            continue
        if len(parts) == 1:
            targets = {'FTPlayerTests', 'FTPlayerPlaybackTests'}
        elif len(parts) == 2:
            targets = {target for (cls, _), targets in available.items() if cls == parts[1] for target in targets}
        else:
            targets = available.get((parts[1], parts[2]), set())
        if not targets:
            raise SystemExit('Unknown preserved test selector: ' + selection)
        output.extend(flag + ':' + '/'.join([target, *parts[1:]]) for target in sorted(targets))
    result = []
    seen = set()
    for value in output:
        if value.startswith(('-only-testing:', '-skip-testing:')):
            if value in seen:
                continue
            seen.add(value)
        result.append(value)
    return result

if __name__ == '__main__':
    for argument in route(sys.argv[1:]):
        if '\n' in argument:
            raise SystemExit('Unexpected multiline test argument')
        print(argument)
