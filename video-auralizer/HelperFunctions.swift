//
//  HelperFunctions.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/8/25.
//

import Foundation
import AVFoundation
import Accelerate

// MARK: - Complex Struct
struct Complex {
    var real: Float
    var imag: Float
    
    init(_ real: Float, _ imag: Float) {
        self.real = real
        self.imag = imag
    }
    
    static func +(lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imag + rhs.imag)
    }
    
    static func -(lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real - rhs.real, lhs.imag - rhs.imag)
    }
    
    static func *(lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real*rhs.real - lhs.imag*rhs.imag,
                lhs.real*rhs.imag + lhs.imag*rhs.real)
    }
    
    static func /(lhs: Complex, rhs: Complex) -> Complex {
        let denom = rhs.real*rhs.real + rhs.imag*rhs.imag
        return Complex(
            (lhs.real*rhs.real + lhs.imag*rhs.imag)/denom,
            (lhs.imag*rhs.real - lhs.real*rhs.imag)/denom
        )
    }
    
    func magnitude() -> Float {
        sqrt(real*real + imag*imag)
    }
    
    var conjugate: Complex {
        Complex(real, -imag)
    }
}

// MARK: - Linear / Log2 Conversion
func linearToLog2(_ x: [Float], x0: Float = 20.0, x1: Float = 20_000.0, y0: Float = 400.0, y1: Float = 790.0) -> [Float] {
    let m = (y1 - y0) / log2(x1 / x0)
    return x.map { m * log2($0 / x0) + y0 }
}

func linearToLog2Single(_ x: Float, x0: Float = 20.0, x1: Float = 20_000.0, y0: Float = 400.0, y1: Float = 790.0) -> Float {
    let m = (y1 - y0) / log2(x1 / x0)
    return m * log2(x / x0) + y0
}

// MARK: - LUT Storage
private var f0LUT: [Float] = []
private let lutSize = 256

// MARK: - Load LUT from Bundle
func loadFrequencyLUT() {
    guard let url = Bundle.main.url(forResource: "frequency_lut", withExtension: "bin") else {
        print("LUT file not found in bundle!")
        return
    }
    
    do {
        let data = try Data(contentsOf: url)
        let expectedCount = lutSize * lutSize * lutSize
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            print("LUT file size mismatch: expected \(expectedCount * MemoryLayout<Float>.size), got \(data.count)")
            return
        }
        
        f0LUT = [Float](repeating: 0, count: expectedCount)
        data.withUnsafeBytes { ptr in
            let floatPtr = ptr.bindMemory(to: Float.self)
            for i in 0..<expectedCount {
                f0LUT[i] = floatPtr[i]
            }
        }
        print("Frequency LUT loaded with \(f0LUT.count) entries ✅")
        
    } catch {
        print("Failed to load LUT: \(error)")
    }
}

// MARK: - Lookup Function
func lookupF0(r: Int, g: Int, b: Int) -> Float {
    guard !f0LUT.isEmpty else {
        print("Warning: LUT not loaded yet")
        return 400.0  // fallback value
    }
    
    let rClamped = max(0, min(lutSize - 1, r))
    let gClamped = max(0, min(lutSize - 1, g))
    let bClamped = max(0, min(lutSize - 1, b))
    
    let index = rClamped * lutSize * lutSize + gClamped * lutSize + bClamped
    return f0LUT[index]
}

// MARK: - Mirror & Conjugate
func mirrorAndConjugate(_ half: [Complex]) -> [DSPComplex] {
    let F = half.count // number of bins from frequency sampling
    let NFFT = 2 * (F + 1)
    
    var full = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: NFFT)
    
    // DC bin
    full[0] = DSPComplex(real: 0, imag: 0)
    
    for k in 0..<F {
        let c = half[k]
        full[k+1] = DSPComplex(real: c.real, imag: c.imag) // Positive frequencies
        full[NFFT - (k + 1)] = DSPComplex(real: c.real, imag: -c.imag) // Negative frequencies
    }
    
    // Nyquist bin
    full[F + 1] = DSPComplex(real: 0, imag: 0)
    
    return full
}

// MARK: - Sigmoid Normalization
func sigmoidNormalize(x: Float, M: Float, k: Float = 2.0) -> Float {
    let scaled = x / M
    let g = 1.0 / (1.0 + exp(-k*(scaled - 0.5)))
    let g0 = 1.0 / (1.0 + exp(-k*(0.0 - 0.5)))
    let g1 = 1.0 / (1.0 + exp(-k*(1.0 - 0.5)))
    return (g - g0) / (g1 - g0)
}

// MARK: - LUT Path Helpers
func lutFilePath(fileName: String = "frequency_lut.bin") -> URL {
    let fm = FileManager.default
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent(fileName)
}

// MARK: - Linspace
func linspace(start: Float, end: Float, num: Int) -> [Float] {
    guard num > 1 else { return [start] }
    let step = (end - start) / Float(num - 1)
    return (0..<num).map { start + Float($0) * step }
}

// MARK: - IFFT
func iFFT(_ spectrum: [DSPComplex]) -> [Float] {
    let count = spectrum.count
    let log2N = vDSP_Length(log2(Float(count)))
    
    let realPtr = UnsafeMutablePointer<Float>.allocate(capacity: count)
    let imagPtr = UnsafeMutablePointer<Float>.allocate(capacity: count)
    
    for i in 0..<count {
        realPtr[i] = spectrum[i].real
        imagPtr[i] = spectrum[i].imag
    }
    
    var split = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
    
    guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
        fatalError("FFT setup failed")
    }
    
    vDSP_fft_zip(fftSetup, &split, 1, log2N, FFTDirection(FFT_INVERSE))
    
    var scale = 1.0 / Float(count)
    vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(count))
    
    let output = Array(UnsafeBufferPointer(start: split.realp, count: count))
    
    vDSP_destroy_fftsetup(fftSetup)
    realPtr.deallocate()
    imagPtr.deallocate()
    
    return output
}

