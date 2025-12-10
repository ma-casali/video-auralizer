//
//  SpectrumView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//

import SwiftUI
import simd

import SwiftUI

struct SpectrumView: View {
    @ObservedObject var converter: VideoConverter
    
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let width = size.width
                    let height = size.height
                    
                    // --- Draw color gradient background (rainbow) ---
                    let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .indigo, .purple]
                    let grad = Gradient(colors: colors)
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .linearGradient(grad, startPoint: .zero, endPoint: CGPoint(x: width, y: 0))
                    )
                    
                    // --- Fetch previous spectrum ---
                    let spectrum = converter.previousSpectrum
                    guard !spectrum.isEmpty else { return }
                    
                    // --- Compute magnitude in dB ---
                    let magnitudes: [Float] = spectrum.map { c in
                        let mag = sqrt(c.real*c.real + c.imag*c.imag)
                        return 20 * log10(max(mag, 1e-12))
                    }
                    
                    let maxDB: Float = 0
                    let minDB: Float = -120
                    
                    // --- Draw spectrum line ---
                    var path = Path()
                    for i in 0..<magnitudes.count {
                        let xNorm = log2(1 + Float(i)) / log2(1 + Float(magnitudes.count))
                        let x = CGFloat(xNorm) * width
                        let yNorm = (magnitudes[i] - minDB) / (maxDB - minDB)
                        let y = height * (1 - CGFloat(yNorm))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(.black), lineWidth: 2)
                    
                    // --- Overlay HP/LP cutoffs ---
                    let hpX = width * CGFloat(converter.hpCutoff / 20000)
                    let lpX = width * CGFloat(converter.lpCutoff / 20000)
                    context.stroke(Path { p in
                        p.move(to: CGPoint(x: hpX, y: 0))
                        p.addLine(to: CGPoint(x: hpX, y: height))
                        p.move(to: CGPoint(x: lpX, y: 0))
                        p.addLine(to: CGPoint(x: lpX, y: height))
                    }, with: .color(.black), lineWidth: 1)
                }
            }
        }
        .cornerRadius(8)
        .shadow(radius: 3)
    }
}
