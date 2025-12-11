//
//  XYPad.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//


import SwiftUI

struct XYPad: View {
    @Binding var xValue: CGFloat   // normalized: 0...1
    @Binding var yValue: CGFloat   // normalized: 0...1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                // --- Background grid ---
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .border(Color.gray, width: 2)

                // --- Optional crosshair ---
                Path { p in
                    p.move(to: CGPoint(x: width/2, y: 0))
                    p.addLine(to: CGPoint(x: width/2, y: height))
                    p.move(to: CGPoint(x: 0, y: height/2))
                    p.addLine(to: CGPoint(x: width, y: height/2))
                }
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)

                // --- Draggable circle ---
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                    .position(
                        x: xValue * width,
                        y: (1 - yValue) * height // y goes up
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let x = gesture.location.x
                                let y = gesture.location.y

                                // clamp to inside the pad
                                let clampedX = min(max(x, 0), width)
                                let clampedY = min(max(y, 0), height)

                                // normalize values to 0...1
                                xValue = clampedX / width
                                yValue = 1 - (clampedY / height)
                            }
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding()
    }
}

struct XYPadDemo: View {
    @State private var x: CGFloat = 0.5
    @State private var y: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 30) {
            XYPad(xValue: $x, yValue: $y)
                .frame(width: 300, height: 300)

            // Live feedback
            HStack{
                Text(String(format: "X: %.2f", x))
                Text(String(format: "Y: %.2f", y))
            }
        }
        .padding()
    }
}

#Preview{
    XYPadDemo()
}
