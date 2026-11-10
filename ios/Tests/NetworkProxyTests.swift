// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class NetworkProxyTests: XCTestCase {
    func testEndpointAndAuthenticationValidation() throws {
        var profile = NetworkProxyProfile(); profile.mode = .manual
        for host in ["https://proxy.test", "proxy.test:8080", "user@proxy.test", "proxy.test/path", "a\r\nb"] {
            profile.host = host
            XCTAssertThrowsError(try profile.validated())
        }
        profile.host = "[::1]"
        XCTAssertEqual(try profile.validated().host, "::1")
        profile.host = "proxy.test"; profile.username = "user"; profile.password = "p:@/word"
        let value = try profile.runtime(for: URL(string: "https://origin.invalid")!)
        XCTAssertEqual(value["password"] as? String, profile.password)
        profile.username = "user:injected"
        XCTAssertThrowsError(try profile.validated())
        profile.username = "user"; profile.password = "secret\r\nHeader: bad"
        XCTAssertThrowsError(try profile.validated())
        profile.password = String(repeating: "a", count: 256); profile.scheme = .socks5
        XCTAssertThrowsError(try profile.validated())
    }
    func testKeychainRoundTripAndReplacement() throws {
        let service = "io.github.zwthys.yunx.test-proxy.\(UUID().uuidString)"
        defer { NetworkProxyKeychain.remove(service: service) }
        XCTAssertEqual(try NetworkProxyKeychain.read(service: service).mode, .system)
        var profile = NetworkProxyProfile(); profile.mode = .manual; profile.host = "proxy.invalid"
        profile.username = "fixture"; profile.password = "fixture:@/secret"
        try NetworkProxyKeychain.save(profile, service: service)
        XCTAssertEqual(try NetworkProxyKeychain.read(service: service), profile)
        profile.password = "replacement"
        try NetworkProxyKeychain.save(profile, service: service)
        XCTAssertEqual(try NetworkProxyKeychain.read(service: service), profile)
    }
    func testManualNetworkingCannotEnterSystemBackgroundSession() {
        XCTAssertFalse(BackgroundDownloadPolicy.allows(URL(string: "https://origin.invalid/file")!, headers: [:], systemNetworking: false))
        XCTAssertEqual(NetworkProxy.runtimeJSON(for: "https://user:password@origin.invalid", fixed: NetworkProxyProfile()), #"{"error":true}"#)
    }
}
