// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class GitHubMirrorTests: XCTestCase {
    func testPrivateOrSignedDownloadsNeverReachMirrors() throws {
        let prefix = "https://mirror.invalid/"
        for url in ["https://api.github.com/repos/a/b/releases/assets/1", "https://github.com/a/b/releases/download/v1/file?token=secret", "https://evil.invalid/a", "https://user:pass@raw.githubusercontent.com/a/b/main/file"] {
            let original = URL(string: url)!
            let plan = try GitHubMirrorPolicy.plan(CloudDownload(url: original, filename: "file", size: 1, headers: [:]), prefix: prefix)
            XCTAssertEqual(plan.url, original); XCTAssertNil(plan.origin)
        }
        let original = URL(string: "https://raw.githubusercontent.com/a/b/main/file")!
        let plan = try GitHubMirrorPolicy.plan(CloudDownload(url: original, filename: "file", size: 1, headers: ["Authorization": "Bearer fixture"]), prefix: prefix)
        XCTAssertEqual(plan.url, original); XCTAssertNil(plan.origin)
    }
    func testPublicRoutingAndFallbackPersistAcrossRestart() throws {
        let original = URL(string: "https://github.com/a/b/releases/download/v1/file.zip")!
        let plan = try GitHubMirrorPolicy.plan(CloudDownload(url: original, filename: "file.zip", size: 42, headers: [:]), prefix: "https://mirror.invalid/prefix")
        XCTAssertEqual(plan.url.absoluteString, "https://mirror.invalid/prefix/" + original.absoluteString)
        XCTAssertEqual(plan.origin, original)
        var item = DownloadItem(id: UUID(), url: plan.url, filename: "file.zip", state: .paused)
        item.originFallback = plan.origin
        let restored = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.originFallback, original)
        XCTAssertEqual(restored.url, plan.url)
        for prefix in ["http://mirror.invalid", "https://user:pass@mirror.invalid", "https://mirror.invalid/?key=secret", "https://mirror.invalid:8080/"] {
            XCTAssertThrowsError(try GitHubMirrorPolicy.prefix(prefix))
        }
    }
}
