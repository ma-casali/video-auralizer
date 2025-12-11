//
//  VisualizePeak.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/11/25.
//

import SwiftUI

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
    var beamWidth: CGFloat

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
            let sinc = amplitude * (abs( sin((t-0.5) * .pi * beamWidth) / ((t-0.5) * .pi * beamWidth) ) - abs(sin(0.5 * .pi * beamWidth) / (0.5 * .pi * beamWidth)))
            
            // Rotate into line direction
            let x = start.x + baseX * cos(angle) - sinc * sin(angle)
            let y = start.y + baseX * sin(angle) + sinc * cos(angle)
            
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        return path
    }
}

struct CombinedLine: Shape {
    var start: CGPoint
    var end: CGPoint
    var amplitude: CGFloat
    var beamWidth: CGFloat
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
            let sinc =  abs( sin((t-0.5) * .pi * beamWidth) / ((t-0.5) * .pi * beamWidth))
            
            // Q function
            let Q = (1.0 / (1.0 + (pow(Q * (t-0.5), 2.0))) - 1.0 / (1.0 + pow(Q, 2.0) * 0.25)) / (1.0 - (1.0/(1.0 + pow(Q, 2.0)/4.0)))
            
            let combinedLine = amplitude * sinc * Q
            
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

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            // Line colors depend ONLY on the toggle state
            let QColor: Color = controlQ ? .blue.opacity(1.0) : .blue.opacity(0.2)
            let HColor: Color = controlQ ? .red.opacity(0.2)  : .red.opacity(1.0)

            
            ZStack {

                // BLUE — Q-LINE
                QLine(
                    start: CGPoint(x: width, y: height / 2),
                    end:   CGPoint(x: 0,     y: height / 2),
                    amplitude: height / 2,
                    Q: qValue
                )
                .stroke(QColor, style: StrokeStyle(lineWidth: 2))


                // RED — HANNING LINE
                HanningLine(
                    start: CGPoint(x: width, y: height / 2),
                    end:   CGPoint(x: 0,     y: height / 2),
                    amplitude: height / 2,
                    beamWidth: hValue
                )
                .stroke(HColor, style: StrokeStyle(lineWidth: 2))
                
                // PURPLE - COMBINED LINE
                CombinedLine(
                    start: CGPoint(x: width, y: height / 2),
                    end: CGPoint(x: 0, y: height / 2),
                    amplitude: height / 2,
                    beamWidth: hValue,
                    Q: qValue
                )
                .stroke(Color.purple.opacity(1.0), style: StrokeStyle(lineWidth: 5))


            }
            .contentShape(Rectangle())   // drag anywhere
            .gesture(
                DragGesture().onChanged { value in
                    let x = min(max(value.location.x, 0), width)
                    dragX = x / width
                    let dist = abs(dragX - 0.5) * 2.0

                    if controlQ {
                        // -------------------------
                        // CONTROL THE Q CURVE (BLUE)
                        // -------------------------
                        let minQ: CGFloat = 0.01
                        let maxQ: CGFloat = 100.0
                        qValue = maxQ - (maxQ - minQ) * log10(1 + 9.0 * dist)
                    } else {
                        // -------------------------
                        // CONTROL THE HANNING CURVE (RED)
                        // -------------------------
                        let minH: CGFloat = 0.1
                        let maxH: CGFloat = 20.0
                        hValue = minH + (maxH - minH) * dist
                    }
                }
            )
        }
    }
}



struct PeakDemo: View {
    @State private var q: CGFloat = 0.5
    @State private var h: CGFloat = 0.5
    @State private var controlQ = true

    var body: some View {
        VStack(spacing: 30) {

            ControlModeSwitch(controlQ: $controlQ)

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
