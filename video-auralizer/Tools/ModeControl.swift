//
//  ModeControl.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/24/25.
//

import SwiftUI

struct ModeControl: View {
    @ObservedObject var converter: VideoConverter
    
    var body: some View {
        VStack {
            Text("Mode Control")
                .font(.largeTitle)
                .padding()
            
            Slider(
                value: Binding(
                    get: { CGFloat(converter.breathingMode) },
                    set: { converter.breathingMode = Float($0) }
                ),
                in: -1...1,   // specify the range
                label: { Text("Breathing Mode Emphasis") },
                minimumValueLabel: { Text("-1") },
                maximumValueLabel: { Text("1") }
            )
            .frame(width: 300)
            
            Text(String(format: "Breathing Mode Emphasis: %.2f", converter.breathingMode))
            
            Slider(
                value: Binding(
                    get: { CGFloat(converter.verticalTiltMode) },
                    set: { converter.verticalTiltMode = Float($0) }
                ),
                in: -1...1,   // specify the range
                label: { Text("Vertical Tilt Emphasis") },
                minimumValueLabel: { Text("-1") },
                maximumValueLabel: { Text("1") }
            )
            .frame(width: 300)
            
            Text(String(format: "Vertical Mode Emphasis: %.2f", converter.verticalTiltMode))
            
            Slider(
                value: Binding(
                    get: { CGFloat(converter.horizontalTiltMode) },
                    set: { converter.horizontalTiltMode = Float($0) }
                ),
                in: -1...1,   // specify the range
                label: { Text("Horizontal Tilt Emphasis") },
                minimumValueLabel: { Text("-1") },
                maximumValueLabel: { Text("1") }
            )
            .frame(width: 300)
            
            Text(String(format: "Horizontal Mode Emphasis: %.2f", converter.horizontalTiltMode))
            
            Slider(
                value: Binding(
                    get: { CGFloat(converter.shearMode) },
                    set: { converter.shearMode = Float($0) }
                ),
                in: -1...1,   // specify the range
                label: { Text("Shear Emphasis") },
                minimumValueLabel: { Text("-1") },
                maximumValueLabel: { Text("1") }
            )
            .frame(width: 300)
            
            Text(String(format: "Shear Mode Emphasis: %.2f", converter.shearMode))
        }
    }
}
