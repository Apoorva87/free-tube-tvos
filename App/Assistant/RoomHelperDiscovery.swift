import Darwin
import Foundation
import Network

/// Resolve the address once through Bonjour. HTTP requests use the validated numeric address.
@MainActor final class RoomHelperDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private var found: [String: URL] = [:]
    var changed: (([String: URL], String?) -> Void)?
    var isBrowsing: Bool { browser != nil }

    func start() {
        stop()
        let search = NetServiceBrowser()
        browser = search
        search.delegate = self
        search.searchForServices(ofType: "_freetube-ai._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in resolving.values {
            service.delegate = nil
            service.stop()
        }
        resolving.removeAll()
        found.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let dot = CharacterSet(charactersIn: ".")
        guard browser === self.browser, service.domain.lowercased().trimmingCharacters(in: dot) == "local",
              service.type.lowercased().trimmingCharacters(in: dot) == "_freetube-ai._tcp",
              resolving[service.name] == nil else { return }
        resolving[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender === resolving[sender.name], (1...65535).contains(sender.port) else { return }
        let hosts = (sender.addresses ?? []).compactMap(Self.numericHost)
        // Prefer IPv4 when the helper is reachable on both address families.
        guard let host = hosts.first(where: { !$0.contains(":") }) ?? hosts.first else { return }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = sender.port
        guard let url = parts.url else { return }
        found[sender.name] = url
        changed?(found, nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let removed = resolving.removeValue(forKey: service.name)
        removed?.delegate = nil
        removed?.stop()
        found.removeValue(forKey: service.name)
        changed?(found, nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        stop()
        changed?([:], "Apple TV could not search the local network. Check Wi-Fi or Ethernet and try again.")
    }

    nonisolated static func isLANHost(_ host: String) -> Bool {
        if let address = IPv4Address(host) {
            let octets = Array(address.rawValue)
            return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        let plain = String(host.prefix { $0 != "%" })
        guard let address = IPv6Address(plain) else { return false }
        let octets = Array(address.rawValue)
        return octets[0] & 0xfe == 0xfc || (octets[0] == 0xfe && octets[1] & 0xc0 == 0x80)
    }

    nonisolated private static func numericHost(_ data: Data) -> String? {
        var storage = sockaddr_storage()
        guard data.count >= MemoryLayout<sockaddr>.size, data.count <= MemoryLayout<sockaddr_storage>.size else { return nil }
        _ = withUnsafeMutableBytes(of: &storage) { data.copyBytes(to: $0) }
        let length = socklen_t(data.count)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return nil }
        let host = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return isLANHost(host) ? host : nil
    }
}
