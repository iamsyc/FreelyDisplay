//
//  WebServer.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/14.
//

import Network
import CoreGraphics
import ImageIO

class WebServer{
    var streamConnection:NWConnection?=nil
    var listener:NWListener?
    let displayPage:String
    init(using port:NWEndpoint.Port = .http) throws{
        displayPage=try String(contentsOfFile: Bundle.main.path(forResource: "displayPage", ofType: "html")!, encoding: .utf8)
        do{
            try listener=NWListener(using: .tcp, on: port)
            listener?.newConnectionHandler={connection in
                connection.start(queue: .main)
                connection.stateUpdateHandler={state in
                    if state == .cancelled{
                        connection.cancel()
                    }
                }
                connection.receive(minimumIncompleteLength: 0, maximumLength: 999) { content, contentContext, isComplete, error in
                    if let request = parseHTTPRequest(from: content!) {
                        
                        guard let path=URL(string: request.path) else {return}
                        
                        if path.isRoot{
                            connection.send(content: ("HTTP/1.1 200 OK\r\n\r\n"+self.displayPage).data(using: .utf8), completion: .contentProcessed({error in
                                connection.cancel()
                            }))
                        }else if(path.hasSubDir(in: URL(string: "/stream")!)){
                            self.streamConnection=connection
                            connection.send(content: ("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=nextFrameK9_4657\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n").data(using: .utf8), completion: .contentProcessed({_ in}))
                            Timer.scheduledTimer(withTimeInterval: 1/20, repeats: true){_ in
                                print("gjkgkyug")
                                guard let frame=AppHelper.shared.sharingScreenCaptureStream?.jpgData else{ return }
                                
                                let boundary = "--nextFrameK9_4657\r\n"
                                let contentHeader = "Content-Type: image/jpg\r\n"
                                let contentLength = "Content-Length: \(frame.count)\r\n\r\n"
                                let frameData = Data(boundary.utf8) + Data(contentHeader.utf8) + Data(contentLength.utf8) + frame + Data("\r\n".utf8)
                                connection.send(content: frameData, completion: .contentProcessed({_ in}))
                            }
                        }else{
                            connection.send(content: ("HTTP/1.1 404 OK\r\n\r\n").data(using: .utf8), completion: .contentProcessed({error in
                                connection.cancel()
                            }))
                        }
                    }
                    
                    
                    
                }
            }
        }catch{
            throw error
        }
        
    }
    
    public func startListener(){
        listener?.start(queue: .global())
    }
    
}



