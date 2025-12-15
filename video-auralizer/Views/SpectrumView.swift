//
//  SpectrumView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//

import SwiftUI
import simd

struct SpectrumView: View {
    @ObservedObject var converter: VideoConverter
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack{
            GeometryReader { geo in
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let width = size.width
                        let height = size.height
                        let axisFrequencies: [Float] = [20, 80, 320, 1280, 5120, 20480]
                        
                        let axisColor: Color = (colorScheme == .dark) ? .white : .black
                        let textColor: Color = (colorScheme == .dark) ? .white : .black
                        
                        func xPosition(for frequency: Float) -> CGFloat {
                            let xNorm = log2(frequency / 20.0) / log2(20_000.0 / 20.0)
                            return CGFloat(xNorm) * width
                        }
                        
                        // --- Draw color gradient background (rainbow) ---
                        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .indigo, .purple]
                        let grad = Gradient(colors: colors)
                        context.fill(
                            Path(CGRect(x: 0, y:0, width: width, height: height - 30)),
                            with: .linearGradient(
                                grad,
                                startPoint: .zero,
                                endPoint: CGPoint(x: width, y: 0))
                        )
                        
                        // --- Fetch previous spectrum ---
                        let spectrum = converter.previousSpectrum
                        guard !spectrum.isEmpty else { return }
                        
                        // --- Fetch f values
                        let f = converter.original_f
                        guard !f.isEmpty else { return }
                        
                        // --- Compute magnitude in dB ---
                        let magnitudes: [Float] = spectrum.map { c in
                            let mag = sqrt(c.real*c.real + c.imag*c.imag)
                            return mag
                        }
                        
                        let maxMagnitude: Float = magnitudes.max()!
                        let magnitudeDB = magnitudes.map { c in
                            return 20 * log10( c / maxMagnitude )
                        }
                        
                        let maxDB: Float = 0
                        let minDB: Float = -120
                        
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
                        
                        // --- Draw frequency axis ---
                        let axisY = height - 30   // space for labels

                        // Axis baseline
                        var axisPath = Path()
                        axisPath.move(to: CGPoint(x: 0, y: axisY))
                        axisPath.addLine(to: CGPoint(x: width, y: axisY))
                        context.stroke(axisPath, with: .color(axisColor), lineWidth: 1)

                        // Ticks + labels
                        for freq in axisFrequencies {
                            let x = xPosition(for: freq)

                            // Tick
                            var tick = Path()
                            tick.move(to: CGPoint(x: x, y: axisY))
                            tick.addLine(to: CGPoint(x: x, y: axisY + 6))
                            context.stroke(tick, with: .color(textColor), lineWidth: 2)

                            // Label
                            let label: String
                            if freq >= 1000 {
                                label = "\(Int(freq / 1000))k"
                            } else {
                                label = "\(Int(freq))"
                            }

                            let text = Text(label)
                                .font(.caption2)
                                .foregroundColor(textColor)

                            context.draw(
                                text,
                                at: CGPoint(x: x, y: axisY + 14),
                                anchor: .top
                            )
                        }
                    }
                }
            }
            .cornerRadius(8)
            .shadow(radius: 3)
        }
    }
}

#Preview {
    SpectrumView(converter: VideoConverter())
}
