import Darwin
import Foundation
import SystemConfiguration

/// Addresses other computers on the local network can use to reach this Mac.
public enum NetworkAddresses {
    /// IPv4 addresses of active, non-loopback interfaces (Wi-Fi, Ethernet), private ranges first.
    public static func lanIPv4() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }   // skip VPN tunnels, bridges, AWDL
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result.sorted { isPrivate($0) && !isPrivate($1) }
    }

    /// The Bonjour name, e.g. `holgers-macbook.local`, which survives a changing IP address.
    public static func bonjourName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return "\(name).local"
    }

    static func isPrivate(_ ip: String) -> Bool {
        ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".")[1]) ?? 0))
    }
}
