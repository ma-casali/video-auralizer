//
//  TimeDomainFrameView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/16/25.
//


import SwiftUI

struct TimeDomainFrameView: View {
    @ObservedObject var converter: VideoConverter
    @Environment(\.colorScheme) var colorScheme
    
    var waveFormColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        GeometryReader { geo in
            let N = converter.previousSignal.count
            
            Canvas { context, size in
                guard N > 1 else { return }

                let midY = size.height / 2
                let scaleX = size.width / CGFloat(N - 1)
                let scaleY = midY

                var path = Path()

                path.move(to: CGPoint(
                    x: 0,
                    y: midY - CGFloat(converter.previousSignal[0]) * scaleY
                ))

                for i in 1..<N {
                    let x = CGFloat(i) * scaleX
                    let y = midY - CGFloat(converter.previousSignal[i]) * scaleY
                    path.addLine(to: CGPoint(x: x, y: y))
                }

                context.stroke(
                    path,
                    with: .color(waveFormColor),
                    lineWidth: 1.5
                )
            }
            .background(Color.black.opacity(0.0))
        }
    }
}
