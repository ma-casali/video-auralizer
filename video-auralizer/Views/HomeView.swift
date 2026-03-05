//
//  HomeView.swift
//  video-auralizer
//
//  Created by Matthew Casali on 12/10/25.
//

import SwiftUI

struct UIColors {
    var uiBlue = Color(red: 55.0/255.0, green: 125.0/255.0, blue: 188.0/255.0)
    var uiYellow = Color(red: 226.0/255.0, green: 201.0/255.0, blue: 50.0/255.0)
    var uiOrange = Color(red: 226.0/255.0, green: 83.0/255.0, blue: 50.0/255.0)
    var uiMagenta = Color(red: 199.0/255.0, green: 58.0/255.0, blue: 119.0/255.0)
}

extension Image {
    static let homeBackground = Image("HomePageBackground")
}

struct BackgroundView: View {
    var body: some View {
        Image.homeBackground
            .resizable()
            .aspectRatio(contentMode: .fill)
            .ignoresSafeArea()
    }
}

struct HomeView: View {
//    @EnvironmentObject var converter: VideoConverter
    @EnvironmentObject var converter: VideoToAudio

    var body: some View {
        GeometryReader { geometry in
            NavigationStack{
                ZStack {
                    BackgroundView()
                    
                    VStack{
                        Spacer()
                            .frame(height: geometry.size.height*0.2)
                        
                        Text("Welcome to Vaudio!")
                            .foregroundColor(.black)
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        
                        Spacer()
                            .frame(height: geometry.size.height*0.2)
                        
                        NavigationLink(destination: AuralizerView() ){
                            Text("Transform Video to Audio")
                                .foregroundColor(.white)
                                .padding()
                                .font(.system(size: 24, weight: .regular, design: .rounded))
                                .background(UIColors.init().uiBlue)
                                .cornerRadius(8)
                        }
                        
                        Spacer()
                        
                        NavigationLink(destination: ConvolutionDebugView(converter: converter) ){
                            Text("Look Behind the Scenes")
                                .foregroundColor(.white)
                                .padding()
                                .font(.system(size: 20, weight: .regular, design: .rounded))
                                .background(UIColors.init().uiMagenta)
                                .cornerRadius(8)
                        }
                        
                        Spacer()
                            .frame(height: geometry.size.height*0.1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }
}

#Preview {
    HomeView().environmentObject(VideoToAudio())
}


