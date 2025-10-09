//
//  CaptureDisplayView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import CoreImage

struct CaptureDisplayView: View {
//    @State var screenCapture:SceneCapture?=nil
    @State var index:Int
    @State var cgImage:CGImage?
    @EnvironmentObject var captureOut:Capture
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appHelper:AppHelper
    var body: some View {
        Group{
            if let image=cgImage{
                Image(decorative: image, scale: 1.0)
                    .resizable()
//                    .aspectRatio(contentMode: .fit)
                    .scaledToFit()
            }else{
                Text("No Data")
            }
            
        }
        .onAppear{
                Task{
//                    let content = try? await SCShareableContent.excludingDesktopWindows(
//                        false,
//                                                onScreenWindowsOnly: false
//                                            )
//                    guard let displays = content?.displays else { return }
//                    screenCapture=await SceneCapture(display: display, output: captureOut,width: display.width*2,height: display.height*2)
//                    screenCapture?.start()
                    
                }
            }
            .onChange(of: captureOut.surface){
                guard let surface=captureOut.surface else{ return }
                let ciImage = CIImage(cvPixelBuffer: surface)
                let context=CIContext()
                cgImage=context.createCGImage(ciImage, from: ciImage.extent)
            }
            .onChange(of: appHelper.screenCaptureObjects){oldObject,newObject in
                if newObject[index]==nil{
                    dismiss()
                }
                    
                
            }
            .onDisappear{
//                screenCapture?.stop()
                guard let screenCaptureObject=appHelper.screenCaptureObjects[index] else {return}
                screenCaptureObject.stopCapture()
                appHelper.screenCaptureObjects[index]=nil
                
            }
            .onAppear{
                guard let screenCaptureObject=appHelper.screenCaptureObjects[index] else {return}
                try? screenCaptureObject.addStreamOutput(captureOut, type: .screen, sampleHandlerQueue: .main)
                screenCaptureObject.startCapture()
                
            }
            .background(.black)
    }
}

//#Preview {
////    CaaptureDisplayView()
//}

