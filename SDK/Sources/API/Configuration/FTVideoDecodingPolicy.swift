import Foundation

/// Set before replaceVideo(). Strict hardware never falls back to software.
public enum FTVideoDecodingPolicy: String {
    case automatic
    case ffmpeg
    case hardware
}
