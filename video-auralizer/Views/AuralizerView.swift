//
//  ContentView.swift
//  video-Content
//
//  Created by Matthew Casali on 12/8/25.
//

import SwiftUI
import UIKit
import CoreGraphics

extension Image {
    static let converterBackground = Image("ConverterScreen")
}

struct ConverterWallpaper: View {
    var body: some View {
        Image.converterBackground
            .resizable()
            .aspectRatio(contentMode: .fill)
            .ignoresSafeArea()
    }
}

struct DraggableComponent<Content: View>: View {
    let backgroundImage: String
    let content: Content
    let contentSize: CGSize
    let contentOffset: CGFloat
    let clickableHeight: CGFloat
    let clickableOffset: CGFloat
    let minOffset: CGFloat
    let maxOffset: CGFloat
    
    @State private var offset: CGFloat = 0
    @State private var lastOffset: CGFloat = 0
    
    var body: some View {
        ZStack{
            ZStack{
                Image(backgroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                
                content
                    .frame(width: contentSize.width, height: contentSize.height)
                    .offset(y: contentOffset)
            }
            .allowsHitTesting(false)
            
            Color.white.opacity(0.001)
                .frame(height: clickableHeight)
                .offset(y: clickableOffset)
                .clipped()
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newOffset = lastOffset + value.translation.height
                            offset = min(max(newOffset, minOffset), maxOffset)
                        }
                        .onEnded{ _ in lastOffset = offset}
                )
        }
        .offset(y: offset)
       
    }
}


struct AuralizerView: View {
    @EnvironmentObject var converter: VideoToAudio
    @StateObject private var camera = CameraModel()
    
    var body: some View {
        GeometryReader {geometry in
            ZStack {
                Image("ConverterBackground")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                
                ZStack{
                    // Camera Unit (Non-moveable)
                    CameraPreview(session: camera.session)
                        .frame(width: 350, height:350*(16/9))
                        .background(Color.gray)
                        .cornerRadius(8)
                        .offset(y: -180)
                    
                    // Time Signal Unit (Moveable)
                    DraggableComponent(backgroundImage: "ConverterTimeSignal",
                                       content: TimeDomainFrameView(converter: converter),
                                       contentSize: CGSize(width: geometry.size.width, height: geometry.size.height*0.2),
                                       contentOffset: 300 - 800/2.5,
                                       clickableHeight: 860,
                                       clickableOffset: 300,
                                       minOffset: -120,
                                       maxOffset: 250
                    )
                    
                    // Spectrum Unit (Moveable)
                    DraggableComponent(backgroundImage: "ConverterSpectrum",
                                       content: SpectrumView(converter: converter),
                                       contentSize: CGSize(width: geometry.size.width, height: geometry.size.height*0.2),
                                       contentOffset: 300 - 360/4,
                                       clickableHeight: 450,
                                       clickableOffset: 300,
                                       minOffset: -60,
                                       maxOffset: 250
                                       
                    )
                }
            }
            .onAppear {
                camera.startSession()
                converter.visionEngine.attachToSession(camera.session)
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
        .environmentObject(VideoToAudio())
}
