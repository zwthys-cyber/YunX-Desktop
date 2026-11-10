// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class XHSImageTests: XCTestCase {
    func testOriginalCandidateUsesOnlySupportedCDNAndDropsProcessing() throws {
        let raw = URL(string: "https://sns-webpic-qc.xhscdn.com/20261110/abcd/image-id!nd_dft_webp?signature=test")!
        XCTAssertEqual(XHSImageResolver.candidate(raw)?.absoluteString, "https://sns-img-bd.xhscdn.com/image-id")
        XCTAssertNil(XHSImageResolver.candidate(URL(string: "https://xhscdn.com.evil.test/a/b/c")!))
        XCTAssertNil(XHSImageResolver.candidate(URL(string: "https://sns-img-bd.xhscdn.com/image-id")!))
    }
    func testMissingCandidatesPreserveEveryImageAndOrder() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageMockProtocol.self]
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.host, "sns-img-bd.xhscdn.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.url?.path == "/one" { return (200, ["Content-Type": "image/jpeg"], Data()) }
            return (404, [:], Data())
        }
        defer { PageMockProtocol.handler = nil }
        let assets = ["one", "two"].map { name in
            MediaAsset(id: name, url: URL(string: "https://sns-webpic-qc.xhscdn.com/bucket/hash/\(name)!process")!, previewURL: nil,
                       filename: name + ".jpg", label: "平台图片", size: nil, kind: .image, headers: ["Referer": "https://www.xiaohongshu.com/"])
        }
        let result = MediaResult(title: "test", author: "test", source: URL(string: "https://www.xiaohongshu.com/")!, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
        let revised = try await XHSImageResolver(session: URLSession(configuration: config)).resolve(result)
        XCTAssertEqual(revised.assets.map(\.id), ["one", "two"])
        XCTAssertEqual(revised.assets[0].url.host, "sns-img-bd.xhscdn.com")
        XCTAssertEqual(revised.assets[1].url, assets[1].url)
        XCTAssertTrue(revised.notice?.contains("1 张") == true)
    }
}
