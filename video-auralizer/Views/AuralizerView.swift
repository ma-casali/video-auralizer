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
        VStack(spacing: 20) {
            
            // --- Video preview ---
            CameraPreview(session: camera.session)
                .frame(height: 350)
                .frame(width: screenSize.width*350.0/screenSize.height)
                .cornerRadius(12)
                .shadow(radius: 5)
            
            // --- Spectrum analyzer & color bar ---
            VStack {
                SpectrumView(converter: converter)
                    .frame(height: 150)
                
                ControlPanelView(converter: converter)
                    .frame(height: 100)
            }
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
