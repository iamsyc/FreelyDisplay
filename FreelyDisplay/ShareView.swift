//
//  shareView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/16.
//

import SwiftUI
import ScreenCaptureKit
import Network

struct ShareView: View {
    @EnvironmentObject var appHelper:AppHelper
    @State var displays:[SCDisplay]?
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow
    var body: some View {
        if !appHelper.isSharing{
            Group{
                if let displays=displays{
                    List(displays,id:\.self){display in
                        HStack{
                            Image(systemName: "display")
                                .font(.system(size: 40))
                            VStack(alignment: .leading,spacing:5){
                                VStack(alignment: .leading){
                                    
                                    if #available(macOS 26.0, *) {
                                        Text(NSScreen.screens.filter({item in
                                            item.cgDirectDisplayID==display.displayID
                                        }).first?.localizedName ?? "Monitor")
                                            .font(.headline)
    //                                    Text(display.description)
    //                                        .font(.callout)
                                    }else{
                                        Text("Monitor")
                                            .font(.headline)
    //                                    Text(display.description)
    //                                        .font(.headline)
                                    }
                                    
                                        
                                    Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
                                        .font(.subheadline)
                                }
                                if !appHelper.displays.filter({item in
                                    item.displayID==display.displayID
                                }).isEmpty{
                                    Text("Virtual Display")
                                        .font(.caption)
                                        .padding(3)
                                        .padding(.horizontal,5)
                                        .background(.gray.opacity(0.2),in: .capsule)
                                }else{
                                    Text("Physical Display or other Virtual Display")
                                        .font(.caption)
                                        .padding(3)
                                        .padding(.horizontal,5)
                                        .background(.gray.opacity(0.2),in: .capsule)
                                }
                            }
                            .padding(.bottom,5)
                            Spacer()
                            Button("Sharing",action:{
                                Task{
                                    
                                    let screenCapture=await creatScreenCapture(display: display)
                                    
                                    let stream=Capture()
                                    appHelper.sharingScreenCaptureStream=stream
                                    appHelper.sharingScreenCaptureObject=screenCapture
                                    try? screenCapture.addStreamOutput(stream, type: .screen, sampleHandlerQueue: .main)
                                    try? await appHelper.sharingScreenCaptureObject?.startCapture()
                                    appHelper.isSharing=true
                                }
                            })
                        }
                    }
                    .safeAreaInset(edge: .bottom, content: {
                        VStack{
                            if #available(macOS 26.0, *) {}else{
                            Text("The system is lower than macOS 26 and cannot display the monitor name. Replaced with 'Monitor'.")
                                .font(.footnote)
                            }
                            Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                                .font(.footnote)
                        }
//                        .padding()
                        .padding(3)
                    })
                }else{
                    Text("No screen to share")
                }
                
            }
            .onAppear{
                Task{
                    let content = try? await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: false)
                    guard let displays = content?.displays else { return }
                    self.displays=displays
                }
            }
        }else{
            VStack(spacing:20){
                Text("Sharing in progress")
                    .font(.largeTitle)
                HStack{
                    Button("Stop sharing"){
                        appHelper.sharingScreenCaptureObject?.stopCapture()
                        appHelper.isSharing=false
                    }
                    .foregroundStyle(.red)
//                    .buttonStyle(.bordered)
                    Button("Open the page"){
//                        print(getWiFiIPAddress())
//                        openURL(URL(string: "\(getWiFiIPAddress()):\(appHelper.webServer?.listener?.port)")!)
                        guard let ip=getWiFiIPAddress(),let port=appHelper.webServer?.listener?.port else {return}
                        openURL(URL(string:"http://\(ip):\(port)")!)
                    }
                }
                    
            }
        }
            
    }
}

#Preview {
    ShareView()
}
