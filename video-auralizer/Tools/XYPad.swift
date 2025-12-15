//
//  XYPad.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//


import SwiftUI

struct MorphingWaveLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var pointiness: CGFloat      // 0 → sine, 1 → triangle
    var numZeroCrossings: Int    // number of zero-crossings

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)

        let periods = CGFloat(numZeroCrossings + 1) / 2
        let steps = max(10, Int(periods * 50))   // sampling resolution
        let sineAmplitude = CGFloat(10.0)
        let triAmplitude = CGFloat(20.0)

        path.move(to: start)

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let baseX = t * length

            // Sinc function
            let sinc = -abs(sineAmplitude * sin((t-0.5) * .pi * periods) / ((t-0.5) * .pi * periods))
            
            let Q = 15.0 / (1.0 + 100.0 * (pow(t-0.5, 2.0)))

            // Morph
            let wave =  Q * sinc
            let offset = wave

            // Rotate into line direction
            let x = start.x + baseX * cos(angle) - offset * sin(angle)
            let y = start.y + baseX * sin(angle) + offset * cos(angle)

            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}


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
                    .fill(Color.gray.opacity(0.1 + 0.8*sqrt(pow(xValue,2) + pow(yValue,2))))
                
                MorphingWaveLine(
                    start: CGPoint(x: 0, y: height),
                    end: CGPoint(x: 0, y: 0),
                    pointiness: CGFloat(sqrt(pow(xValue,2) + pow(yValue,2))),
                    numZeroCrossings: 16
                )
                
                MorphingWaveLine(
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: width, y: 0),
                    pointiness: CGFloat(sqrt(pow(xValue,2) + pow(yValue,2))),
                    numZeroCrossings: 16
                )
                
                MorphingWaveLine(
                    start: CGPoint(x: width, y: 0),
                    end: CGPoint(x: width, y: height),
                    pointiness: CGFloat(sqrt(pow(xValue,2) + pow(yValue,2))),
                    numZeroCrossings: 32
                )
                
                MorphingWaveLine(
                    start: CGPoint(x: width, y: height),
                    end: CGPoint(x: 0, y: height),
                    pointiness: CGFloat(sqrt(pow(xValue,2) + pow(yValue,2))),
                    numZeroCrossings: 32
                )

                // --- Draggable circle ---
                Circle()
                    .fill(Color.blue.opacity(0.1 + 0.9*sqrt(pow(xValue,2) + pow(yValue,2))))
                    .frame(width: 12 + 24*sqrt(pow(xValue,2) + pow(yValue,2)),
                           height: 12 + 24*sqrt(pow(xValue,2) + pow(yValue,2)))
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
