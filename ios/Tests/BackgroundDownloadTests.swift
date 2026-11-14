// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class BackgroundDownloadTests: XCTestCase {
    func testCredentialRequestsCannotEnterAutomaticRedirectBackgroundSession() throws {
        let url = URL(string: "https://cdn.example.test/file.bin")!
        XCTAssertTrue(BackgroundDownloadPolicy.allows(url, headers: [:]))
        XCTAssertTrue(BackgroundDownloadPolicy.allows(url, headers: ["User-Agent": "fixture", "Referer": "https://example.test/"]))
        for key in ["Cookie", "Authorization", "authorization", "Proxy-Authorization", "X-API-Key", "X-Token"] {
            XCTAssertFalse(BackgroundDownloadPolicy.allows(url, headers: [key: "test-only-secret"]))
        }
        XCTAssertFalse(BackgroundDownloadPolicy.allows(URL(string: "http://cdn.example.test/file")!, headers: [:]))
        XCTAssertFalse(BackgroundDownloadPolicy.allows(URL(string: "https://user:password@cdn.example.test/file")!, headers: [:]))
    }
    func testBackgroundCompletionHandlersRunAfterEventsAndOnlyOnce() async {
        let registry = BackgroundCompletionRegistry()
        let first = expectation(description: "first completion")
        let second = expectation(description: "second completion")
        var calls = 0
        registry.register { calls += 1; first.fulfill() }
        registry.register { calls += 1; second.fulfill() }
        XCTAssertEqual(calls, 0)
        registry.finished()
        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertEqual(calls, 2)
        registry.finished()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(calls, 2)
    }
    func testRejectedTransferReportsHTTPStatusAndPersistsForegroundOnly() async throws {
        let fixture = try NativeHTTPFixture(data: Data(repeating: 0x41, count: 10), requiredHeader: "X-Fixture-Required: missing")
        let url = try await fixture.start()
        defer { fixture.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(root: root.appendingPathComponent("Downloads"), cache: root.appendingPathComponent("Support"), configuration: .ephemeral)
        XCTAssertTrue(store.add(url, filename: "fixture.bin", expectedSize: 10, allowsBackground: false))
        let id = try XCTUnwrap(store.items.first?.id)
        defer { store.delete(id) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, store.items.first?.state != .failed { try await Task.sleep(for: .milliseconds(50)) }
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.error?.contains("HTTP 401") == true)
        XCTAssertEqual(item.foregroundOnly, true)
        XCTAssertEqual(item.backgroundTransfer, false)
        XCTAssertNil(store.fileURL(item))
        let restored = DownloadStore(root: root.appendingPathComponent("Downloads"), cache: root.appendingPathComponent("Support"), configuration: .ephemeral)
        XCTAssertEqual(restored.items.first?.foregroundOnly, true)
    }
}
