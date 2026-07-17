import Foundation
import SynoKit
import Network

struct DiscoveredNAS: Identifiable, Equatable, Sendable {
    let host: String
    let port: Int
    var id: String { "\(host):\(port)" }
}

/// Finds Synology NAS devices on the local LAN. Two passes, both feeding the
/// same verification step (an actual `SYNO.API.Info` HTTPS probe, so a
/// result is never just "something answered," always "this is really DSM"):
///
/// 1. An mDNS/Bonjour fast path (`_http._tcp`, which DSM advertises by
///    default) — near-instant since devices announce themselves instead of
///    being polled, the same mechanism AirDrop/printer discovery use. Purely
///    best-effort: if Bonjour is off in DSM's settings, or the resolve
///    step's brief `NWConnection` doesn't complete in time, this pass just
///    contributes nothing and pass 2 still finds the NAS on its own.
/// 2. A full local /24 sweep (the original approach) as the reliable
///    fallback, since not everything advertises itself.
///
/// Never leaves the local network and never sends credentials.
enum NASDiscoveryService {
    private static let port = 5001
    private static let probeTimeout: TimeInterval = 1.2
    private static let mdnsWindow: TimeInterval = 1.5

    struct ScanProgress: Sendable {
        let checked: Int
        let total: Int
    }

    /// Streams results as they're confirmed (`onDiscovered`) and reports
    /// sweep progress (`onProgress`) so the UI can show a growing list and a
    /// "checked X of Y" indicator instead of a spinner that looks stuck.
    /// Both callbacks are invoked on the main actor.
    static func scan(
        onDiscovered: @escaping @MainActor (DiscoveredNAS) -> Void,
        onProgress: @escaping @MainActor (ScanProgress) -> Void
    ) async {
        var seenHosts = Set<String>()

        for host in await mdnsCandidateHosts() {
            guard !seenHosts.contains(host) else { continue }
            if let discovered = await probe(host: host) {
                seenHosts.insert(host)
                await onDiscovered(discovered)
            }
        }

        guard let (localIP, netmask) = localIPv4AddressAndNetmask() else { return }
        let hosts = candidateHosts(localIP: localIP, netmask: netmask)
        guard !hosts.isEmpty else { return }

        var checked = 0
        await withTaskGroup(of: (String, DiscoveredNAS?).self) { group in
            for host in hosts {
                group.addTask { (host, await probe(host: host)) }
            }
            for await (host, result) in group {
                checked += 1
                await onProgress(ScanProgress(checked: checked, total: hosts.count))
                if let result, !seenHosts.contains(host) {
                    seenHosts.insert(host)
                    await onDiscovered(result)
                }
            }
        }
    }

    /// Browses for `_http._tcp` Bonjour services (DSM's default advertised
    /// service) and briefly attempts to connect to each one just far enough
    /// to learn its resolved IP address — Bonjour results only expose an
    /// opaque service endpoint, not a usable host, until something actually
    /// tries to connect to it. Not NAS-specific by itself (other devices
    /// advertise `_http._tcp` too); the real filtering happens afterward via
    /// the same `probe(host:)` every candidate goes through regardless of
    /// how it was found.
    private static func mdnsCandidateHosts() async -> [String] {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
            let state = MDNSResolutionState()

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    state.beginResolving(result.endpoint)
                }
            }
            browser.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + mdnsWindow) {
                browser.cancel()
                continuation.resume(returning: state.finish())
            }
        }
    }

    private static func probe(host: String) async -> DiscoveredNAS? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        components.path = "/webapi/query.cgi"
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Info"),
            URLQueryItem(name: "method", value: "query"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "query", value: "SYNO.API.Auth"),
        ]
        guard let url = components.url else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        let session = URLSession(configuration: configuration, delegate: InsecureProbeDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(APIInfoResponse.self, from: data),
              response.success,
              let map = response.data,
              map["SYNO.API.Auth"] != nil else {
            return nil
        }
        return DiscoveredNAS(host: host, port: port)
    }

    private static func candidateHosts(localIP: String, netmask: String) -> [String] {
        guard let ipParts = ipv4Components(localIP), let maskParts = ipv4Components(netmask) else { return [] }
        guard maskParts == [255, 255, 255, 0] else { return [] }
        let prefix = "\(ipParts[0]).\(ipParts[1]).\(ipParts[2])"
        return (1...254).compactMap { last -> String? in
            let candidate = "\(prefix).\(last)"
            return candidate == localIP ? nil : candidate
        }
    }

    private static func ipv4Components(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 ? parts : nil
    }

    /// Reads the active Wi-Fi/Ethernet interface's IPv4 address and netmask
    /// via `getifaddrs`, skipping loopback and non-IPv4 interfaces.
    private static func localIPv4AddressAndNetmask() -> (address: String, netmask: String)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = Int32(bitPattern: interface.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let netmaskAddr = interface.pointee.ifa_netmask else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            if let address = ipString(from: addr), let netmask = ipString(from: netmaskAddr) {
                return (address, netmask)
            }
        }
        return nil
    }

    private static func ipString(from sockaddrPtr: UnsafeMutablePointer<sockaddr>) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            sockaddrPtr, socklen_t(sockaddrPtr.pointee.sa_len),
            &hostBuffer, socklen_t(hostBuffer.count),
            nil, 0, NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }
}

/// Owns the in-flight `NWConnection`s used to resolve Bonjour endpoints to
/// IPs, so `mdnsCandidateHosts` can hand off a plain closure to `NWBrowser`
/// without capturing mutable state across threads directly.
private final class MDNSResolutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedHosts = Set<String>()
    private var connections: [NWConnection] = []
    private var finished = false

    func beginResolving(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
                    self.addHost("\(host)")
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        connections.append(connection)
        lock.unlock()
        connection.start(queue: .global(qos: .utility))
    }

    private func addHost(_ host: String) {
        // Strip a `%en0`-style zone-id suffix some link-local addresses carry.
        let cleaned = host.split(separator: "%").first.map(String.init) ?? host
        lock.lock()
        resolvedHosts.insert(cleaned)
        lock.unlock()
    }

    func finish() -> [String] {
        lock.lock()
        finished = true
        let hosts = Array(resolvedHosts)
        let pending = connections
        connections = []
        lock.unlock()
        for connection in pending {
            connection.cancel()
        }
        return hosts
    }
}

/// Used only for the LAN discovery probe above, which sends no credentials
/// and only checks whether a host answers as a DSM API. The actual
/// authenticated session always goes through `CertificateTrustDelegate`'s
/// TOFU pinning instead.
private final class InsecureProbeDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
