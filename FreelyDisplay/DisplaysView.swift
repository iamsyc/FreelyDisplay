//
//  DisplayView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa

struct DisplaysView: View {
    @State private var displays:[NSScreen]?
    @Environment(\.openWindow) var openWindow
    @Environment(\.openURL) var openURL
    var body: some View {
        Group{
            if let displays=displays{
                if !displays.isEmpty{
                    List(displays,id: \.self){display in
                        HStack(alignment:.center){
                            Image(systemName: "display")
                                .font(.system(size: 30))
                            VStack(alignment: .leading){
                                Text(display.localizedName)
    //                                .font(.title3)
                                    .font(.headline)
                                Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
                                    .font(.subheadline)
                                
                            }
                            Spacer()
                            HStack{
                                
                            }
                        }
                    }
                }else{Text("No display")}
            }else {Text("No display")}
           
        }
        .safeAreaInset(edge: .bottom, content: {
            HStack{
                Text("Please [go to the settings app](\(String("x-apple.systempreferences:com.apple.preference.displays"))) to adjust the monitor settings.")
                    .font(.footnote)
                
            }
            .padding(3)
        })
        .toolbar{
//            ToolbarItem(placement: .automatic, content: {
//                Button("Reflash", systemImage: "arrow.trianglehead.clockwise",action: {displays=NSScreen.screens})
//            })
        }
        .onAppear{
            displays=NSScreen.screens
            
        }
    }
        
}

#Preview {
    DisplaysView()
}
