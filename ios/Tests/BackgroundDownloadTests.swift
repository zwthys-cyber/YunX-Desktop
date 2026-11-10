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
}
