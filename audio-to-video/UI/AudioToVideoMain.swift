// AudioToVideoMain.swift
// main entry point of the application, controls the app lifecycle and permissions

import SwiftUI
import AVFoundation

@main
struct AudioToVideoMain: App {
    @State private var isAuthorized = false

    var body: some Scene {
        WindowGroup {
            if isAuthorized {
                MetalView()
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView {
                    Label("Microphone Access Required", systemImage: "mic.fill")
                } description: {
                    Text("This app requires microphone access to perform real-time beamforming and spatial visualization.")
                } actions: {
                    Button("Grant Permission") {
                        requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    func requestPermissions() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                self.isAuthorized = granted
            }
            
            if !granted {
                // Direct the user to Settings if they previously denied access
                if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsUrl)
                }
            }
        }
    }
}
