//
//  ContentView.swift
//  video-Content
//
//  Created by Matthew Casali on 12/8/25.
//

import SwiftUI
import UIKit
import CoreGraphics

struct AuralizerView: View {
    @EnvironmentObject var converter: VideoConverter
    @StateObject private var camera = CameraModel()
    
    @State private var screenSize: CGSize = .zero
    
    var body: some View {
        NavigationStack {
            
            // --- Video preview ---
            CameraPreview(session: camera.session)
                .frame(height: 350)
                .frame(width: screenSize.width*350.0/screenSize.height)
                .cornerRadius(12)
                .shadow(radius: 5)
            
            TimeDomainFrameView(converter: converter)
                .frame(height: 150)
                .padding(.horizontal, 10)
            
            // --- Spectrum analyzer & color bar ---
            ZStack {
                SpectrumView(converter: converter)
                    .frame(height: 150)
                    .clipped()
                    .padding(.horizontal, 10)
                
                FilterTool(x1Value: Binding(
                            get: {CGFloat(log2(converter.hpCutoff/20.0)/log2(20_000.0/20.0))},
                            set: {converter.hpCutoff = 20.0 * pow(2, Float($0) * log2(20_000.0/20.0))}
                            ),
                           y1Value: Binding(
                            get: {CGFloat(converter.hpOrder/10.0)} ,
                            set: {converter.hpOrder = Float($0)*10.0}
                            ),
                           x2Value: Binding(
                            get: {CGFloat(log2(converter.lpCutoff/20.0)/log2(20_000.0/20.0))},
                            set: {converter.lpCutoff = 20.0 * pow(2, Float($0) * log2(20_000.0/20.0))}
                            ),
                           y2Value: Binding(
                            get: {CGFloat(converter.lpOrder/10.0)} ,
                            set: {converter.lpOrder = Float($0)*10.0}
                            )
                    )
                .padding(.horizontal, 10)
                .allowsHitTesting(true)
                .contentShape(Rectangle())
                .frame(height: 120)
                .position(CGPoint(x: screenSize.width / 2, y: 60))
            }
            .frame(height: 150)
            .background(
                        WindowReader { window in
                            let size = window.windowScene?.screen.bounds.size ?? .zero
                            self.screenSize = size
                        }
                        .allowsHitTesting(false)
                    )
            .onAppear {
                camera.startSession()
                converter.attachToSession(camera.session)
            }
            VStack{
                Text(String(format: "High-Pass Cutoff: %.2f with Order: %.2f", converter.hpCutoff, converter.hpOrder))
                Text(String(format: "Low-Pass Cutoff: %.2f with Order: %.2f", converter.lpCutoff, converter.lpOrder))
            }
            
            NavigationLink(destination: ExtraControlView(converter: converter)){
                Text("More Controls")
                .foregroundColor(.blue)
                .padding()
                .background(Color.white)
                .cornerRadius(8)
            }

        }
    }
}

struct WindowReader: UIViewRepresentable {
    var onUpdate: (UIWindow) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let window = uiView.window {
                onUpdate(window)
            }
        }
    }
}

#Preview{
    AuralizerView()
        .environmentObject(VideoConverter())
}
