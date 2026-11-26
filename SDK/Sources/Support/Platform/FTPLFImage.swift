//
//  FTPLFImage.swift
//  
//
//  Edited by TP on 2024/11/21.
//

import Foundation
import UIKit

typealias FTPLFImage = UIImage

// Function to create UIImage from CGImage
func FTPLFImageWithCGImage(_ image: CGImage) -> FTPLFImage {
    return UIImage(cgImage: image)
}

// Function to create UIImage from RGB data buffer
func FTPLFImageWithRGBData(_ rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int) -> FTPLFImage? {
    guard let imageRef = FTPLFImageCGImageWithRGBData(rgbData, linesize: linesize, width: width, height: height) else {
        return nil
    }
    let image = FTPLFImageWithCGImage(imageRef)
    return image
}

// Function to create CGImage from RGB data buffer
func FTPLFImageCGImageWithRGBData(_ rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int) -> CGImage? {
    guard let data = CFDataCreate(kCFAllocatorDefault, rgbData, linesize * height) else { return nil }
    guard let provider = CGDataProvider(data: data) else {
        return nil
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
    }

    let imageRef = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: linesize,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )

    return imageRef
}
