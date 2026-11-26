// Test-fixture generator only: preserve the AAC bitstream and emit HLS fMP4.
// Usage: make-audio input.m4a output.mp4
import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class Segments: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var bytes = Data()
    private var initializationSize = 0
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        if segmentType == .initialization { initializationSize = data.count }
        bytes.append(data)
    }
    func save(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        precondition(initializationSize > 0 && bytes.range(of: Data("moof".utf8)) != nil)
        try bytes.write(to: url, options: .atomic)
        print("bytes=\(bytes.count) initialization=\(initializationSize)")
    }
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let asset = AVURLAsset(url: source)
let audio = asset.tracks(withMediaType: .audio).first!
let reader = try AVAssetReader(asset: asset)
let samples = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
reader.add(samples)
let writer = AVAssetWriter(contentType: .mpeg4Movie)
let segments = Segments()
writer.delegate = segments
writer.outputFileTypeProfile = .mpeg4AppleHLS
writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1000)
writer.initialSegmentStartTime = .zero
let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                              sourceFormatHint: (audio.formatDescriptions.first as! CMFormatDescription))
input.expectsMediaDataInRealTime = false
writer.add(input)
precondition(writer.startWriting()); precondition(reader.startReading())
writer.startSession(atSourceTime: .zero)
while let buffer = samples.copyNextSampleBuffer() {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
    precondition(input.append(buffer))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
precondition(writer.status == .completed, String(describing: writer.error))
try segments.save(output)
