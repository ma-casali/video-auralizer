//
//  XLine.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct XLine: View {
    @Binding var x1Value: CGFloat    // normalized 0...1
    @Binding var x2Value: CGFloat    // normalized 0...1
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let centerY = geo.size.height / 2
            
            ZStack {

                // --- LEFT BAR (0 → x1) ---
                LinearGradient(
                    colors: [Color.black.opacity(0.2), Color.blue.opacity(1.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: x1Value * width, height: 6)
                .cornerRadius(3)
                .position(
                    x: (x1Value * width) / 2,
                    y: centerY
                )
                .allowsHitTesting(false)

                // --- MIDDLE BAR (x1 → x2) ---
                LinearGradient(
                    colors: [Color.blue.opacity(1.0), Color.black.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: (x2Value - x1Value) * width, height: 6)
                .cornerRadius(3)
                .position(
                    x: (x1Value + (x2Value - x1Value)/2) * width,
                    y: centerY
                )
                .allowsHitTesting(false)
                
                // --- RIGHT BAR (x2 -> 1)
                LinearGradient(
                    colors: [Color.black.opacity(0.2), Color.black.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: (1 - x2Value) * width, height: 6)
                .cornerRadius(3)
                .position(
                    x: x2Value * width/2 + width/2,
                    y: centerY
                )
                .allowsHitTesting(false)
                
                // --- Dashed Circle (x2) ---
                Circle()
                    .fill(Color.white.opacity(1.0))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [4]))
                    .frame(width: 24, height: 24)
                    .position(x: x2Value * width, y: centerY)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let clamped = min(max(gesture.location.x, x1Value * width), x1Value*width + width/2)
                                x2Value = clamped / width
                            }
                    )
                
                // --- BLUE CIRCLE (x1) ---
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                    .position(x: x1Value * width, y: centerY)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let maxClamp = min(width/2, x2Value * width)
                                let clamped = min(max(gesture.location.x, 0), maxClamp)
                                x1Value = clamped / width
                            }
                    )
            }
        }
        .frame(height: 60)
    }
}



struct XLineDemo: View {
    @State private var x1: CGFloat = 0.0
    @State private var x2: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 30) {
            XLine(x1Value: $x1, x2Value: $x2)
                .frame(width: 300, height: 300)

            // Live feedback
            HStack{
                Text(String(format: "Attack: %.2f", x1))
                Text(String(format: "Release: %.2f", (x2 - x1)))
            }
        }
        .padding()
    }
}

#Preview {
    XLineDemo()
}
