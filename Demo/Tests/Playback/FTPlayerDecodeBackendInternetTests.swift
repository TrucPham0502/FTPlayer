import XCTest
@testable import FTPlayer

final class FTPlayerDecodeBackendInternetTests: DecodeBackendTestCase {
    func testFfmpegMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .ffmpeg, rate: 2, internet: true) }
    func testFfmpegMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .ffmpeg, rate: 4, internet: true) }
    func testFfmpegMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .ffmpeg, rate: 8, internet: true) }
    func testFfmpegMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .ffmpeg, rate: 16, internet: true) }
    func testFfmpegMP4H264RapidSeekAndRate() throws { try checkRapid("mp4-h264-w3c", policy: .ffmpeg, internet: true) }
    func testFfmpegMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .ffmpeg, rate: 2, internet: true) }
    func testFfmpegMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .ffmpeg, rate: 4, internet: true) }
    func testFfmpegMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .ffmpeg, rate: 8, internet: true) }
    func testFfmpegMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .ffmpeg, rate: 16, internet: true) }
    func testFfmpegMP4HEVCRapidSeekAndRate() throws { try checkRapid("mp4-hevc", policy: .ffmpeg, internet: true) }
    func testFfmpegHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-media", policy: .ffmpeg, rate: 2, internet: true) }
    func testFfmpegHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-media", policy: .ffmpeg, rate: 4, internet: true) }
    func testFfmpegHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-media", policy: .ffmpeg, rate: 8, internet: true) }
    func testFfmpegHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-media", policy: .ffmpeg, rate: 16, internet: true) }
    func testFfmpegHLSH264RapidSeekAndRate() throws { try checkRapid("hls-media", policy: .ffmpeg, internet: true) }
    func testFfmpegHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .ffmpeg, rate: 2, internet: true) }
    func testFfmpegHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .ffmpeg, rate: 4, internet: true) }
    func testFfmpegHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .ffmpeg, rate: 8, internet: true) }
    func testFfmpegHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .ffmpeg, rate: 16, internet: true) }
    func testFfmpegHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc", policy: .ffmpeg, internet: true) }
    func testHardwareMP4H264SeekAt2xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .hardware, rate: 2, internet: true) }
    func testHardwareMP4H264SeekAt4xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .hardware, rate: 4, internet: true) }
    func testHardwareMP4H264SeekAt8xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .hardware, rate: 8, internet: true) }
    func testHardwareMP4H264SeekAt16xAndBackTo1x() throws { try checkRate("mp4-h264-w3c", policy: .hardware, rate: 16, internet: true) }
    func testHardwareMP4H264RapidSeekAndRate() throws { try checkRapid("mp4-h264-w3c", policy: .hardware, internet: true) }
    func testHardwareMP4HEVCSeekAt2xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .hardware, rate: 2, internet: true) }
    func testHardwareMP4HEVCSeekAt4xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .hardware, rate: 4, internet: true) }
    func testHardwareMP4HEVCSeekAt8xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .hardware, rate: 8, internet: true) }
    func testHardwareMP4HEVCSeekAt16xAndBackTo1x() throws { try checkRate("mp4-hevc", policy: .hardware, rate: 16, internet: true) }
    func testHardwareMP4HEVCRapidSeekAndRate() throws { try checkRapid("mp4-hevc", policy: .hardware, internet: true) }
    func testHardwareHLSH264SeekAt2xAndBackTo1x() throws { try checkRate("hls-media", policy: .hardware, rate: 2, internet: true) }
    func testHardwareHLSH264SeekAt4xAndBackTo1x() throws { try checkRate("hls-media", policy: .hardware, rate: 4, internet: true) }
    func testHardwareHLSH264SeekAt8xAndBackTo1x() throws { try checkRate("hls-media", policy: .hardware, rate: 8, internet: true) }
    func testHardwareHLSH264SeekAt16xAndBackTo1x() throws { try checkRate("hls-media", policy: .hardware, rate: 16, internet: true) }
    func testHardwareHLSH264RapidSeekAndRate() throws { try checkRapid("hls-media", policy: .hardware, internet: true) }
    func testHardwareHLSHEVCSeekAt2xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .hardware, rate: 2, internet: true) }
    func testHardwareHLSHEVCSeekAt4xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .hardware, rate: 4, internet: true) }
    func testHardwareHLSHEVCSeekAt8xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .hardware, rate: 8, internet: true) }
    func testHardwareHLSHEVCSeekAt16xAndBackTo1x() throws { try checkRate("hls-hevc", policy: .hardware, rate: 16, internet: true) }
    func testHardwareHLSHEVCRapidSeekAndRate() throws { try checkRapid("hls-hevc", policy: .hardware, internet: true) }
    func testFfmpegPrivatePlaybackSeekAt2xAndBackTo1x() throws { try checkRate("private-playback", policy: .ffmpeg, rate: 2, internet: true) }
    func testFfmpegPrivatePlaybackSeekAt4xAndBackTo1x() throws { try checkRate("private-playback", policy: .ffmpeg, rate: 4, internet: true) }
    func testFfmpegPrivatePlaybackSeekAt8xAndBackTo1x() throws { try checkRate("private-playback", policy: .ffmpeg, rate: 8, internet: true) }
    func testFfmpegPrivatePlaybackSeekAt16xAndBackTo1x() throws { try checkRate("private-playback", policy: .ffmpeg, rate: 16, internet: true) }
    func testFfmpegPrivatePlaybackRapidSeekAndRate() throws { try checkRapid("private-playback", policy: .ffmpeg, internet: true) }
    func testHardwarePrivatePlaybackSeekAt2xAndBackTo1x() throws { try checkRate("private-playback", policy: .hardware, rate: 2, internet: true) }
    func testHardwarePrivatePlaybackSeekAt4xAndBackTo1x() throws { try checkRate("private-playback", policy: .hardware, rate: 4, internet: true) }
    func testHardwarePrivatePlaybackSeekAt8xAndBackTo1x() throws { try checkRate("private-playback", policy: .hardware, rate: 8, internet: true) }
    func testHardwarePrivatePlaybackSeekAt16xAndBackTo1x() throws { try checkRate("private-playback", policy: .hardware, rate: 16, internet: true) }
    func testHardwarePrivatePlaybackRapidSeekAndRate() throws { try checkRapid("private-playback", policy: .hardware, internet: true) }

}
