//
//  HelperFunctions.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/8/25.
//

import Foundation
import AVFoundation
import Accelerate

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
    
    static func conjugate(_ c: Complex) -> Complex {
        Complex(c.real, -c.imag)
    }
}

// MARK: - Linear / Log2 Conversion

func linearToLog2(_ x: [Float], x0: Float = 20.0, x1: Float = 20_000.0, y0: Float = 400.0, y1: Float = 790.0)
-> [Float]{
    var z = [Float](repeating: 0, count: x.count)
    var m: Float = 0.0
    var b: Float = 0.0
    
    for i in 0..<x.count {
        m = (y1 - y0) / (log2(x1 / x0))
        b = y0
        z[i] = m * log2(x[i] / x0) + b
    }
    return z
}

// MARK: - LUT Storage
private var f0LUT: [Float] = []
private let lutSize = 256

// MARK: - Load LUT from Bundle
public func loadFrequencyLUT() {
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
public func lookupF0(r: Int, g: Int, b: Int) -> Float {
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
func mirrorAndConjugate(_ spec: [Complex]) -> [Complex] {
    let N = spec.count
    var out = [Complex](repeating: Complex(0,0), count: 2*N+1)
    for i in 0..<N { out[i+1] = spec[i] }
    for i in 0..<N { out[N+1+i] = Complex.conjugate(spec[N-1-i])}
    return out
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

// MARK: - numpy linspace equivalent
func linspace(start: Float, end: Float, num: Int) -> [Float] {
    guard num > 1 else { return [start] }
    
    let step = (end - start) / Float(num - 1)
    return (0..<num).map { i in
        start + Float(i) * step
    }
}
