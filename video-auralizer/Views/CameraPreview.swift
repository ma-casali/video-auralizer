//
//  CameraPreview.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()

        guard let session else {
            view.backgroundColor = .gray
            let label = UILabel()
            label.text = "Camera Not Accessible"
            label.textAlignment = .center
            label.textColor = .white
            label.frame = view.bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
            return view
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds

        context.coordinator.previewLayer = previewLayer
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
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


#Preview{
    CameraPreview(session: nil)
}
