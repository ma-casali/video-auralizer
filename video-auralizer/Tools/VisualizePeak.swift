//
//  VisualizePeak.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/11/25.
//

import SwiftUI

func sinc(x: CGFloat) -> CGFloat {
    return sin(x * .pi) / (x * .pi)
}

struct QLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var amplitude: CGFloat
    var Q: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)
        
        let steps = 1000
        
        path.move(to: start)
        
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let baseX = t * length

            let Q = amplitude * (1.0 / (1.0 + (pow(Q * (t-0.5), 2.0))) - 1.0 / (1.0 + pow(Q, 2.0) * 0.25)) / (1.0 - (1.0/(1.0 + pow(Q, 2.0)/4.0)))

            // Rotate into line direction
            let x = start.x + baseX * cos(angle) - Q * sin(angle)
            let y = start.y + baseX * sin(angle) + Q * cos(angle)

            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

struct HanningLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var amplitude: CGFloat
    var T: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let steps = 1000
        
        path.move(to: start)
        
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let baseX = t * length
            
            // Sinc function
            let H = amplitude * abs((T / 2.0 * sinc(x: (t - 0.5) * T) - (T / 4.0) * (sinc(x: (t - 0.5) * T-1) + sinc(x: (t - 0.5) * T + 1))) / (T / 2.0  - T / 4.0 * (sinc(x: -1.0) + sinc(x: 1.0))) )
            
            // Rotate into line direction
            let x = start.x + baseX * cos(angle) - H * sin(angle)
            let y = start.y + baseX * sin(angle) + H * cos(angle)
            
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        return path
    }
}

struct CombinedLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var amplitude: CGFloat
    var T: CGFloat
    var Q: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let steps = 1000
        
        path.move(to: start)
        
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps+1)
            let baseX = t * length
            
            // Sinc function
            let H = abs((T / 2.0 * sinc(x: (t - 0.5) * T) - (T / 4.0) * (sinc(x: (t - 0.5) * T-1) + sinc(x: (t - 0.5) * T + 1))) / (T / 2.0  - T / 4.0 * (sinc(x: -1.0) + sinc(x: 1.0))) )
            
            // Q function
            let Q = (1.0 / (1.0 + (pow(Q * (t-0.5), 2.0))) - 1.0 / (1.0 + pow(Q, 2.0) * 0.25)) / (1.0 - (1.0/(1.0 + pow(Q, 2.0)/4.0)))
            
            let combinedLine = amplitude * H * Q
            
            // Rotate into line direction
            let x = start.x + baseX * cos(angle) - combinedLine * sin(angle)
            let y = start.y + baseX * sin(angle) + combinedLine * cos(angle)
            
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        return path
    }
}

struct ControlModeSwitch: View {
    @Binding var controlQ: Bool    // true = Q, false = Hanning
    
    var body: some View {
        HStack(spacing: 0) {

            // LEFT SIDE — CONTROL Q
            Text("Control Q")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(controlQ ? Color.blue : Color.clear)
                .foregroundColor(controlQ ? .white : .blue)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        controlQ = true
                    }
                }

            // RIGHT SIDE — CONTROL HANNING
            Text("Control Hanning")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(!controlQ ? Color.red : Color.clear)
                .foregroundColor(!controlQ ? .white : .red)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        controlQ = false
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal)
    }
}

struct VisualizePeak: View {
    @Binding var qValue: CGFloat
    @Binding var hValue: CGFloat
    @Binding var controlQ: Bool
    
    @State private var dragX: CGFloat = 0.5
    @State private var printHValue: CGFloat = 1.0
    
    let graphScale: CGFloat = 7.0 / 8.0
    let amplitudeScale: CGFloat = 0.70

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            let QColor: Color = controlQ ? .blue.opacity(1.0) : .blue.opacity(0.2)
            let HColor: Color = controlQ ? .red.opacity(0.2)  : .red.opacity(1.0)
            
            ZStack {

                // --- Outer bounding box ---
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.3), radius: 5)
                    .frame(width: 320, height: height * 1.4)
                    .position(x: width/2, y: (height * 1.2) / 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )

                VStack(spacing: 12) {

                    // ====== MODE SWITCH ======
                    ControlModeSwitch(controlQ: $controlQ)
                        .frame(width: 300, height: 30)
                        .padding(.top, 8)

                    // ====== GRAPH ======
                    ZStack {

                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.5))
                            .frame(width: width, height: height * graphScale)

                        // Center line
                        Path { p in
                            p.move(
                                to: CGPoint(
                                    x: width / 2,
                                    y: height * graphScale * (1.0 - (amplitudeScale*1/4 + 0.75))
                                )
                            )
                            p.addLine(to: CGPoint(x: width / 2, y: height * graphScale))
                        }
                        .stroke(Color.black.opacity(0.6),
                                style: StrokeStyle(lineWidth: 2, dash: [4,4]))

                        // Black combined line
                        CombinedLine(
                            start: CGPoint(x: width, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            end: CGPoint(x: 0, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            amplitude: height * graphScale * amplitudeScale,
                            T: hValue,
                            Q: qValue
                        )
                        .stroke(Color.black.opacity(1.0),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

                        // Blue Q line
                        QLine(
                            start: CGPoint(x: width, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            end: CGPoint(x: 0, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            amplitude: height * graphScale * amplitudeScale,
                            Q: qValue
                        )
                        .stroke(QColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Red Hanning line
                        HanningLine(
                            start: CGPoint(x: width, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            end: CGPoint(x: 0, y: height * graphScale * (amplitudeScale/2 + 0.5)),
                            amplitude: height * graphScale * amplitudeScale,
                            T: hValue
                        )
                        .stroke(HColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        // Outer color highlight
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(controlQ ? Color.blue : Color.red,
                                    style: StrokeStyle(lineWidth: 5))
                            .frame(width: width, height: height * graphScale)

                        // Center frequency label
                        Text("center frequency")
                            .font(.subheadline)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.5))
                                    .shadow(radius: 2)
                            )
                            .foregroundColor(.black)
                            .position(
                                x: width / 2,
                                y: height * graphScale * (1.0 - (amplitudeScale*1/4 + 0.75))
                            )
                    }
                    .gesture(
                        DragGesture().onChanged { value in
                            let x = min(max(value.location.x, 0), width)
                            dragX = x / width
                            let dx = 0.10
                            let dist = max(dx/(0.5 - dx), abs((-(dragX - (0.5 - dx)) + dx)/(0.5 - dx))) - dx/(0.5 - dx)

                            if controlQ {
                                let minQ: CGFloat = 0.01
                                let maxQ: CGFloat = 100
                                qValue = maxQ - (maxQ - minQ) * log10(1 + 9 * dist)
                            } else {
                                let minH: CGFloat = 1
                                let maxH: CGFloat = 20
                                hValue = minH + (maxH - minH) * (pow(10.0, log10(2.0)*(1.0 - dist)) - 1)
                                printHValue = ((hValue-1.0)/(20.0-1.0)*(10_000.0-1.0) + 1.0)
                            }
                        }
                    )
                    // ====== LIVE FEEDBACK BOX ======
                    VStack(spacing: 4) {
                        Text(String(format: "Hanning Multiplier: %.2f", printHValue))
                        Text(String(format: "Q Scaling Factor: %.2f", qValue))
                    }
                    .font(.footnote)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.8))
                            .shadow(radius: 1)
                    )
                }
            }
        }
    }
}




struct PeakDemo: View {
    @State private var q: CGFloat = 0.5
    @State private var h: CGFloat = 0.5
    @State private var controlQ = true

    var body: some View {
        VStack(spacing: 30) {

            

            VisualizePeak(
                qValue: $q,
                hValue: $h,
                controlQ: $controlQ
            )
            .frame(width: 300, height: 300)
        }
    }
}



#Preview{
    PeakDemo()
}
