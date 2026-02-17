//
//  TutorialStart.swift
//  video-auralizer
//
//  Created by Matthew Casali on 1/26/26.
//

import SwiftUI
import UIKit
import CoreGraphics
import Combine

struct TutorialSlider: View {
    let label: String
    @Binding var value: Double
    let gradient: Gradient
    let height: CGFloat
    let width: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).bold()
            ZStack {
                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(width: width, height: height)
                    .cornerRadius(8)
                Slider(value: $value, in: 0...1)
                    .accentColor(.clear)
                    .frame(width: width, height: height)
            }
        }
    }
}

struct TutorialView: View {
    @ObservedObject var converter: VideoConverter
    @State private var screenSize: CGSize = .zero
    @State private var isPlaying: Bool = false
    
    @State private var h: Double = 0.0 // hue
    @State private var s: Double = 1.0 // saturation
    @State private var b: Double = 1.0 // brightness
    
    
    // Timer to simulate 30fps video frames
    let timer = Timer.publish(every: 1/30, on: .main, in: .common).autoconnect()
    
    var body: some View {
        GeometryReader { geometry in
            let screenSize = geometry.size
            let isLandscape = screenSize.width > screenSize.height
            
            VStack(spacing: screenSize.height * 0.02) {
                // --- Fake Video Preview ---
                ZStack{
                    Rectangle()
                        .fill(Color(hue: h, saturation: s, brightness: b))
                        .frame(height: screenSize.height * 0.5)
                        .frame(width: screenSize.width * 0.5)
                        .cornerRadius(12)
                        .shadow(radius: 5)
                    
                    // Hue Slider to change color (and thus frequency)
                    VStack(spacing: screenSize.height * 0.015) {
                        TutorialSlider(
                            label: "",
                            value: $h,
                            gradient: Gradient(colors: (0...10).map { Color(hue: Double($0)/10.0, saturation: s, brightness: b) }),
                            height: screenSize.height * 0.05,
                            width: screenSize.width * 0.5
                        )
                        
                        TutorialSlider(
                            label: "",
                            value: $s,
                            gradient: Gradient(colors: [Color(hue: h, saturation: 0.0, brightness: b), Color(hue: h, saturation: 1.0, brightness: b)]),
                            height: screenSize.height * 0.05,
                            width: screenSize.width * 0.5
                        )
                        
                        TutorialSlider(
                            label: "",
                            value: $b,
                            gradient: Gradient(colors: [Color(hue: h, saturation: s, brightness: 0.0), Color(hue: h, saturation: s, brightness: 1.0)]),
                            height: screenSize.height * 0.05,
                            width: screenSize.width * 0.5
                        )
                    }
                }
                .padding(.horizontal)

                TimeDomainFrameView(converter: converter)
                    .frame(height: screenSize.height * 0.10)
                
                SpectrumView(converter: converter)
                    .frame(height: screenSize.height * 0.20)
                    .frame(width: screenSize.width*0.9)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(10)
                
                Button(isPlaying ? "Stop Audio" : "Start Audio") {
                    isPlaying.toggle()
                }
                .padding()
                .background(isPlaying ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .onReceive(timer) { _ in
                guard isPlaying else { return }
                
                // 1. Create color from current hue
                let color = UIColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1.0)
                
                // 2. Generate the fake pixel buffer (using the helper we moved into the class)
                if let buffer = createColorBuffer(color: color, width: 640, height: 480) {
                    // 3. Inject it into the pipeline
                    converter.spectrumMixing = 0.90
                    converter.hpCutoff = 0.0
                    converter.lpCutoff = 20_000.0
                    converter.Hanning_Window_Multiplier = 1.0
                    converter.Q_scaling = 1.0
                    converter.attack = 1.0
                    converter.release = 1.0
                    
                    converter.breathingMode = 0.0
                    converter.shearMode = 0.0
                    converter.horizontalTiltMode = 0.0
                    converter.verticalTiltMode = 0.0
                    
                    converter.processManualBuffer(buffer)
                }
            }
            .background(
                WindowReader { window in
                    self.screenSize = window.windowScene?.screen.bounds.size ?? .zero
                }
            )
        }
    }
}

#Preview{
    TutorialView(converter: VideoConverter())
}
