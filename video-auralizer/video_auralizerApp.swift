//
//  video_auralizerApp.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/8/25.
//

import SwiftUI

@main
struct MyApp: App {
    // Initialize VideoConverter for the entire app lifetime
    @StateObject private var converter = VideoConverter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(converter)
        }
    }
}
