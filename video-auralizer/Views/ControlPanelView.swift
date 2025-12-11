//
//  ControlPanelView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI


struct ControlPanelView: View {
    @ObservedObject var converter: VideoConverter
    
    var body: some View {
        NavigationStack{
            VStack {
                Slider(
                    value: $converter.hpCutoff,
                    in: 20...20000
                )
                Text("HP Cutoff: \(converter.hpCutoff, specifier: "%.0f") Hz")
                
                Slider(
                    value: Binding(
                        get: { 20000 - converter.lpCutoff },
                        set: { converter.lpCutoff = 20000 - $0 }
                    ),
                    in: 20...20000
                )
                .environment(\.layoutDirection, .rightToLeft)
                Text("LP Cutoff: \(converter.lpCutoff, specifier: "%.0f") Hz")
                
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
    ControlPanelView(converter: VideoConverter())
}
