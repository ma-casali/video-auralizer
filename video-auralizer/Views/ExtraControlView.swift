//
//  ExtraControlView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct ExtraControlView: View {
    @ObservedObject var converter: VideoConverter
    @State private var controlQ = true
    
    var body: some View {
        
        ScrollView{
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
                }.padding(10)
            
                Slider(
                    value: Binding(
                        get: { CGFloat(converter.spectrumMixing) },
                        set: { converter.spectrumMixing = Float($0) }
                    ),
                    in: 0...1,   // specify the range
                    label: { Text("Spectrum Mixing") },
                    minimumValueLabel: { Text("0") },
                    maximumValueLabel: { Text("1") }
                )
                .frame(width: 300)
                
                Text(String(format: "Spectrum Mixing: %.2f", converter.spectrumMixing))
                ZStack{
                    // --- Bounding Box ---
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemBackground))      // background fill
                        .shadow(color: .black.opacity(0.3), radius: 5)
                        .frame(width: 360, height: 450)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    ModeControl(converter: converter)
                        .frame(width: 300)
                }
            }
            .padding(.top)
        }
    }
}

#Preview{
    ExtraControlView(converter: VideoConverter())
}
