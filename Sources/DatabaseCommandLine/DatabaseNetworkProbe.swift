import Darwin
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DatabaseNetworkCheckResult: Sendable, Equatable {
    case passed(String)
    case skipped(String)
    case failed(summary: String, remediation: String)
}

public struct DatabaseNetworkProbeReport: Sendable, Equatable {
    public let dns: DatabaseNetworkCheckResult
    public let tcp: DatabaseNetworkCheckResult
    public let tls: DatabaseNetworkCheckResult

    public init(
        dns: DatabaseNetworkCheckResult,
        tcp: DatabaseNetworkCheckResult,
        tls: DatabaseNetworkCheckResult
    ) {
        self.dns = dns
        self.tcp = tcp
        self.tls = tls
    }
}

public protocol DatabaseNetworkProbing: Sendable {
    func probe(_ endpoint: URL) async -> DatabaseNetworkProbeReport
}

public struct DefaultDatabaseNetworkProbe: DatabaseNetworkProbing {
    public init() {}

    public func probe(_ endpoint: URL) async -> DatabaseNetworkProbeReport {
        guard let target = ProbeTarget(endpoint: endpoint) else {
            return DatabaseNetworkProbeReport(
                dns: .failed(
                    summary: "Endpoint host or port is invalid.",
                    remediation: "Use an HTTP, HTTPS, WS, or WSS endpoint with a host."
                ),
                tcp: .skipped("TCP was not attempted because the endpoint is invalid."),
                tls: .skipped("TLS was not attempted because the endpoint is invalid.")
            )
        }
        let socketResult = await Task.detached(priority: .utility) {
            SocketConnectivityProbe.run(target: target)
        }.value
        switch socketResult {
        case .dnsFailure(let summary):
            return DatabaseNetworkProbeReport(
                dns: .failed(
                    summary: summary,
                    remediation: "Verify the endpoint hostname and DNS configuration."
                ),
                tcp: .skipped("TCP was not attempted because DNS resolution failed."),
                tls: .skipped("TLS was not attempted because DNS resolution failed.")
            )
        case .tcpFailure(let resolvedAddressCount, let summary):
            return DatabaseNetworkProbeReport(
                dns: .passed("Resolved \(resolvedAddressCount) endpoint address(es)."),
                tcp: .failed(
                    summary: summary,
                    remediation: "Verify the listener address, firewall, and server readiness."
                ),
                tls: .skipped("TLS was not attempted because TCP connection failed.")
            )
        case .connected(let resolvedAddressCount):
            let tls = await probeTLS(endpoint, scheme: target.scheme)
            return DatabaseNetworkProbeReport(
                dns: .passed("Resolved \(resolvedAddressCount) endpoint address(es)."),
                tcp: .passed("Connected to \(target.host):\(target.port) over TCP."),
                tls: tls
            )
        }
    }

    private func probeTLS(
        _ endpoint: URL,
        scheme: String
    ) async -> DatabaseNetworkCheckResult {
        guard scheme == "https" || scheme == "wss" else {
            return .skipped("The selected endpoint does not use TLS.")
        }
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            return .failed(
                summary: "The TLS endpoint URL is invalid.",
                remediation: "Verify the configured endpoint URL."
            )
        }
        components.scheme = "https"
        guard let probeURL = components.url else {
            return .failed(
                summary: "The TLS endpoint URL is invalid.",
                remediation: "Verify the configured endpoint URL."
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: probeURL)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else {
                return .failed(
                    summary: "TLS completed without an HTTP response.",
                    remediation: "Verify the TLS listener and endpoint protocol."
                )
            }
            return .passed("TLS certificate validation and handshake succeeded.")
        } catch {
            return .failed(
                summary: "TLS validation failed: \(error)",
                remediation: "Verify the certificate chain, hostname, validity, and trust roots."
            )
        }
    }
}

private struct ProbeTarget: Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(endpoint: URL) {
        guard let scheme = endpoint.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              var host = endpoint.host,
              !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let defaultPort = (scheme == "https" || scheme == "wss") ? 443 : 80
        let port = endpoint.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }
}

private enum SocketProbeResult: Sendable {
    case dnsFailure(String)
    case tcpFailure(resolvedAddressCount: Int, summary: String)
    case connected(resolvedAddressCount: Int)
}

private enum SocketConnectivityProbe {
    static func run(target: ProbeTarget) -> SocketProbeResult {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let resolutionStatus = getaddrinfo(
            target.host,
            String(target.port),
            &hints,
            &result
        )
        guard resolutionStatus == 0, let first = result else {
            let message = String(cString: gai_strerror(resolutionStatus))
            return .dnsFailure("DNS resolution failed: \(message)")
        }
        defer { freeaddrinfo(first) }

        var addressCount = 0
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor, addressCount < 8 {
            addressCount += 1
            defer { cursor = entry.pointee.ai_next }
            let descriptor = Darwin.socket(
                entry.pointee.ai_family,
                entry.pointee.ai_socktype,
                entry.pointee.ai_protocol
            )
            guard descriptor >= 0 else { continue }
            defer { _ = Darwin.close(descriptor) }
            let currentFlags = Darwin.fcntl(descriptor, F_GETFL, 0)
            guard currentFlags >= 0,
                  Darwin.fcntl(
                    descriptor,
                    F_SETFL,
                    currentFlags | O_NONBLOCK
                  ) == 0 else {
                continue
            }
            let status = Darwin.connect(
                descriptor,
                entry.pointee.ai_addr,
                entry.pointee.ai_addrlen
            )
            if status == 0 { return .connected(resolvedAddressCount: addressCount) }
            guard errno == EINPROGRESS else { continue }
            var event = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let pollStatus = Darwin.poll(&event, 1, 1_000)
            guard pollStatus > 0 else { continue }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let optionStatus = withUnsafeMutablePointer(to: &socketError) {
                Darwin.getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    $0,
                    &socketErrorLength
                )
            }
            if optionStatus == 0, socketError == 0 {
                return .connected(resolvedAddressCount: addressCount)
            }
        }
        return .tcpFailure(
            resolvedAddressCount: addressCount,
            summary: "No resolved address accepted a TCP connection."
        )
    }
}
