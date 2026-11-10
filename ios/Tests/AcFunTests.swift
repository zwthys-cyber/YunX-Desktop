// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class AcFunTests: XCTestCase {
    private func client() -> MediaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageMockProtocol.self]
        return MediaClient(session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    func testNestedPlaybackJSONKeepsActualHLSVariantsAndNoCDNCookie() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "www.acfun.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-cookie")
            let play: [String: Any] = ["adaptationSet": [["representation": [
                ["url": "https://cdn.example.test/high.m3u8", "qualityLabel": "1080P"],
                ["url": "https://cdn.example.test/low.m3u8", "qualityLabel": "720P"]
            ]]]]
            let nested = String(decoding: try JSONSerialization.data(withJSONObject: play), as: UTF8.self)
            let info: [String: Any] = ["title": "AcFun \"测试\"", "user": ["name": "作者"], "currentVideoInfo": ["ksPlayJson": nested]]
            let html = "<script>window.videoInfo=" + String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self) + ";</script>"
            return (200, ["Content-Type": "text/html"], Data(html.utf8))
        }
        defer { PageMockProtocol.handler = nil }
        let result = try await client().resolve(MediaLink.parse("https://www.acfun.cn/v/ac123"), cookie: "test-cookie")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.assets.allSatisfy(\.isHLS))
        XCTAssertTrue(result.assets.allSatisfy { $0.headers["Cookie"] == nil })
        XCTAssertEqual(result.assets.map(\.label), ["1080P · HLS", "720P · HLS"])
    }
    func testNonHLSRepresentationCannotBecomeFakeMP4() async throws {
        PageMockProtocol.handler = { _ in
            let info: [String: Any] = ["currentVideoInfo": ["ksPlayJson": ["adaptationSet": [["representation": [["url": "https://cdn.example.test/unsupported"]]]]]]]
            let html = "<script>window.videoInfo=" + String(decoding: try JSONSerialization.data(withJSONObject: info), as: UTF8.self) + ";</script>"
            return (200, [:], Data(html.utf8))
        }
        defer { PageMockProtocol.handler = nil }
        do { _ = try await client().resolve(MediaLink.parse("https://www.acfun.cn/v/ac123")); XCTFail("Expected unsupported stream rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不受支持")) }
        XCTAssertThrowsError(try MediaLink.parse("https://acfun.cn.evil.test/v/ac123"))
    }
}
