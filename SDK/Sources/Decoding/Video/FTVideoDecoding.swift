import Foundation
import VideoToolbox

func ffVideoDecoderSpecification(requireHardware: Bool) -> CFDictionary {
    if #available(iOS 17.0, *) {
        return [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware] as CFDictionary
    }
    return [:] as CFDictionary
}

func ffVTSessionUsesHardware(_ session: VTDecompressionSession) -> Bool? {
    guard #available(iOS 17.0, *) else { return nil }
    // The void* output contains a retained CF object (Copy rule), not a Swift strong reference.
    var value: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                      allocator: kCFAllocatorDefault, valueOut: &value)
    let property = value?.takeRetainedValue()
    guard status == noErr else { return nil }
    return (property as? NSNumber)?.boolValue
}

// MPEG-TS/raw H.264 contains Annex-B SPS/PPS and packets, unlike MP4 avcC.
func ffAnnexBNALUnits(_ bytes: [UInt8]) -> [[UInt8]] {
    var starts: [(Int, Int)] = []
    var i = 0
    while i + 2 < bytes.count {
        if bytes[i] == 0 && bytes[i+1] == 0 {
            if bytes[i+2] == 1 { starts.append((i, i+3)); i += 3; continue }
            if i+3 < bytes.count && bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i, i+4)); i += 4; continue }
        }
        i += 1
    }
    return starts.enumerated().compactMap { index, entry in
        let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
        return end > entry.1 ? Array(bytes[entry.1..<end]) : nil
    }
}
