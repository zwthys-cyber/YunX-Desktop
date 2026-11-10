// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class PageMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CloudError.message("Live network disabled") }
            let (status, headers, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class KuaishouTests: XCTestCase {
    private func client() -> MediaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageMockProtocol.self]
        return MediaClient(session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    nonisolated private static func html(_ root: [String: Any]) throws -> Data {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        return Data(("<script>window.INIT_STATE = " + json + ";window.next={};</script>").utf8)
    }
    func testRedirectAndEveryAtlasImageWithoutCrossDomainCookies() async throws {
        PageMockProtocol.handler = { request in
            if request.url?.host == "v.kuaishou.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-cookie")
                return (302, ["Location": "https://v.m.chenzhongtech.com/fw/photo/work123"], Data())
            }
            XCTAssertEqual(request.url?.host, "v.m.chenzhongtech.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, ["Content-Type": "text/html"], try Self.html(["entry": ["photo": [
                "id": "work123", "caption": "包含引号 \" 和括号 } [ 的标题", "userName": "作者\u{3164}",
                "mainMvUrls": [["url": "https://cdn.example.test/video.mp4"]],
                "ext_params": ["atlas": ["cdnList": [["cdn": "cdn.example.test"]], "list": ["image1.png", "image2.webp"]]]
            ]]]))
        }
        defer { PageMockProtocol.handler = nil }
        let link = try MediaLink.parse("https://v.kuaishou.com/share123")
        let result = try await client().resolve(link, cookie: "test-cookie")
        XCTAssertEqual(result.assets.count, 3)
        XCTAssertEqual(result.author, "作者")
        XCTAssertTrue(result.assets[1].filename.hasSuffix(".png"))
        XCTAssertTrue(result.assets[2].filename.hasSuffix(".webp"))
        XCTAssertTrue(result.assets.allSatisfy { $0.headers["Cookie"] == nil })
    }
    func testExternalRedirectAndSpoofedHostsAreRejected() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "v.kuaishou.com")
            return (302, ["Location": "https://evil.example.test/"], Data())
        }
        defer { PageMockProtocol.handler = nil }
        let link = try MediaLink.parse("https://v.kuaishou.com/share123")
        do { _ = try await client().resolve(link, cookie: "test-cookie"); XCTFail("Expected redirect rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不支持")) }
        XCTAssertThrowsError(try MediaLink.parse("https://kuaishou.com.evil.example.test/short-video/id123"))
    }
    func testMissingAndAmbiguousSSRIsRejected() async throws {
        XCTAssertThrowsError(try InlineJSON.object("<html>verification</html>", marker: "window.INIT_STATE"))
        PageMockProtocol.handler = { _ in
            (200, [:], try Self.html(["one": ["photo": ["id": "other1"]], "two": ["photo": ["id": "other2"]]]))
        }
        defer { PageMockProtocol.handler = nil }
        let link = try MediaLink.parse("https://www.kuaishou.com/short-video/work123")
        do { _ = try await client().resolve(link); XCTFail("Expected ambiguous work rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("唯一")) }
    }
}
