#!/usr/bin/env python3
"""Export measured rate/seek evidence from XCTest playback JSON attachments."""
import csv, json, sys
from pathlib import Path
root=Path(sys.argv[1]);rows=[]
for directory in sorted(root.glob('*-attachments')):
 manifest=directory/'manifest.json'
 if not manifest.exists():continue
 for entry in json.loads(manifest.read_text()):
  for attachment in entry.get('attachments',[]):
   file=directory/attachment['exportedFileName']
   if file.suffix!='.json':continue
   try:data=json.loads(file.read_text())
   except (ValueError,OSError):continue
   if not isinstance(data,dict):continue
   for measure in data.get('measurements',[]):
    row=dict(phase=directory.name.removesuffix('-attachments'),test=entry['testIdentifier'],decodePolicy=data.get('decodePolicy',''),url=data.get('url',''),ffmpegFrames=data.get('ffmpegFrames',0),hardwareFrames=data.get('hardwareFrames',0),videoToolboxSoftwareFrames=data.get('videoToolboxSoftwareFrames',0),videoToolboxUnverifiedFrames=data.get('videoToolboxUnverifiedFrames',0))
    row.update(measure); rows.append(row)
fields=['phase','test','decodePolicy','url','operation','requestedRate','rate','target','seekTarget','elapsed','mediaDelta','observedRate','firstObservedVideoPTS','ptsError','buffering','bufferingDuringMeasurement','frames','ffmpegFrames','hardwareFrames','videoToolboxSoftwareFrames','videoToolboxUnverifiedFrames','rateChangedAfterRequest','videoPTS','lastVideoPTS','masterClock','callbacks']
with (root/'measurements.csv').open('w') as file:
 writer=csv.DictWriter(file,fieldnames=fields,extrasaction='ignore');writer.writeheader();writer.writerows(rows)
(root/'measurements.json').write_text(json.dumps(rows,indent=2))
print(f'Exported {len(rows)} timing/seek measurements')
