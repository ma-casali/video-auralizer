//
//  HomeView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct HomeView: View {

    var body: some View {
        NavigationStack{
            VStack{
                Text("Welcome to Video Auralizer!")
                    .font(.largeTitle)
                    .bold()
                    .padding()
                    .multilineTextAlignment(.center)
                
                NavigationLink(destination: AuralizerView().environmentObject(VideoConverter()) ){
                    Text("Begin Auralization")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(8)
                }
            }
        }
    }
}

#Preview {
    HomeView()
}


