//
//  FilterTool.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct FilterTool: View {
    @Binding var x1Value: CGFloat   // normalized: 0...1
    @Binding var y1Value: CGFloat   // normalized: 0...1
    
    @Binding var x2Value: CGFloat   // normalized: 0...1
    @Binding var y2Value: CGFloat   // normalized: 0...1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            let hpPosition = CGPoint(
                x: x1Value * width,
                y: (1 - y1Value) * height
            )
            
            let lpPosition = CGPoint(
                x: x2Value * width,
                y: (1 - y2Value) * height
            )

            ZStack {

                // --- High Pass Order ---
                Path { p in
                    
                    let x1 = x1Value
                    let y1 = 1.0 - y1Value
                    
                    let xSlope: CGFloat = abs(1.0 - y1) < 0.001 ? -1e6 : (0.0 - y1) / (1.0 - y1)
                    let ySlope: CGFloat = abs(0.0 - y1) < 0.001 ? -1e6 : (1.0 - y1) / (0.0 - y1)

                    p.move(to: CGPoint(
                        x: max(0.0, xSlope * (1.0 - y1) + x1) * width,
                        y: min(1.0, ySlope * (0.0 - x1) + y1) * height
                    ))
                    p.addLine(to: hpPosition)
                }
                .stroke(Color.black, lineWidth: 2)
                
                // --- Low Pass Order ---
                Path { p in
                    
                    let x1 = x2Value
                    let y1 = 1.0 - y2Value
                    
                    let xSlope: CGFloat = abs(1.0 - y1) < 0.001 ? -1e6 : (0.0 - y1) / (1.0 - y1)
                    let ySlope: CGFloat = abs(0.0 - y1) < 0.001 ? -1e6 : (1.0 - y1) / (0.0 - y1)

                    p.move(to: CGPoint(
                        x: min(1.0, -xSlope * (1.0 - y1) + x1) * width,
                        y: min(1.0, -ySlope * (1.0 - x1) + y1) * height
                    ))
                    p.addLine(to: lpPosition)
                }
                .stroke(Color.black, lineWidth: 2)
                
                // Connection
                Path { p in
                    p.move(to: lpPosition)
                    p.addLine(to: hpPosition)
                }
                .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 6]))

                // --- High Pass Cutoff ---
                Circle()
                    .stroke(Color.black, lineWidth: 2)
                    .frame(width: 24,
                           height: 24)
                    .position(
                        x: x1Value * width,
                        y: (1 - y1Value) * height // y goes up
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let x = gesture.location.x
                                let y = gesture.location.y

                                // clamp to inside the pad
                                let clampedX = min(max(x, 0), x2Value*width)
                                let clampedY = min(max(y, 0), height)

                                // normalize values to 0...1
                                x1Value = clampedX / width
                                y1Value = 1 - (clampedY / height)
 
                            }
                    )
                
                // --- Low Pass Cutoff ---
                Circle()
                    .stroke(Color.black, lineWidth: 2)
                    .frame(width: 24,
                           height: 24)
                    .position(
                        x: x2Value * width,
                        y: (1 - y2Value) * height // y goes up
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let x = gesture.location.x
                                let y = gesture.location.y

                                // clamp to inside the pad
                                let clampedX = min(max(x, x1Value*width), width)
                                let clampedY = min(max(y, 0), height)

                                // normalize values to 0...1
                                x2Value = clampedX / width
                                y2Value = 1 - (clampedY / height)
 
                            }
                    )
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
    }
}

struct FilterToolDemo: View {
    @State private var x1: CGFloat = 0.5
    @State private var y1: CGFloat = 0.5
    @State private var x2: CGFloat = 0.5
    @State private var y2: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 30) {
            FilterTool(x1Value: $x1, y1Value: $y1,
                       x2Value: $x2, y2Value: $y2
            )
                .frame(width: 300, height: 300)

            // Live feedback
            VStack{
                Text(String(format: "High-Pass Cutoff: %.2f with Order: %.2f", x1, y1))
                Text(String(format: "Low-Pass Cutoff: %.2f with Order: %.2f", x2, y2))
            }
        }
        .padding()
    }
}

#Preview{
    FilterToolDemo()
}
