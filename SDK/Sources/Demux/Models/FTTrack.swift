//
//  FTTrack.swift
//  
//
//  Edited by TP on 2024/11/21.
//

import Foundation

// Enum for track type
enum FTTrackType: UInt {
    case video = 0
    case audio
    case subtitle
}

// Class for track
class FTTrack {
    var index: Int
    var type: FTTrackType
    var metadata: FTMetadata?

    init(index: Int, type: FTTrackType, metadata: FTMetadata? = nil) {
        self.index = index
        self.type = type
        self.metadata = metadata
    }
}
