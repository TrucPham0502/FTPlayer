import Foundation

extension SyntheticMedia {
    /// The former Demo fixture tree, generated once per test process at the
    /// paths `FixtureHTTPServer` serves (sample, faststart, HLS variants…).
    static func fixtureRoot() throws -> URL { try fixtureTree.get() }

    private static let fixtureTree = Result { () throws -> URL in
        let files = FileManager.default
        let root = directory.appendingPathComponent("fixtures")
        try? files.removeItem(at: root)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = try SyntheticMedia.sample()
        try files.copyItem(at: sample, to: root.appendingPathComponent("sample.mp4"))
        try remux(sample, to: root.appendingPathComponent("faststart.mp4"), format: "mp4", options: ["movflags": "+faststart"])

        try hls(sample, in: root.appendingPathComponent("hls-ts"), type: "mpegts")
        try hls(sample, in: root.appendingPathComponent("hls-fmp4"), type: "fmp4")
        // Shaped like the former 10.1 s HEVC clip: one 8.3 s GOP, then a short tail.
        let hevc = try cached("hevc-10s.mp4") {
            try write(Spec(duration: 10.1, video: Video(codec: .hevc, fps: 30, gop: 250), audio: nil), to: $0)
        }
        try hls(hevc, in: root.appendingPathComponent("hls-hevc"), type: "fmp4")

        let aes = root.appendingPathComponent("hls-aes128")
        try files.createDirectory(at: aes, withIntermediateDirectories: true)
        let key = aes.appendingPathComponent("key.bin"), keyInfo = directory.appendingPathComponent("aes128.keyinfo")
        try Data(0..<16).write(to: key)
        try "key.bin\n\(key.path)\n000102030405060708090a0b0c0d0e0f\n".write(to: keyInfo, atomically: true, encoding: .utf8)
        try hls(sample, in: aes, type: "mpegts", options: ["hls_key_info_file": keyInfo.path], master: false)

        // Audio-only fragmented MP4: moov, then moof/mdat fragments (byte-range HLS rendition).
        try remux(sample, to: root.appendingPathComponent("hls-master-audio.mp4"), format: "mp4", video: false,
                  options: ["movflags": "empty_moov+default_base_moof", "frag_duration": "2000000"])

        // 1 fps camera-style video, 30 s, no B-frames: at >= 2x the decoder discards
        // non-reference pictures, which would hide a B-frame tail. frag_custom keeps
        // a declared AAC track that has no packets.
        let slow = Video(fps: 1, gop: 30, bFrames: 0)
        try write(Spec(video: slow, audioDuration: 0, muxerOptions: ["movflags": "frag_custom"]),
                  to: root.appendingPathComponent("empty-audio.mp4"))
        try write(Spec(video: slow, audioDuration: 3), to: root.appendingPathComponent("partial-audio.mp4"))
        try write(Spec(video: slow), to: root.appendingPathComponent("audio-present.mp4"))

        // 60 fps TS VOD: three 10 s segments, one GOP each.
        let sixty = root.appendingPathComponent("hls-60fps")
        try files.createDirectory(at: sixty, withIntermediateDirectories: true)
        try write(Spec(format: "hls", fileExtension: "m3u8", video: Video(fps: 60, gop: 600),
                       muxerOptions: ["hls_time": "10", "hls_list_size": "0", "hls_playlist_type": "vod",
                                      "hls_segment_filename": sixty.appendingPathComponent("segment-%d.ts").path]),
                  to: sixty.appendingPathComponent("index.m3u8"))

        // Container and codec variants served over HTTP.
        for (name, format, video, audio) in [("h264.mov", "mov", true, true), ("h264.mkv", "matroska", true, true),
                                             ("h264.ts", "mpegts", true, true), ("h264.flv", "flv", true, true),
                                             ("raw.h264", "h264", true, false), ("audio.m4a", "ipod", false, true)] {
            try files.copyItem(at: SyntheticMedia.sample(as: name, format: format, video: video, audio: audio), to: root.appendingPathComponent(name))
        }
        let generated: [(String, Spec)] = [
            ("raw.h265", Spec(format: "hevc", fileExtension: "h265", duration: 10, video: Video(codec: .hevc), audio: nil)),
            // Stand-ins for the former 10 s Big Buck Bunny 360p clips (video only).
            ("internet-h264.mp4", Spec(duration: 10, video: Video(fps: 30, gop: 60), audio: nil)),
            ("internet-hevc.mp4", Spec(duration: 10, video: Video(codec: .hevc, fps: 30, gop: 60), audio: nil)),
            ("sustained-hevc-aac.mp4", Spec(duration: 160, video: Video(codec: .hevc, fps: 30, gop: 60))),
            // Stand-in for the former 720p HEVC camera clip.
            ("photoprism-tsu-hevc.mp4", Spec(duration: 12, video: Video(codec: .hevc, width: 1280, height: 720, fps: 30, gop: 30), audio: nil)),
        ]
        for (name, spec) in generated {
            try files.copyItem(at: cached(name) { try write(spec, to: $0) }, to: root.appendingPathComponent(name))
        }
        try files.copyItem(at: sustained(), to: root.appendingPathComponent("sustained-h264-aac.mp4"))
        // 160 s muxed A/V TS behind a master playlist, for cached HLS at 16x.
        try hls(sustained(), in: root.appendingPathComponent("hls-sustained"), type: "mpegts")
        try files.copyItem(at: cached("sustained-h264-video.mp4") { try write(Spec(duration: 160, audio: nil), to: $0) },
                           to: root.appendingPathComponent("sustained-h264-video.mp4"))

        // Short AVI whose audio outlasts its 1 s of MPEG-4 video (MP2 stands in for the former MP3).
        try write(Spec(format: "avi", fileExtension: "avi", duration: 1,
                       video: Video(codec: .mpeg4, width: 320, height: 180, fps: 30, bFrames: 0),
                       audio: Audio(codec: .mp2, sampleRate: 32_000), audioDuration: 1.368),
                  to: root.appendingPathComponent("short-mpeg4-mp2.avi"))
        // Two-picture HEVC clip.
        try write(Spec(duration: 2.0 / 30, video: Video(codec: .hevc, width: 320, height: 240, fps: 30, gop: 1, bFrames: 0), audio: nil),
                  to: root.appendingPathComponent("tiny-hevc.mp4"))

        // Two 7.68 s TS segments at 25 fps; audio stops 2.33 s before the video
        // tail and the playlist carries an unparseable PROGRAM-DATE-TIME.
        let badPDT = root.appendingPathComponent("bad-pdt")
        try files.createDirectory(at: badPDT, withIntermediateDirectories: true)
        let badPlaylist = badPDT.appendingPathComponent("index.m3u8")
        try write(Spec(format: "hls", fileExtension: "m3u8", duration: 15.36, video: Video(fps: 25, gop: 192),
                       audio: Audio(sampleRate: 48_000), audioDuration: 13.03,
                       muxerOptions: ["hls_time": "7.68", "hls_list_size": "0", "hls_playlist_type": "vod",
                                      "hls_segment_filename": badPDT.appendingPathComponent("segment-%d.ts").path]),
                  to: badPlaylist)
        var playlist = try String(contentsOf: badPlaylist, encoding: .utf8)
        if let first = playlist.range(of: "#EXTINF") { playlist.insert(contentsOf: "#EXT-X-PROGRAM-DATE-TIME:TEST1\n", at: first.lowerBound) }
        try playlist.write(to: badPlaylist, atomically: true, encoding: .utf8)
        return root
    }

    private static func hls(_ source: URL, in folder: URL, type: String, options extra: [String: String] = [:], master: Bool = true) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var options = ["hls_time": "2", "hls_list_size": "0", "hls_segment_type": type,
                       "hls_segment_filename": folder.appendingPathComponent("segment%d.\(type == "fmp4" ? "m4s" : "ts")").path]
        options.merge(extra) { $1 }
        try remux(source, to: folder.appendingPathComponent("index.m3u8"), format: "hls", options: options)
        if master {
            try "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nindex.m3u8\n"
                .write(to: folder.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        }
    }
}
