import XCTest
@testable import FTPlayer

final class FTPlayerDecodeBackendTests: DecodeBackendTestCase {
    func testFfmpegPhotoprismHEVCSeekAt2xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegPhotoprismHEVCSeekAt4xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegPhotoprismHEVCSeekAt8xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegPhotoprismHEVCSeekAt16xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegPhotoprismHEVCRapidSeekAndRate() throws { try checkRapid("photoprism-tsu-hevc.mp4", policy: .ffmpeg) }
    func testHardwarePhotoprismHEVCSeekAt2xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 2) }
    func testHardwarePhotoprismHEVCSeekAt4xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 4) }
    func testHardwarePhotoprismHEVCSeekAt8xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 8) }
    func testHardwarePhotoprismHEVCSeekAt16xAndBackTo1x() throws { try checkRate("photoprism-tsu-hevc.mp4", policy: .hardware, rate: 16) }
    func testHardwarePhotoprismHEVCRapidSeekAndRate() throws { try checkRapid("photoprism-tsu-hevc.mp4", policy: .hardware) }
    func testFfmpegMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegMP4H264RapidSeekAndRate() throws { try checkRapid("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4H264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4H264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("sample.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 2) }
    func testFfmpegMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 4) }
    func testFfmpegMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 8) }
    func testFfmpegMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .ffmpeg, rate: 16) }
    func testFfmpegMP4HEVCRapidSeekAndRate() throws { try checkRapid("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegMP4HEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("internet-hevc.mp4", policy: .ffmpeg) }
    func testFfmpegHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 2) }
    func testFfmpegHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 4) }
    func testFfmpegHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 8) }
    func testFfmpegHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .ffmpeg, rate: 16) }
    func testFfmpegHLSH264RapidSeekAndRate() throws { try checkRapid("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSH264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSH264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-ts/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 2) }
    func testFfmpegHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 4) }
    func testFfmpegHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 8) }
    func testFfmpegHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .ffmpeg, rate: 16) }
    func testFfmpegHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testFfmpegHLSHEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-hevc/index.m3u8", policy: .ffmpeg) }
    func testHardwareMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 2) }
    func testHardwareMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 4) }
    func testHardwareMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 8) }
    func testHardwareMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("sample.mp4", policy: .hardware, rate: 16) }
    func testHardwareMP4H264RapidSeekAndRate() throws { try checkRapid("sample.mp4", policy: .hardware) }
    func testHardwareMP4H264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("sample.mp4", policy: .hardware) }
    func testHardwareMP4H264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("sample.mp4", policy: .hardware) }
    func testHardwareMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 2) }
    func testHardwareMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 4) }
    func testHardwareMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 8) }
    func testHardwareMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("internet-hevc.mp4", policy: .hardware, rate: 16) }
    func testHardwareMP4HEVCRapidSeekAndRate() throws { try checkRapid("internet-hevc.mp4", policy: .hardware) }
    func testHardwareMP4HEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("internet-hevc.mp4", policy: .hardware) }
    func testHardwareMP4HEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("internet-hevc.mp4", policy: .hardware) }
    func testHardwareHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 2) }
    func testHardwareHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 4) }
    func testHardwareHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 8) }
    func testHardwareHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-ts/index.m3u8", policy: .hardware, rate: 16) }
    func testHardwareHLSH264RapidSeekAndRate() throws { try checkRapid("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSH264PauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSH264EveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-ts/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 2) }
    func testHardwareHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 4) }
    func testHardwareHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 8) }
    func testHardwareHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc/index.m3u8", policy: .hardware, rate: 16) }
    func testHardwareHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCPauseSeekAndNearEnd() throws { try checkPauseAndBoundary("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareHLSHEVCEveryIntegerRate2Through16() throws { try checkEveryIntegerRate("hls-hevc/index.m3u8", policy: .hardware) }
    func testHardwareH264DamagedPicturesRecoverWithoutSoftwareFallback() throws {
        let s = try backendSession("w3c-nonref.mp4", policy: .hardware)
        // The source has incomplete non-reference pictures around 3.52s and 9.60s.
        // At 1x, require displayed video past both, rather than accepting ready/stats.
        try require(until(20) { (s.player.decoder?.currentVideoFrame?.position ?? 0) > 12 || s.failure != nil }, "Hardware did not recover past damaged H264 pictures")
        try require((s.player.decoder?.currentVideoFrame?.position ?? 0) > 12, "Hardware video stalled after a bad picture")
        try assertBackend(s, .hardware)
        s.measurements.append(["operation": "hardware-bad-picture-recovery", "displayedPTS": s.player.decoder?.currentVideoFrame?.position ?? -1, "hardwareFrames": s.player.videoDecodingStatistics.hardwareFrames])
    }
    func testHardwareHLS60FPSSeekAt16xAndBackTo1x() throws {
        try checkRate("hls-60fps/index.m3u8", policy: .hardware, rate: 16)
    }

}
