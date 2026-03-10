//
//  ContentView.swift
//  video-Content
//
//  Created by Matthew Casali on 12/8/25.
//

import SwiftUI
import UIKit
import CoreGraphics

struct ImageShape: Shape {
    let uiImage: UIImage
    let threshold: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let cgImage = uiImage.cgImage else { return path }
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Calculate the scale factor to match contentMode .fill
        let horizontalScale = rect.width / CGFloat(width)
        let verticalScale = rect.height / CGFloat(height)
        let scale = max(horizontalScale, verticalScale)
        
        // Center the scaled image within the rect (SwiftUI's default alignment)
        let newWidth = CGFloat(width) * scale
        let newHeight = CGFloat(height) * scale
        let xOffset = (rect.width - newWidth) / 2
        let yOffset = (rect.height - newHeight) / 2
        
        // Performance optimization: Step through pixels (don't check every single one)
        let step = 16
        
        guard let pixelData = cgImage.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else { return path }

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let pixelIndex = (width * y + x) * 4
                let alpha = CGFloat(data[pixelIndex + 3]) / 255.0
                
                if alpha > threshold {
                    let rectX = xOffset + CGFloat(x) * scale
                    let rectY = yOffset + CGFloat(y) * scale
                    path.addRect(CGRect(x: rectX, y: rectY,
                                        width: CGFloat(step) * scale,
                                        height: CGFloat(step) * scale))
                }
            }
        }
        return path
    }
}


struct FolderComponent<Content: View>: View {
    let backgroundImage: String
    let content: Content
    let contentSize: CGSize
    let contentOffset: CGFloat
    let contentDescription: String?
    let popupDescription: String?
    let textPosition: CGFloat
    
    let bottomSnapPoint: CGFloat

    @Binding public var isAtBottom: Bool
    @State private var offset: CGFloat = 0
    
    var isInteractionDisabled: Bool = false
    
    var body: some View {
        GeometryReader{ geometry in
            ZStack{
                ZStack{
                    Image(backgroundImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .ignoresSafeArea()
                    
                        content
                            .frame(width: contentSize.width, height: contentSize.height)
//                            .border(.white, width: 4) // debug
                            .offset(y: contentOffset)
                    
                    Text(contentDescription!)
                        .foregroundColor(.black)
                        .padding()
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.trailing)
                        .background(.white.opacity(0.75))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: textPosition)
                        .padding(.horizontal)
                }
                .allowsHitTesting(false)
                
                if let uiImage = UIImage(named: backgroundImage) {
                    ImageShape(uiImage: uiImage, threshold: 0.1)
                        .fill(Color.clear) // Use clear so it's invisible
                        .contentShape(ImageShape(uiImage: uiImage, threshold: 0.1))
                        .ignoresSafeArea()
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                        offset = isAtBottom ? 0 : bottomSnapPoint
                                        isAtBottom.toggle()
                                    }
                                }
                        )
                        .allowsHitTesting(!isInteractionDisabled)
                }
            }
            .offset(y: offset)
        }
    }
}


struct AuralizerView: View {
    @EnvironmentObject var converter: VideoToAudio
    @StateObject private var camera = CameraModel()
    
    // New States to track positions
    @State private var signalIsBottom = false
    @State private var spectrumIsBottom = false
    
    var body: some View {
        GeometryReader {geometry in
            ZStack(alignment: .center) {
                
                Image("ConverterCameraBackground")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                
                // Camera Unit (Non-moveable)
                CameraPreview(session: camera.session)
                    .frame(width: 350, height:350*(16/9))
                    .background(Color.gray)
                    .cornerRadius(8)
                    .offset(y: -100)
                
                ZStack{
                    
                    // Time Signal Unit (Moveable)
                    FolderComponent(backgroundImage: "ConverterSignalBackground",
                                    content: TimeDomainFrameView(converter: converter),
                                    contentSize: CGSize(width: geometry.size.width, height: geometry.size.height*0.4),
                                    contentOffset: geometry.size.height*0.15,
                                    contentDescription: String("Audio Waveform"),
                                    popupDescription: String("This is the audio waveform displayed in real-time. It is generated from the spectrum shown on this page and represents what you are hearing."),
                                    textPosition: -geometry.size.height*0.25,
                                    bottomSnapPoint: geometry.size.height * 0.5,
                                    isAtBottom: $signalIsBottom,
                                    isInteractionDisabled: (spectrumIsBottom == false)
                    )
                    
                    // Spectrum Unit (Moveable)
                    FolderComponent(backgroundImage: "ConverterSpectrumBackground",
                                    content: SpectrumView(converter: converter),
                                    contentSize: CGSize(width: geometry.size.width, height: geometry.size.height*0.4),
                                    contentOffset: geometry.size.height/2 - geometry.size.height*0.2,
                                    contentDescription: String("Audio Spectrum"),
                                    popupDescription: String("This is the audio frequency spectrum displayed on a logarithmic frqeuency axis in real-time. It represents the different frequencies present in the audio you are hearing."),
                                    textPosition: geometry.size.height*0.0,
                                    bottomSnapPoint: geometry.size.height/2 * 0.75,
                                    isAtBottom: $spectrumIsBottom,
                                    isInteractionDisabled: (signalIsBottom == true)
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
