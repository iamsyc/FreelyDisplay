//
//  ContentView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationSplitView{
            List{
                Section("Monitor"){
                    NavigationLink(destination: {DisplaysView().navigationTitle("Screen")}, label: {Label("Screen", systemImage: "display")})
                    NavigationLink(destination: {VirtualDisplayView().navigationTitle("Virtual Display")}, label: {Label("Virtual Display", systemImage: "display.2")})
                    NavigationLink(destination: {IsCapturing().navigationTitle("Monitor Screen")}, label: {Label("Monitor Screen", systemImage: "dot.scope.display")})
                }
                Section("Sharing"){
                    NavigationLink(destination: {ShareView().navigationTitle("Screen Sharing")}, label: {Label("Screen Sharing", systemImage: "display")})
                    
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 160,max: 190)
        }detail: {
            Text("")
        }
        
    }
}

#Preview {
    HomeView()
}
