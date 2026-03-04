//
//  ControlPanelView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI


struct ControlPanelView: View {
    @ObservedObject var converter: VideoToAudio
    
    var body: some View {
        NavigationStack{
            VStack {
                Slider(
                    value: $converter.soundEngine.hpCutoff,
                    in: 20...20000
                )
                Text("HP Cutoff: \(converter.soundEngine.hpCutoff, specifier: "%.0f") Hz")
                
                Slider(
                    value: Binding(
                        get: { 20000 - converter.soundEngine.lpCutoff },
                        set: { converter.soundEngine.lpCutoff = 20000 - $0 }
                    ),
                    in: 20...20000
                )
                .environment(\.layoutDirection, .rightToLeft)
                Text("LP Cutoff: \(converter.soundEngine.lpCutoff, specifier: "%.0f") Hz")
                
                NavigationLink(destination: ExtraControlView(converter: converter)){
                    Text("More Controls")
                    .foregroundColor(.blue)
                    .padding()
                    .cornerRadius(8)
                }
            }
            .padding(.top)
        }
    }
}

#Preview{
    ControlPanelView(converter: VideoToAudio())
}
