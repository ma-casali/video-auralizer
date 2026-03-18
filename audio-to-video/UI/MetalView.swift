// MetalView.swift
// controls MTKView, which is the view that renders the Metal content
// controls the overlay, which is the view that displays the audio visualizer

import SwiftUI
import MetalKit

struct MetalView: UIViewRepresentable {
    // This will eventually be your C++ Engine's bridge
    // let renderer: EngineBridge

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.device = MTLCreateSystemDefaultDevice()
        
        // Important for video synthesis:
        mtkView.framebufferOnly = false
        mtkView.drawableSize = mtkView.frame.size
        
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            <#code#>
        }
        
        var parent: MetalView
        var bridge: EngineBridge

        init(_ parent: MetalView) {
            self.parent = parent
            // Initialize the bridge with the system's default GPU
            self.bridge = EngineBridge(device: MTLCreateSystemDefaultDevice()!)
            super.init()
            
            self.bridge.startProcessing()
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            
            // 1. Get the texture synthesized by C++/Metal
            let synthesizedTexture = bridge.getLatestFrame()
            
            // 2. Create a command buffer to present it to the screen
            let commandBuffer = view.device?.makeCommandQueue()?.makeCommandBuffer()
            
            // (Simplified logic: You would typically use a BlitEncoder
            // to copy synthesizedTexture to drawable.texture)
            
            commandBuffer?.present(drawable)
            commandBuffer?.commit()
        }
    }
}
