//
//  ContentView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/8/25.
//

import SwiftUI

struct ParameterSlider: View {
    var label: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var isLog: Bool = false
    
    var body: some View {
        VStack {
            Text("\(label): \(value, specifier: "%.2f")")
            Slider(value: Binding(
                get: {
                    isLog ? log10(value) : value
                },
                set: { newVal in
                    value = isLog ? pow(10, newVal) : newVal
                }
            ), in: isLog ? log10(range.lowerBound)...log10(range.upperBound) : range)
        }
    }
}

struct ColorBarView: View {
    @ObservedObject var converter: VideoConverter
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            Canvas { context, size in
                // Draw rainbow gradient
                let grad = Gradient(colors: [.red, .orange, .yellow, .green, .blue, .indigo, .purple])
                context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)),
                             with: .linearGradient(grad, startPoint: .zero, endPoint: CGPoint(x: width, y: 0)))
                
                // Draw HP/LP cutoffs
                let hpX = width * CGFloat(converter.hpCutoff / 20000)
                let lpX = width * CGFloat(converter.lpCutoff / 20000)
                
                let lineStyle = StrokeStyle(lineWidth: 2)
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: hpX, y: 0))
                    p.addLine(to: CGPoint(x: hpX, y: height))
                    p.move(to: CGPoint(x: lpX, y: 0))
                    p.addLine(to: CGPoint(x: lpX, y: height))
                }, with: .color(.black), style: lineStyle)
            }
        }
        .cornerRadius(8)
    }
}

struct ControlPanelView: View {
    @ObservedObject var converter: VideoConverter

    var body: some View {
        VStack {
            // --- Envelope controls ---
            HStack(spacing: 30) {
                ParameterSlider(label: "Attack",
                                value: Binding(
                                    get: { converter.attack },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.attack = newValue
                                        }
                                    }
                                ),
                                range: 0.01...1.0)

                ParameterSlider(label: "Release",
                                value: Binding(
                                    get: { converter.release },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.release = newValue
                                        }
                                    }
                                ),
                                range: 0.01...0.1)
            }
            .padding(.horizontal)

            // --- Filter controls ---
            HStack(spacing: 20) {
                ParameterSlider(label: "HP Cutoff",
                                value: Binding(
                                    get: { converter.hpCutoff },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.hpCutoff = newValue
                                        }
                                    }
                                ),
                                range: 20...20_000)

                ParameterSlider(label: "LP Cutoff",
                                value: Binding(
                                    get: { converter.lpCutoff },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.lpCutoff = newValue
                                        }
                                    }
                                ),
                                range: 20...20_000)

                ParameterSlider(label: "HP Order",
                                value: Binding(
                                    get: { converter.hpOrder },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.hpOrder = newValue
                                        }
                                    }
                                ),
                                range: 1...10)

                ParameterSlider(label: "LP Order",
                                value: Binding(
                                    get: { converter.lpOrder },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.lpOrder = newValue
                                        }
                                    }
                                ),
                                range: 1...10)
            }
            .padding(.horizontal)

            // --- Spectrum controls ---
            HStack(spacing: 20) {
                ParameterSlider(label: "Q Scaling",
                                value: Binding(
                                    get: { converter.Q_scaling },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.Q_scaling = newValue
                                        }
                                    }
                                ),
                                range: 0.01...100)

                ParameterSlider(label: "Spectrum Mixing",
                                value: Binding(
                                    get: { converter.spectrumMixing },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.spectrumMixing = newValue
                                        }
                                    }
                                ),
                                range: 0.01...1.0)

                ParameterSlider(label: "Hanning BW",
                                value: Binding(
                                    get: { converter.Hanning_Window_Multiplier },
                                    set: { newValue in
                                        DispatchQueue.main.async {
                                            converter.Hanning_Window_Multiplier = newValue
                                        }
                                    }
                                ),
                                range: 1...10_000)
            }
            .padding(.horizontal)

            // --- Status bar ---
            Text("Peak: \(converter.lastFrame.map { abs($0) }.max() ?? 0, specifier: "%.3f")")
                .padding()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var converter: VideoConverter
    @StateObject private var camera = CameraModel()
    
    var body: some View {
        VStack(spacing: 20) {
            
            // --- Video preview ---
            CameraPreview(session: camera.session)
                .frame(height: 200)
                .cornerRadius(12)
                .shadow(radius: 5)
            
            // --- Spectrum analyzer & color bar ---
            VStack {
                CameraPreview(session: camera.session)
                    .frame(height: 200)
                    .cornerRadius(12)
                
                ColorBarView(converter: converter)
                    .frame(height: 50)
                
                SpectrumView(converter: converter)
                    .frame(height: 150)
                
                ControlPanelView(converter: converter)
                    .frame(height: 300)
                
            }
            .padding(.horizontal)
            
            .onAppear {
                camera.startSession()
                converter.attachToSession(camera.session)
            }
        }
    }
}
