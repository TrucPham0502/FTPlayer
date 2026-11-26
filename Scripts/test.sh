#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-unit}"
export PYTHONPATH="$ROOT/Scripts${PYTHONPATH:+:$PYTHONPATH}"
DESTINATION="${FTPLAYER_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4}"
# Keep headless XCTest products outside Desktop; its loader may not read them there.
DERIVED_DATA="${FTPLAYER_DERIVED_DATA:-${TMPDIR:-/private/tmp}/FTPlayerDerivedData}"
mkdir -p "$ROOT/build/TestResults"
OUT="$(mktemp -d "$ROOT/build/TestResults/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
# The stat cache can stall on this SDK/toolchain combination. This changes build
# acceleration only, not runtime settings or which tests execute.
BUILD_ARGS=(SDK_STAT_CACHE_ENABLE=NO)
if [[ "$DESTINATION" == platform=macOS,* ]]; then
  # Xcode's debug-dylib trampoline can hang in dyld for Designed for iPad hosts.
  # Link the normal app executable for Mac tests; strict hardware remains enabled.
  BUILD_ARGS+=(ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO)
fi
if [[ "$DESTINATION" == platform=iOS,* || "$DESTINATION" == platform=macOS,* ]]; then
  : "${FTPLAYER_DEVELOPMENT_TEAM:?Set FTPLAYER_DEVELOPMENT_TEAM for signed iPhone or Mac testing}"
  SIGNING_ARGS=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$FTPLAYER_DEVELOPMENT_TEAM")
fi
mkdir -p "$OUT"
echo "Results: $OUT"
run_suite() {
  local scheme="$1" name="$2"
  if [[ "$scheme" == FTPlayerDemo ]]; then scheme=FTPlayerRegression; fi
  shift 2
  echo "Running $name ($scheme)..."
  local command=(xcodebuild -workspace "$ROOT/FTPlayer.xcworkspace" -scheme "$scheme" -configuration Debug
    -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA"
    "${SIGNING_ARGS[@]}" "${BUILD_ARGS[@]}")
  local media_manifest=""
  if [[ -n "${FTPLAYER_TEST_MEDIA_MANIFEST:-}" ]]; then
    # Simulator test processes cannot necessarily read input files on Desktop.
    # Pass a private temporary copy, not the user's original configuration file.
    media_manifest="$(mktemp "${TMPDIR:-/private/tmp}/FTPlayerTestMedia.XXXXXX")"
    if ! cp "$FTPLAYER_TEST_MEDIA_MANIFEST" "$media_manifest"; then
      rm -f -- "$media_manifest"
      return 1
    fi
    chmod 600 "$media_manifest"
    command+=("FTPLAYER_TEST_MEDIA_MANIFEST=$media_manifest")
  fi
  if [[ "${FTPLAYER_TEST_BACKEND:-all}" == hardware || "${FTPLAYER_TEST_BACKEND:-all}" == ffmpeg ]]; then
    local test_class
    case "$scheme" in
      FTPlayerDecodeBackends) test_class=FTPlayerDecodeBackendTests ;;
      FTPlayerDecodeBackendsInternet) test_class=FTPlayerDecodeBackendInternetTests ;;
      *) echo "FTPLAYER_TEST_BACKEND filtering requires backends, backends-internet or backends-all"; return 2 ;;
    esac
    while IFS= read -r test_method; do
      command+=("-only-testing:FTPlayerPlaybackTests/$test_class/$test_method")
    done < <(python3 - "$ROOT/Demo/Tests/Playback/$test_class.swift" "$FTPLAYER_TEST_BACKEND" <<'PYFILTER'
from test_inventory import source_text
from pathlib import Path
import re,sys
prefix = "testHardware" if sys.argv[2] == "hardware" else "testFfmpeg"
for method in re.findall(r'func (' + prefix + r'\w+)\(', source_text(Path(sys.argv[1]))): print(method)
PYFILTER
)
  fi
  local routed
  if ! routed="$(python3 "$ROOT/Scripts/test_inventory.py" "$@")"; then
    if [[ -n "$media_manifest" ]]; then rm -f -- "$media_manifest"; fi
    return 1
  fi
  while IFS= read -r argument; do
    if [[ -n "$argument" ]]; then command+=("$argument"); fi
  done <<< "$routed"
  set +e
  if [[ "$name" == audio-session* || "$name" == high-rate* || "$name" == ready-seek* || "$name" == weak-network-rate ]]; then
    # Discover selectors from the newly built test bundle. Xcode can otherwise
    # expand class filters using the previous bundle and omit newly added tests.
    "${command[@]}" build-for-testing > "$OUT/$name-build.log" 2>&1
    local build_result=$?
    if [[ $build_result -ne 0 ]]; then
      if [[ -n "$media_manifest" ]]; then rm -f -- "$media_manifest"; fi
      set -e; return "$build_result"
    fi
    "${command[@]}" -resultBundlePath "$OUT/$name.xcresult" test-without-building > "$OUT/$name.log" 2>&1
  else
    "${command[@]}" -resultBundlePath "$OUT/$name.xcresult" test > "$OUT/$name.log" 2>&1
  fi
  local result=$?
  if [[ -n "$media_manifest" ]]; then rm -f -- "$media_manifest"; fi
  set -e
  xcrun xcresulttool get test-results tests --path "$OUT/$name.xcresult" --format json > "$OUT/$name.json"
  xcrun xcresulttool export attachments --path "$OUT/$name.xcresult" --output-path "$OUT/$name-attachments" > "$OUT/$name-attachments.log"
  python3 "$ROOT/Scripts/summarize-tests.py" "$OUT/$name.json" "$OUT/$name-summary"
  cat "$OUT/$name-summary.md"
  return "$result"
}
status=0
case "$MODE" in
  regression-retention)
    python3 -m unittest discover -s "$ROOT/Tests" -p test_regression_retention.py || status=$?
    node --test "$ROOT/Tests/CapturedMediaPayloadTests.cjs" || status=$?
    run_suite FTPlayerDemo regression-retention -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO \
      -only-testing:FTPlayerPlaybackTests/FTPlayerCapturedMediaRegressionTests \
      -only-testing:FTPlayerPlaybackTests/FTPlayerDemoTests/testResolvedRecordingURLPlaysHLSWithoutMetadataAPI \
      -only-testing:FTPlayerPlaybackTests/FTPlayerDemoTests/testBackFromResolvedRecordingReleasesPlayerAndKeepsRoot \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testPartialAudioPacketPressureDoesNotOscillateBuffering \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testSeekPartialAudioPacketPressureDoesNotOscillateBuffering \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testEmptyAudioTrackHLSStartsCached \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testEmptyAudioTrackHLSStartsWithoutCache \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testEmptyAudioTrackFileFinishesAtVideoTail \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests/testEmptyAudioPeriodKeepsLaterAudioAndFinishes || status=$?
    python3 "$ROOT/Scripts/verify-regression-retention.py" "$OUT/regression-retention-summary.csv" "$OUT/regression-retention-attachments" || status=$?
    ;;
  ready-seek|ready-seek-online|weak-network-rate)
    case "$MODE" in
      ready-seek) review_class=FTPlayerReadySeekTests; review_prefix=testReadySeek; review_scheme=FTPlayerDemo ;;
      ready-seek-online) review_class=FTPlayerInternetTests; review_prefix=testReadySeekOnline; review_scheme=FTPlayerInternet ;;
      weak-network-rate) review_class=FTPlayerWeakNetworkRateTests; review_prefix=testWeakNetwork; review_scheme=FTPlayerDemo ;;
    esac
    review_source="$ROOT/Demo/Tests/Playback/FTPlayerControlTests.swift"
    if [[ "$MODE" == ready-seek-online ]]; then review_source="$ROOT/Demo/Tests/Playback/FTPlayerInternetTests.swift"; fi
    review_methods="$(python3 - "$review_source" "$review_class" "$review_prefix" <<'PYREVIEWFILTER'
from test_inventory import source_text
from pathlib import Path
import re,sys
source=source_text(Path(sys.argv[1])).split('final class '+sys.argv[2]+':',1)[1]
source=re.split(r'^final class |^extension PlaybackTestCase',source,maxsplit=1,flags=re.M)[0]
methods=re.findall(r'func ('+sys.argv[3]+r'\w+)\(',source)
expected=9 if sys.argv[2]=='FTPlayerWeakNetworkRateTests' else 8
if len(methods)!=expected:sys.exit('Unexpected SDK review test count')
print('\n'.join(methods))
PYREVIEWFILTER
)"
    review_filters=()
    while IFS= read -r method; do review_filters+=("-only-testing:FTPlayerPlaybackTests/$review_class/$method"); done <<< "$review_methods"
    run_suite "$review_scheme" "$MODE" -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO "${review_filters[@]}" || status=$?
    python3 - "$OUT/$MODE-summary.csv" "$review_class" "$review_methods" <<'PYREVIEWVERIFY' || status=$?
import csv,sys
from pathlib import Path
rows=list(csv.DictReader(Path(sys.argv[1]).open()))
actual={r['test'].removesuffix('()') for r in rows if r['suite']==sys.argv[2]}
if actual!=set(sys.argv[3].splitlines()) or any(r['result']!='Passed' for r in rows):
 sys.exit('Requested SDK review tests were missing, skipped or failed')
print('Verified all '+str(len(actual))+' SDK review tests executed and passed')
PYREVIEWVERIFY
    ;;
  high-rate-load)
    run_suite FTPlayerDemo high-rate-load -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateFullQueueRefillsBeforeWallBufferRunsOut \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateSamplingKeepsDisplayCadence \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateNotificationsAreBounded \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateLoadH264 \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateLoadHEVC || status=$?
    python3 - "$ROOT/Demo/Tests/Playback/FTPlayerControlTests.swift" "$OUT/high-rate-load-summary.csv" <<'PYHIGHRATE' || status=$?
from test_inventory import source_text
import csv,re,sys
from pathlib import Path
expected=set(re.findall(r'func (testHighRate\w+)\(',source_text(Path(sys.argv[1])).split('final class FTPlayerHighRateLoadTests:',1)[1]))-{'testHighRateLoadCamera'}
rows=list(csv.DictReader(Path(sys.argv[2]).open()))
actual={row['test'].removesuffix('()') for row in rows if row['suite']=='FTPlayerHighRateLoadTests'}
if actual!=expected or any(row['result']!='Passed' for row in rows):
 sys.exit('High-rate load tests were missing, skipped or failed')
print('Verified all '+str(len(expected))+' high-rate load methods executed and passed')
PYHIGHRATE
    ;;
  high-rate-camera)
    run_suite FTPlayerDemo high-rate-camera -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHighRateLoadTests/testHighRateLoadCamera || status=$?
    python3 - "$OUT/high-rate-camera-summary.csv" <<'PYHIGHRATECAMERA' || status=$?
import csv,sys
from pathlib import Path
rows=list(csv.DictReader(Path(sys.argv[1]).open()))
if len(rows)!=1 or rows[0]['test'].removesuffix('()')!='testHighRateLoadCamera' or rows[0]['result']!='Passed':
 sys.exit('Camera load test was missing, skipped or failed; install its opt-in input')
PYHIGHRATECAMERA
    ;;
  rate-transition)
    rate_transition_filters=()
    rate_transition_methods="$(python3 - "$ROOT" <<'PYRATETRANSITION'
from test_inventory import source_text
from pathlib import Path
import re,sys
source=source_text(Path(sys.argv[1])/'Demo/Tests/Playback/FTPlayerControlTests.swift')
methods=re.findall(r'func (testRateDropTransition\w+)\(',source)
if len(methods)!=8: sys.exit('Expected 8 immediate rate-transition cases')
print('\n'.join(methods))
PYRATETRANSITION
)"
    while IFS= read -r method; do rate_transition_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/$method"); done <<< "$rate_transition_methods"
    run_suite FTPlayerInternet rate-transition "${rate_transition_filters[@]}" || status=$?
    ;;
  rate-reset)
    rate_reset_filters=()
    rate_reset_methods="$(python3 - "$ROOT" <<'PYRATERESET'
from test_inventory import source_text
from pathlib import Path
import re,sys
source=source_text(Path(sys.argv[1])/'Demo/Tests/Playback/FTPlayerControlTests.swift')
methods=re.findall(r'func (testRateResetAfterSeekBurst\w+)\(',source)
if len(methods)!=8: sys.exit('Expected 8 rate-reset source/cache cases')
print('\n'.join(methods))
PYRATERESET
)"
    while IFS= read -r method; do rate_reset_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/$method"); done <<< "$rate_reset_methods"
    run_suite FTPlayerInternet rate-reset "${rate_reset_filters[@]}" || status=$?
    ;;
  catalog-controls)
    control_filters=()
    control_methods="$(python3 - "$ROOT" <<'PYCONTROLS'
from test_inventory import source_text
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
catalog=json.loads(source_text(root/'Demo/Sources/SampleStreams.json'))
if catalog != json.loads(source_text(root/'Demo/Tests/Playback/Resources/SampleStreams.json')):
    sys.exit('Demo and SDK test catalogs differ')
ids=[v['id'] for v in catalog]
if len(ids)!=len(set(ids)): sys.exit('Duplicate catalog IDs')
source=source_text(root/'Demo/Tests/Playback/FTPlayerInternetTests.swift')
for row in catalog:
    methods = ['testMalformed'+mode+'_'+row['malformedTest'] for mode in ['Default','Cached']] if row.get('malformedTest') else ['testCatalogControls_'+row['id'].replace('-','_')]
    for method in methods:
        if f'func {method}(' not in source: sys.exit('Missing seek/16x/cache test: '+row['id'])
        print(method)
for method in ['testOceansDistantCachedSeekRetainsPrerollKeyframe', 'testCatalogFLVDeclaredDurationExceedsPacketExtent']:
    if f'func {method}(' not in source: sys.exit('Missing control diagnostic: '+method)
    print(method)
PYCONTROLS
)"
    while IFS= read -r method; do control_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/$method"); done <<< "$control_methods"
    run_suite FTPlayerInternet catalog-controls "${control_filters[@]}" || status=$?
    ;;
  malformed-media)
    malformed_filters=()
    malformed_methods="$(python3 - "$ROOT" <<'PYMALFORMED'
from test_inventory import source_text
from pathlib import Path
import re,sys
source=source_text(Path(sys.argv[1])/'Demo/Tests/Playback/FTPlayerInternetTests.swift')
methods=re.findall(r'func (testMalformed(?:Default|Cached)_\w+)\(',source)
if len(methods)!=20: sys.exit('Expected 10 malformed-media sources in both cache modes')
print('\n'.join(methods))
PYMALFORMED
)"
    while IFS= read -r method; do
      malformed_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/$method")
    done <<< "$malformed_methods"
    run_suite FTPlayerInternet malformed-media "${malformed_filters[@]}" || status=$?
    ;;
  mux-16x)
    run_suite FTPlayerInternet mux-16x \
      -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testHlsMuxMasterCachedSustained16x \
      -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testHlsMuxMasterFFmpegCachedSustained16x \
      -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testHlsMuxMasterHardwareCachedSustained16x || status=$?
    ;;
  catalog-cache|catalog-extra|catalog-more|catalog-round3|catalog-stress)
    catalog_filters=()
    catalog_methods="$(python3 - "$ROOT" "$MODE" <<'PYCATALOG'
from test_inventory import source_text
from pathlib import Path
import json, sys
root = Path(sys.argv[1])
catalog = json.loads(source_text(root / "Demo/Sources/SampleStreams.json"))
if catalog != json.loads(source_text(root / "Demo/Tests/Playback/Resources/SampleStreams.json")):
    sys.exit("Demo and SDK test catalogs differ")
coverage = {
    "mp4-h264": "testMp4H264", "mp4-hevc": "testMp4Hevc",
    "mp4-h264-w3c": "testMp4H264W3C", "mp4-hevc-photoprism-tsu": "testHevcPhotoprismTSU",
    "webm-vp9": "testWebmVp9", "flv-public": "testFlvPublic",
    "hls-master": "testHlsMaster", "hls-media": "testHlsMedia",
    "hls-apple-ts": "testHlsAppleTs", "hls-apple-fmp4": "testHlsAppleFmp4",
    "hls-hevc": "testHlsHevc", "dash-h264": "testDASHCapabilityAndGracefulFailure",
}
extra = {
    "mp4-hevc-jellyfish-1080": "testHevcJellyfish1080",
    "mp4-hevc-photoprism-1080": "testHevcPhotoprism1080",
    "mp4-hevc-photoprism-4k": "testHevcPhotoprism4K",
    "hls-hevc-720p60": "testHlsHevc720p60", "hls-hevc-1080p60": "testHlsHevc1080p60",
    "webm-vp8": "testWebmVp8", "mkv-h264": "testMkvH264", "hls-mux-pts-shift": "testHlsMuxPTSShift",
}
coverage.update(extra)
more = {
    "hls-hevc-ts-public": "testHlsPublicHevcTS", "hls-apple-hdr10plus": "testHlsAppleHDR10Plus",
    "mp4-hevc-camera": "testHevcCameraMP4", "mov-pcm-s16be": "testMovPCM16BigEndian",
    "hls-oceans-aes128": "testHlsOceansAES128", "hls-mux-sample-aes": "testHlsMuxSampleAES",
    "hls-aes128-audio": "testHlsAES128SeparateAudio", "hls-shaka-angel-one": "testHlsShakaAngelOne",
    "hls-unified-tos": "testHlsUnifiedTearsOfSteel", "hls-jw-muxed-fmp4": "testHlsJWMuxedFMP4",
}
coverage.update(more)
round3 = {
    "hls-fdr": "testPublicRound3FDR", "hls-surveillance": "testPublicRound3Surveillance",
    "hls-mp3-vod": "testPublicRound3MP3VOD", "hls-captions": "testPublicRound3Captions",
    "hls-elephants-audio": "testPublicRound3ElephantsAudio", "hls-wistia-pes": "testPublicRound3WistiaPES",
    "hls-hevc-4k": "testPublicRound3HEVC4K", "mov-camera": "testPublicRound3MOVCamera",
    "webm-vp9-earth": "testPublicRound3VP9Earth", "avi-mpeg4-mp3": "testPublicRound3AVIMPEG4",
}
coverage.update(round3)
stress = {
    "hls-dai-discontinuity": "testStressDAIDiscontinuity", "hls-custom-iv": "testStressCustomIV",
    "hls-pdt-large-gaps": "testStressPDTLargeGaps", "hls-av-start-gap": "testStressAVStartGap",
    "hls-audio-pdt-gap": "testStressAudioPDTGap",
}
coverage.update(stress)
coverage.update({row['id']: 'testMalformedCached_'+row['malformedTest'] for row in catalog if row.get('malformedTest')})
ids = [item["id"] for item in catalog]
if len(ids) != len(set(ids)) or set(ids) != set(coverage):
    sys.exit(f"Update catalog cache regression coverage: missing={set(ids)-set(coverage)}, stale={set(coverage)-set(ids)}")
methods = list(coverage.values()) + ["testHLSMasterCachedPacketSeekKeepsAudioVideoOrigins", "testHLSTSMasterCachedPacketSeekKeepsAudioVideoOrigins"]
if sys.argv[2] == "catalog-extra": methods = list(extra.values())
if sys.argv[2] == "catalog-more": methods = list(more.values())
if sys.argv[2] == "catalog-round3":
    methods = list(round3.values()) + ['testCatalogControls_' + id.replace('-', '_') for id in round3]
if sys.argv[2] == "catalog-stress":
    methods = list(stress.values()) + ['testCatalogControls_' + id.replace('-', '_') for id in stress]
source = source_text(root / "Demo/Tests/Playback/FTPlayerInternetTests.swift")
for method in methods:
    if f"func {method}(" not in source:
        sys.exit(f"Missing catalog cache test: {method}")
print("\n".join(methods))
PYCATALOG
)"
    while IFS= read -r method; do
      catalog_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/$method")
    done <<< "$catalog_methods"
    run_suite FTPlayerInternet "$MODE" "${catalog_filters[@]}" || status=$?
    ;;
  load-review)
    run_suite FTPlayerDemo load-review \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHTTPTests \
      -only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/testStartupLogNativeCallbackHonorsVerboseLevel \
      -only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/testStartupLogKeepsNativeErrorForCorruptMP4 \
      -only-testing:FTPlayerPlaybackTests/FTPlayerDemoTests/testHLSCacheLabelIncreasesWhenHEADIsForbidden || status=$?
    ;;
  hls-review)
    hls_review_filters=()
    while IFS= read -r method; do hls_review_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/$method"); done < <(python3 - "$ROOT/Demo/Tests/Playback/FTPlayerInternetTests.swift" <<'PYHLSREVIEW'
from test_inventory import source_text
from pathlib import Path
import re,sys
for method in re.findall(r'func ((?:testHLSReview|testLoadControlHLS)\w+)\(',source_text(Path(sys.argv[1]))):print(method)
PYHLSREVIEW
)
    run_suite FTPlayerInternet hls-review "${hls_review_filters[@]}" || status=$?
    ;;
  load-control)
    load_control_filters=()
    while IFS= read -r method; do load_control_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerHTTPTests/$method"); done < <(python3 - "$ROOT/Demo/Tests/Playback/FTPlayerHTTPTests.swift" <<'PYLOADCONTROL'
from test_inventory import source_text
from pathlib import Path
import re,sys
for method in re.findall(r'func (testLoadControl\w+)\(',source_text(Path(sys.argv[1]))):print(method)
PYLOADCONTROL
)
    run_suite FTPlayerDemo load-control "${load_control_filters[@]}" \
      -only-testing:FTPlayerPlaybackTests/FTPlayerHLSTests \
      -only-testing:FTPlayerPlaybackTests/FTPlayerDemoTests/testHLSCacheLabelIncreasesWhenHEADIsForbidden || status=$?
    ;;
  preparation)
    preparation_filters=()
    while IFS= read -r entry; do preparation_filters+=("-only-testing:FTPlayerPlaybackTests/$entry"); done < <(python3 - "$ROOT" <<'PYPREPARATION'
from test_inventory import source_text
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
for suite,path in [('FTPlayerControlTests','Demo/Tests/Playback/FTPlayerControlTests.swift'),('FTPlayerDemoTests','Demo/Tests/FTPlayerDemoTests.swift')]:
 for name in re.findall(r'func (testPreparation\w+)\(', source_text(root/path)):print(suite+'/'+name)
PYPREPARATION
)
    run_suite FTPlayerDemo preparation "${preparation_filters[@]}" || status=$?
    ;;
  spam-seek)
    spam_filters=()
    while IFS= read -r entry; do spam_filters+=("-only-testing:FTPlayerPlaybackTests/$entry"); done < <(python3 - "$ROOT" <<'PYSPAM'
from test_inventory import source_text
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
for suite,path in [('FTPlayerControlTests','Demo/Tests/Playback/FTPlayerControlTests.swift'),('FTPlayerDemoTests','Demo/Tests/FTPlayerDemoTests.swift')]:
 for name in re.findall(r'func (testSpamSeek\w+)\(', source_text(root/path)): print(suite+'/'+name)
PYSPAM
)
    run_suite FTPlayerDemo spam-seek "${spam_filters[@]}" || status=$?
    ;;
  daily-startup)
    run_suite FTPlayerInternet daily-startup \
      -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testRecordingDailyStartupBenchmarkFromManifest \
      -maximum-test-execution-time-allowance 5400 || status=$?
    ;;
  startup-log)
    run_suite FTPlayerDemo startup-log \
      -only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/testStartupLogNativeCallbackHonorsVerboseLevel \
      -only-testing:FTPlayerPlaybackTests/FTPlayerControlTests/testStartupLogKeepsNativeErrorForCorruptMP4 || status=$?
    ;;
  audio) run_suite FTPlayerDemo audio -only-testing:FTPlayerPlaybackTests/FTPlayerMuteTests || status=$? ;;
  audio-session-recording)
    run_suite FTPlayerDemo audio-session-recording -only-testing:FTPlayerPlaybackTests/FTPlayerPrivateAudioSessionTests \
      -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO || status=$?
    python3 - "$ROOT/Demo/Tests/Playback/FTPlayerMuteTests.swift" "$OUT/audio-session-recording-summary.csv" <<'PYAUDIORECORDING' || status=$?
from test_inventory import source_text
import csv,re,sys
from pathlib import Path
expected=set(re.findall(r'func (testPrivateURL\w+)\(',source_text(Path(sys.argv[1]))))
rows=list(csv.DictReader(Path(sys.argv[2]).open()))
actual={row['test'].removesuffix('()') for row in rows if row['suite']=='FTPlayerPrivateAudioSessionTests'}
if not expected or actual!=expected or any(row['result']!='Passed' for row in rows):
 sys.exit('Private recording audio test was missing, skipped or failed; inspect its input and results')
print('Verified private recording audio test executed and passed')
PYAUDIORECORDING
    ;;
  audio-session)
    run_suite FTPlayerDemo audio-session -only-testing:FTPlayerPlaybackTests/FTPlayerAudioSessionTests \
      -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO || status=$?
    python3 - "$ROOT/Demo/Tests/Playback/FTPlayerMuteTests.swift" "$OUT/audio-session-summary.csv" <<'PYAUDIOSESSION' || status=$?
from test_inventory import source_text
import csv,re,sys
from pathlib import Path
expected=set(re.findall(r'func (testAudioSession\w+)\(',source_text(Path(sys.argv[1]))))
rows=list(csv.DictReader(Path(sys.argv[2]).open()))
actual={row['test'].removesuffix('()') for row in rows if row['suite']=='FTPlayerAudioSessionTests'}
if not expected or actual!=expected:
 sys.exit('Audio-session test discovery mismatch: missing='+str(sorted(expected-actual))+' extra='+str(sorted(actual-expected)))
if any(row['result']!='Passed' for row in rows): sys.exit('Audio-session tests did not all pass')
print('Verified all '+str(len(expected))+' audio-session methods executed and passed')
PYAUDIOSESSION
    ;;
  cache) run_suite FTPlayerDemo cache -only-testing:FTPlayerPlaybackTests/FTPlayerHTTPTests || status=$? ;;
  session-cache)
    session_filters=()
    while IFS= read -r entry; do session_filters+=("-only-testing:FTPlayerPlaybackTests/$entry"); done < <(python3 - "$ROOT" <<'PYSESSION'
from test_inventory import source_text
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
for suite,path in [('FTPlayerHTTPTests','Demo/Tests/Playback/FTPlayerHTTPTests.swift'),('FTPlayerDemoTests','Demo/Tests/FTPlayerDemoTests.swift')]:
 for name in re.findall(r'func (testSession\w+)\(', source_text(root/path)):print(suite+'/'+name)
PYSESSION
)
    run_suite FTPlayerDemo session-cache "${session_filters[@]}" || status=$?
    ;;

  errors)
    error_filters=()
    while IFS= read -r entry; do error_filters+=("-only-testing:FTPlayerPlaybackTests/$entry"); done < <(python3 - "$ROOT" <<'PYERRORS'
from test_inventory import source_text
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
extra={'testHTTP403','testHTTP404','testHTTP500','testHTTPCache404FailsWithoutRetryLoop','testHTMLDisguisedAsMP4','testBrokenHLSMissingSegment','testCacheStalledReadReturnsTimeoutInsteadOfHanging','testCachePlaysWhenHEADStallsButGETHasContentRange','testCacheStopCancelsStalledMetadataProbe','testStopDuringStalledOpen'}
for suite,path in [('FTPlayerHTTPTests','Demo/Tests/Playback/FTPlayerHTTPTests.swift'),('FTPlayerDemoTests','Demo/Tests/FTPlayerDemoTests.swift')]:
 for method in re.findall(r'func (test\w+)\(', source_text(root/path)):
  if method.startswith(('testError','testCacheNetwork')) or method in extra:print(suite+'/'+method)
PYERRORS
)
    run_suite FTPlayerDemo errors "${error_filters[@]}" || status=$?
    ;;

  photoprism)
    run_suite FTPlayerDemo photoprism-local \
      -only-testing:FTPlayerPlaybackTests/FTPlayerFormatTests/testReviewHEVCBFramePictureOrderHardware \
      -only-testing:FTPlayerPlaybackTests/FTPlayerFormatTests/testReviewHEVCBFramePictureOrderFFmpeg \
      -only-testing:FTPlayerPlaybackTests/FTPlayerFormatTests/testReviewHEVCHardwareDoesNotHoldDecodedReferenceSurfaces || status=$?
    photo_filters=()
    for policy in Hardware Ffmpeg; do
      for rate in 2 4 8 16; do
        photo_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerDecodeBackendTests/test${policy}PhotoprismHEVCSeekAt${rate}xAndBackTo1x")
      done
      photo_filters+=("-only-testing:FTPlayerPlaybackTests/FTPlayerDecodeBackendTests/test${policy}PhotoprismHEVCRapidSeekAndRate")
    done
    run_suite FTPlayerDecodeBackends photoprism-backends "${photo_filters[@]}" || status=$?
    ;;
  photoprism-internet)
    run_suite FTPlayerInternet photoprism-internet -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testHevcPhotoprismTSU || status=$?
    ;;
  sdk|unit)
    run_suite FTPlayerUnit unit -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO || status=$?
    python3 "$ROOT/Scripts/verify-test-execution.py" unit "$OUT/unit-summary.csv" || status=$?
    ;;
  ui)
    run_suite FTPlayerDemoUI ui -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO || status=$?
    python3 "$ROOT/Scripts/verify-test-execution.py" ui "$OUT/ui-summary.csv" || status=$?
    ;;
  playback-public)
    python3 - "$ROOT" "$OUT/public-media-sources.json" <<'PYPUBLICMEDIA'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
rows=json.loads((root/'Demo/Sources/SampleStreams.json').read_text())
names={'internet-h264.mp4':'mp4-h264','internet-hevc.mp4':'mp4-hevc','photoprism-tsu-hevc.mp4':'mp4-hevc-photoprism-tsu'}
sources={path:next(row['url'] for row in rows if row['id']==source) for path,source in names.items()}
Path(sys.argv[2]).write_text(json.dumps({'sources':sources},indent=2)+'\n')
PYPUBLICMEDIA
    FTPLAYER_TEST_MEDIA_MANIFEST="$OUT/public-media-sources.json"
    run_suite FTPlayerPlayback playback-public -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO \
      -only-testing:FTPlayerPlaybackTests/FTPlayerFormatTests/testH264MP4 \
      -only-testing:FTPlayerPlaybackTests/FTPlayerFormatTests/testHEVCMP4 \
      -only-testing:FTPlayerPlaybackTests/FTPlayerInternetTests/testHevcPhotoprismTSU || status=$?
    python3 - "$OUT/playback-public-summary.csv" <<'PYVERIFYPUBLIC'
import csv,sys
from pathlib import Path
rows=list(csv.DictReader(Path(sys.argv[1]).open()))
expected={'testH264MP4','testHEVCMP4','testHevcPhotoprismTSU'}
if {row['test'].removesuffix('()') for row in rows} != expected or any(row['result']!='Passed' for row in rows):
 raise SystemExit('Public playback cases were missing, skipped or failed')
print('Verified three real public URL playback cases; no bundled video or skip counted as PASS')
PYVERIFYPUBLIC
    ;;
  playback) run_suite FTPlayerPlayback playback || status=$? ;;
  full)
    run_suite FTPlayerUnit unit || status=$?
    run_suite FTPlayerDemoUI ui || status=$?
    run_suite FTPlayerDemo local || status=$?
    run_suite FTPlayerInternet internet || status=$?
    run_suite FTPlayerDecodeBackends backends-local || status=$?
    run_suite FTPlayerDecodeBackendsInternet backends-internet || status=$?
    ;;
  local)
    run_suite FTPlayerUnit unit -parallel-testing-enabled NO FTPLAYER_CREATE_XCFRAMEWORK=NO || status=$?
    python3 "$ROOT/Scripts/verify-test-execution.py" unit "$OUT/unit-summary.csv" || status=$?
    ;;
  internet) run_suite FTPlayerInternet internet || status=$? ;;
  backends) run_suite FTPlayerDecodeBackends backends-local || status=$? ;;
  backends-internet) run_suite FTPlayerDecodeBackendsInternet backends-internet || status=$? ;;
  backends-all)
    run_suite FTPlayerDecodeBackends backends-local || status=$?
    run_suite FTPlayerDecodeBackendsInternet backends-internet || status=$?
    ;;
  all)
    run_suite FTPlayerDemoUI ui || status=$?
    run_suite FTPlayerDemo local || status=$?
    run_suite FTPlayerInternet internet || status=$?
    ;;
  *) echo "Usage: $0 unit|sdk|ui|playback-public|playback|local|internet|rate-reset|rate-transition|high-rate-load|high-rate-camera|ready-seek|ready-seek-online|weak-network-rate|catalog-cache|catalog-extra|catalog-more|catalog-round3|catalog-stress|catalog-controls|malformed-media|mux-16x|all|backends|backends-internet|backends-all|full|spam-seek|daily-startup|startup-log|audio|audio-session|audio-session-recording|cache|session-cache|preparation|errors|photoprism|photoprism-internet|hls-review|load-control|load-review"; exit 2 ;;
esac
echo "Results: $OUT"
exit "$status"
