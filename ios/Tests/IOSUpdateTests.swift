// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class UpdateRequests: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func received() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@MainActor
final class IOSUpdateTests: XCTestCase {
    nonisolated private static func release(_ version: String, body: String = "", digest: String = "sha256:" + String(repeating: "a", count: 64), url: String? = nil) -> [String: Any] {
        ["tag_name": "ios-v" + version, "draft": false, "prerelease": false, "body": body, "assets": [["name": "YunX-iOS17-TrollStore.ipa", "state": "uploaded", "size": 1024, "digest": digest, "browser_download_url": url ?? "https://github.com/zwthys-cyber/YunX-Desktop/releases/download/ios-v\(version)/YunX-iOS17-TrollStore.ipa"]]]
    }
    private func releases(_ objects: [[String: Any]]) throws -> [IOSRelease] { try JSONDecoder().decode([IOSRelease].self, from: JSONSerialization.data(withJSONObject: objects)) }
    func testSemanticVersionOrderingAndIOSOnlyReleaseSelection() throws {
        XCTAssertLessThan(try XCTUnwrap(IOSVersion("1.9.9")), try XCTUnwrap(IOSVersion("1.10.0")))
        XCTAssertNil(IOSVersion("01.2.3")); XCTAssertNil(IOSVersion("1.2.3-beta")); XCTAssertNil(IOSVersion("9999999.0.0"))
        var desktop = Self.release("9.0.0"); desktop["tag_name"] = "v9.0.0"
        var beta = Self.release("9.0.0"); beta["prerelease"] = true
        let update = try IOSUpdate.select(releases([desktop, beta, Self.release("0.4.0"), Self.release("0.3.1")]), current: XCTUnwrap(IOSVersion("0.3.0")), system: XCTUnwrap(IOSVersion("17.0.0")))
        XCTAssertEqual(update?.version.description, "0.4.0"); XCTAssertEqual(update?.sha256, String(repeating: "a", count: 64))
    }
    func testUnverifiedForeignAndIncompatiblePackagesAreRejected() throws {
        let current = IOSVersion("0.3.0")!, system = IOSVersion("17.0.0")!
        for object in [Self.release("0.4.0", digest: "missing"), Self.release("0.4.0", url: "https://github.com.evil.test/file.ipa"), Self.release("0.4.0", url: "https://github.com/another/repository/releases/download/ios-v0.4.0/YunX-iOS17-TrollStore.ipa"), Self.release("0.4.0", body: "<!-- yunx-ios-min-os: 18.0 -->"), Self.release("0.4.0", body: "<!-- yunx-ios-min-os: invalid -->")] {
            XCTAssertThrowsError(try IOSUpdate.select(releases([object]), current: current, system: system))
        }
    }
    func testAutomaticCheckIsOptInThrottledAndNeverSendsAccountHeaders() async throws {
        let suite = "IOSUpdateTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date(), forKey: "lastIOSUpdateCheck")
        let requests = UpdateRequests()
        MediaMockProtocol.handler = { request in
            requests.received()
            XCTAssertEqual(request.url?.host, "api.github.com"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, [:], [Self.release("999999.0.0")])
        }
        defer { MediaMockProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]; config.httpCookieStorage = nil
        let store = IOSUpdateStore(client: IOSUpdateClient(session: URLSession(configuration: config)), defaults: defaults)
        await store.check(automatic: true); XCTAssertEqual(requests.total, 0)
        store.automatic = true
        await store.check(automatic: true); XCTAssertEqual(requests.total, 0)
        await store.check(); XCTAssertEqual(requests.total, 1); XCTAssertNotNil(store.latest)
        store.ignore(); XCTAssertNil(store.prompt); XCTAssertEqual(defaults.string(forKey: "ignoredIOSUpdate"), "999999.0.0")
    }
}
