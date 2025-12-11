//
//  ExtraControlView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct ExtraControlView: View {
    @ObservedObject var converter: VideoConverter
    
    var body: some View {
            VStack {
                XLine(x1Value: Binding(
                    get: {CGFloat(converter.attack*0.5)},
                    set: {converter.attack = Float($0)/0.5}
                ),
                      x2Value: Binding(
                        get: {CGFloat(converter.attack*0.5 + converter.release*0.5)},
                        set: {converter.release = (Float($0) - converter.attack*0.5)/0.5}
                    )
                ).padding(.horizontal, 40)
                
                // Live feedback
                HStack{
                    Text(String(format: "Attack: %.2f", converter.attack))
                    Text(String(format: "Release: %.2f", converter.release))
                }
            }
            .padding(.top)
        }
}

#Preview{
    ExtraControlView(converter: VideoConverter())
}
