#!/bin/bash
# Run the SDK unit tests (scheme FTPlayerUnit). Extra arguments go to xcodebuild,
# e.g. ./Scripts/test.sh -only-testing:FTPlayerTests/FTPlayerHLSPlaybackTests
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${FTPLAYER_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4}"
# Keep headless XCTest products outside Desktop; its loader may not read them there.
DERIVED_DATA="${FTPLAYER_DERIVED_DATA:-${TMPDIR:-/private/tmp}/FTPlayerDerivedData}"
mkdir -p "$ROOT/build/TestResults"
OUT="$(mktemp -d "$ROOT/build/TestResults/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ "$DESTINATION" == platform=iOS,* ]]; then
  : "${FTPLAYER_DEVELOPMENT_TEAM:?Set FTPLAYER_DEVELOPMENT_TEAM for signed iPhone testing}"
  SIGNING_ARGS=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$FTPLAYER_DEVELOPMENT_TEAM")
fi
echo "Results: $OUT"
# The stat cache can stall on this SDK/toolchain combination; it only affects build acceleration.
xcodebuild test -project "$ROOT/SDK/FTPlayer.xcodeproj" -scheme FTPlayerUnit -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$OUT/unit.xcresult" \
  -parallel-testing-enabled NO "${SIGNING_ARGS[@]}" SDK_STAT_CACHE_ENABLE=NO FTPLAYER_CREATE_XCFRAMEWORK=NO \
  "$@" 2>&1 | tee "$OUT/unit.log"
