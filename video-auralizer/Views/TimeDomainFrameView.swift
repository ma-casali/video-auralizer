//
//  TimeDomainFrameView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/16/25.
//


import SwiftUI

struct TimeDomainFrameView: View {
    @ObservedObject var converter: VideoToAudio
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        GeometryReader { geo in
            let N = converter.soundEngine.previousSignal.count
            
            Canvas { context, size in
                guard N > 1 else { return }

                let midY = size.height / 2
                let scaleX = size.width / CGFloat(N - 1)
                let scaleY = midY * 0.8

                var path = Path()

                path.move(to: CGPoint(
                    x: 0,
                    y: midY - CGFloat(converter.soundEngine.previousSignal[0]) * scaleY
                ))

                for i in 1..<N {
                    let x = CGFloat(i) * scaleX
                    let y = midY - CGFloat(converter.soundEngine.previousSignal[i]) * scaleY
                    path.addLine(to: CGPoint(x: x, y: y))
                }

                context.stroke(
                    path,
                    with: .color(.white),
                    style: StrokeStyle(
                        lineWidth: 5,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .background(Color.black.opacity(0.0))
        }
    }
}
