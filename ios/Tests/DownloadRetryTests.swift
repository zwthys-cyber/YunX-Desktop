// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class DownloadRetryTests: XCTestCase {
    func testRetriesAreBoundedAndNeverReplayAuthenticationFailures() {
        XCTAssertEqual(DownloadRetry.delay(attempt: 0, status: 503), 2)
        XCTAssertEqual(DownloadRetry.delay(attempt: 2, status: 429, retryAfter: "120"), 120)
        XCTAssertEqual(DownloadRetry.delay(attempt: 0, status: 429, retryAfter: "999999"), 300)
        XCTAssertNil(DownloadRetry.delay(attempt: 3, status: 503))
        for status in [400, 401, 403, 404] { XCTAssertNil(DownloadRetry.delay(attempt: 0, status: status)) }
        XCTAssertNil(DownloadRetry.delay(attempt: 0, error: URLError(.cancelled) as NSError))
        XCTAssertNil(DownloadRetry.delay(attempt: 0, error: URLError(.serverCertificateUntrusted) as NSError))
    }
    func testRealURLSession503RetryCompletesWithoutSavingErrorBody() async throws {
        let content = Data(repeating: 0x47, count: 131072)
        let fixture = try NativeHTTPFixture(data: content, failures: 1)
        let url = try await fixture.start()
        defer { fixture.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DownloadStore(root: folder.appendingPathComponent("Downloads"), cache: folder.appendingPathComponent("Support"), configuration: .ephemeral)
        XCTAssertTrue(store.add(url, filename: "fixture.bin", expectedSize: Int64(content.count)))
        let id = try XCTUnwrap(store.items.first?.id)
        defer { store.delete(id) }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, store.items.first?.state != .completed {
            try await Task.sleep(for: .milliseconds(100))
        }
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.retryCount, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(item))), content)
    }
}
