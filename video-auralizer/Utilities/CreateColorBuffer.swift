//
//  CreateSolidColorBuffer.swift
//  video-auralizer
//
//  Created by Matthew Casali on 2/9/26.
//

import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd
import Accelerate

func createColorBuffer(color: UIColor, width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
        kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
        kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue // Essential for Metal!
    ] as CFDictionary
    
    let status: CVReturn = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs,
        &pixelBuffer
    )
    
    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        return nil as CVPixelBuffer?
    }
    
    CVPixelBufferLockBaseAddress(buffer, [])
    let data = CVPixelBufferGetBaseAddress(buffer)
    
    // Get RGBA components
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    
    // Convert to BGRA for the metal shader
    let bInt = UInt8(b * 255)
    let gInt = UInt8(g * 255)
    let rInt = UInt8(r * 255)
    let aInt = UInt8(a * 255)
    
    let pixelCount = width * height
    let pixelData = UnsafeMutablePointer<UInt8>(data!.assumingMemoryBound(to: UInt8.self))
    
    for i in 0..<pixelCount {
        pixelData[i*4] = bInt
        pixelData[i*4+1] = gInt
        pixelData[i*4+2] = rInt
        pixelData[i*4+3] = aInt
    }
    
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
