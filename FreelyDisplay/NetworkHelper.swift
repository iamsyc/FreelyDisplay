//
//  NetworkHelper.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/11/8.
//

import Foundation
import SystemConfiguration

func getWiFiIPAddress() -> String? {
var address: String?
var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil

guard getifaddrs(&ifaddr) == 0 else { return nil }
guard let firstAddr = ifaddr else { return nil }

for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
let interface = ifptr.pointee
let addrFamily = interface.ifa_addr.pointee.sa_family

if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
let name = String(cString: interface.ifa_name)
if name == "en0" { // en0 通常表示 WiFi 接口
var addr = interface.ifa_addr.pointee
var hostName = [CChar](repeating: 0, count: Int(NI_MAXHOST))
getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostName, socklen_t(hostName.count), nil, socklen_t(0), NI_NUMERICHOST)
address = String(cString: hostName)
}
}
}

freeifaddrs(ifaddr)
return address
}
