#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/SDK/build/FTPlayer.xcframework}"
if [[ -e "$OUTPUT" ]]; then
  echo "Output already exists: $OUTPUT. Choose a new output path or remove the old build."
  exit 1
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/FTPlayer-archive.XXXXXX")"
STAGED_PACKAGE="$WORK/FTPlayer.xcframework"
mkdir -p "$(dirname "$OUTPUT")"
xcodebuild archive -project "$ROOT/SDK/FTPlayer.xcodeproj" -scheme FTPlayer \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$WORK/device.xcarchive" -derivedDataPath "$WORK/device-data" \
  SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf FTPLAYER_CREATE_XCFRAMEWORK=NO
xcodebuild archive -project "$ROOT/SDK/FTPlayer.xcodeproj" -scheme FTPlayer \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -archivePath "$WORK/simulator.xcarchive" -derivedDataPath "$WORK/simulator-data" \
  SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf FTPLAYER_CREATE_XCFRAMEWORK=NO
xcodebuild -create-xcframework \
  -framework "$WORK/device.xcarchive/Products/Library/Frameworks/FTPlayer.framework" \
  -framework "$WORK/simulator.xcarchive/Products/Library/Frameworks/FTPlayer.framework" \
  -output "$STAGED_PACKAGE"
python3 "$ROOT/Scripts/check-sdk-import.py" "$STAGED_PACKAGE" --work-dir "$WORK/consumer-check"
mv "$STAGED_PACKAGE" "$OUTPUT"
echo "Built SDK: $OUTPUT"
echo "Archive files: $WORK"
