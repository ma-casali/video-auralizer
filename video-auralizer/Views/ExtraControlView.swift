//
//  ExtraControlView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct ExtraControlView: View {
    @ObservedObject var converter: VideoToAudio
    @State private var controlQ = true
    
    var body: some View {
        
        ScrollView{
            VStack {
                XLine(x1Value: Binding(
                    get: {CGFloat(converter.soundEngine.attack*0.5)},
                    set: {converter.soundEngine.attack = Float($0)/0.5}
                ),
                      x2Value: Binding(
                        get: {CGFloat(converter.soundEngine.attack*0.5 + converter.soundEngine.release*0.5)},
                        set: {converter.soundEngine.release = (Float($0) - converter.soundEngine.attack*0.5)/0.5}
                      )
                ).padding(.horizontal, 40)
                
                // Live feedback
                HStack{
                    Text(String(format: "Attack: %.2f", converter.soundEngine.attack))
                    Text(String(format: "Release: %.2f", converter.soundEngine.release))
                }.padding(10)
            
                Slider(
                    value: Binding(
                        get: { CGFloat(converter.soundEngine.spectrumMixing) },
                        set: { converter.soundEngine.spectrumMixing = Float($0) }
                    ),
                    in: 0...1,   // specify the range
                    label: { Text("Spectrum Mixing") },
                    minimumValueLabel: { Text("0") },
                    maximumValueLabel: { Text("1") }
                )
                .frame(width: 300)
                
                Text(String(format: "Spectrum Mixing: %.2f", converter.soundEngine.spectrumMixing))
                
            }
            .padding(.top)
        }
    }
}

#Preview{
    ExtraControlView(converter: VideoToAudio())
}
