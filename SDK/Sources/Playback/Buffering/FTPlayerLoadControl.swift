import Foundation

struct FTPlayerLoadControl {
    let configuration: FTPlayerLoadControlConfiguration
    let targetBytes: Int64
    private(set) var isLoading = false
    init(configuration: FTPlayerLoadControlConfiguration = .init(), video: Bool = true, audio: Bool = true) {
        self.configuration = configuration; targetBytes = configuration.targetBytes(video:video,audio:audio)
    }
    mutating func shouldLoad(mediaAhead: Double, bytesAhead: Int64, rate: Float) -> Bool {
        let sizeReached = bytesAhead >= targetBytes
        if mediaAhead < configuration.minimumDuration(rate:rate) {
            isLoading = configuration.prioritizesTimeOverSize || !sizeReached
        } else if mediaAhead >= configuration.maximumBufferDuration || sizeReached {
            isLoading = false
        }
        return isLoading
    }
}
