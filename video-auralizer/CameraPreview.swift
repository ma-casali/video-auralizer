//
//  CameraPreview.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//

import SwiftUI
import AVFoundation
import Combine

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()

        // Create and store the preview layer
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds

        // Store reference in the coordinator
        context.coordinator.previewLayer = previewLayer

        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Resize camera layer to match SwiftUI layout
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = view.bounds
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

class CameraModel: NSObject, ObservableObject {
    @Published var isRunning: Bool = false
    let session = AVCaptureSession()

    func startSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }

        session.addInput(input)
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
}
