//
//  FTAudioOutputContext.swift
//  FTPlayer
//
//  Created by Như Trực on 10/3/26.
//

import AudioToolbox

struct FTAudioOutputContext {
    var graph: AUGraph? = nil
    var converterNodeContext = FTAudioNodeContext()
    var timePitchNodeContext = FTAudioNodeContext() // Đã thêm
    var mixerNodeContext = FTAudioNodeContext()
    var outputNodeContext = FTAudioNodeContext()
    var commonFormat = AudioStreamBasicDescription()
}
