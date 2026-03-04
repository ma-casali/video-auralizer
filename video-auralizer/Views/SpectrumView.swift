//
//  SpectrumView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//

import SwiftUI
import simd

struct SpectrumView: View {
    @ObservedObject var converter: VideoToAudio
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack{
            GeometryReader { geo in
                TimelineView(.animation) { timeline in
                    Canvas { context, size in

                        let width = size.width
                        let height = size.height

                        func xPosition(for frequency: Float) -> CGFloat {
                            let xNorm = log2(frequency / 20.0) / log2(20_000.0 / 20.0)
                            return CGFloat(xNorm) * width
                        }
                        
                        // --- Fetch previous spectrum ---
                        let spectrum = converter.soundEngine.previousSpectrum
                        guard !spectrum.isEmpty else { return }
                        
                        // --- Fetch f values
                        let f = converter.soundEngine.original_f
                        guard !f.isEmpty else { return }
                        
                        // --- Compute magnitude in dB ---
                        let magnitudes: [Float] = spectrum.map { c in
                            let mag = sqrt(c.real*c.real + c.imag*c.imag)
                            return mag
                        }
                        
                        let maxMagnitude: Float = magnitudes.max()!
                        let magnitudeDB = magnitudes.map { c in
                            return 20 * log10( c / maxMagnitude)
                        }
                        
                        let maxDB: Float = 0
                        let minDB: Float = -180
                        
                        // --- Draw spectrum line ---
                        var path = Path()
                        for i in 0..<magnitudes.count {
                            
                            let xNorm = log2(f[i] / 20.0) / log2(20_000.0 / 20.0)
                            let x = CGFloat(xNorm) * width
                            let yNorm = (magnitudeDB[i] - minDB) / (maxDB - minDB)
                            let y = height * (1 - CGFloat(yNorm))
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        context.stroke(
                            path,
                            with: .color(.black),
                            style: StrokeStyle(
                                lineWidth: 5,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }
                }
            }
            .cornerRadius(8)
            .shadow(radius: 3)
        }
    }
}

#Preview {
    SpectrumView(converter: VideoToAudio())
}
