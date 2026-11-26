//
//  FTArtworkFrame.swift
//  FTPlayer
//
//  Created by Như Trực on 10/3/26.
//

class FTArtworkFrame: FTFrame {
    var picture: Data?

    override var type: FTFrameType {
        return .artwork
    }
}
