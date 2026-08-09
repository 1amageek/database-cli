import Darwin
import Foundation
import Testing
@testable import DatabaseCommandLine

@Suite("Database network probe", .serialized)
struct DatabaseNetworkProbeTests {
    @Test("DNS and TCP are probed independently and plaintext skips TLS")
    func loopbackConnectivityStages() async throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NetworkProbeTestError.socketCreation }
        var listenerIsOpen = true
        defer {
            if listenerIsOpen { _ = Darwin.close(listener) }
        }
        var reuse: Int32 = 1
        guard Darwin.setsockopt(
            listener,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw NetworkProbeTestError.socketConfiguration
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0, Darwin.listen(listener, 1) == 0 else {
            throw NetworkProbeTestError.socketConfiguration
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &boundLength)
            }
        }
        guard nameStatus == 0 else {
            throw NetworkProbeTestError.socketConfiguration
        }
        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        let endpoint = try #require(
            URL(string: "http://127.0.0.1:\(port)/v1/database")
        )
        let probe = DefaultDatabaseNetworkProbe()

        let reachable = await probe.probe(endpoint)
        guard case .passed = reachable.dns,
              case .passed = reachable.tcp,
              case .skipped = reachable.tls else {
            Issue.record("Expected a reachable plaintext endpoint")
            return
        }

        _ = Darwin.close(listener)
        listenerIsOpen = false
        let unavailable = await probe.probe(endpoint)
        guard case .passed = unavailable.dns,
              case .failed = unavailable.tcp,
              case .skipped = unavailable.tls else {
            Issue.record("Expected a typed TCP failure after listener shutdown")
            return
        }
    }
}

private enum NetworkProbeTestError: Error {
    case socketCreation
    case socketConfiguration
}
