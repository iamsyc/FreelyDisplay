//
//  FreelyDisplayApp.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Combine
import ScreenCaptureKit
import Network

//var sceneCapture:SceneCapture?
@main
struct FreelyDisplayApp: App {
//    @StateObject var captureOutput=Capture()
    
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(AppHelper.shared)
                
                .id(AppHelper.shared.id)
//                .onAppear{
//                    Task{
//                        let content = try? await SCShareableContent.excludingDesktopWindows(
//                            false,
//                            onScreenWindowsOnly: true
//                        )
//                        guard let displays = content?.displays else { return }
//                        sceneCapture=await SceneCapture(display: displays.first!, output: captureOutput)
//                    }
//                }
        }
        
        WindowGroup(for: Int.self){$index in
            @Environment(\.dismiss) var dismiss
            let caputure=Capture()
            if let index = index{
                if AppHelper.shared.screenCaptureObjects.count > index{
                    CaptureDisplayView(index: index)
                        .navigationTitle("Screen Monitoring")
                        .environmentObject(caputure)
                        .environmentObject(AppHelper.shared)
                }else{Group{}.onAppear{
                    dismiss()
                }}
            }
            
                
        }
        
        
        
        
    }
    
}

class AppHelper:ObservableObject{
    @Published var displays:[CGVirtualDisplay]=[]
    static var shared=AppHelper()
    @Published var id=UUID()
    @Published var screenCaptureObjects:[SCStream?]=[]
    @Published var sharingScreenCaptureObject:SCStream?=nil
    @Published var sharingScreenCaptureStream:Capture?=nil
    @Published var isSharing=false
    let webServer=try? WebServer(using: 8081)
    init() {
        webServer?.startListener()
    }
}


