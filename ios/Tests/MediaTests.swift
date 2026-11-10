// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class MediaMockProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CloudError.message("Live network disabled in media tests.") }
            let (status, headers, object) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

enum MediaFixtures {
    static var view: [String: Any] {
        ["code": 0, "data": ["bvid": "BV1GJ411x7h7", "title": "测试/视频", "owner": ["name": "作者"],
                             "pages": [["cid": 11, "part": "第一集"], ["cid": 22, "part": "第二集"]]]]
    }
    static var play: [String: Any] {
        ["code": 0, "data": ["quality": 32, "accept_quality": [64, 32],
                             "accept_description": ["720P", "480P"],
                             "durl": [["url": "https://cdn.example.test/part1.mp4", "size": 123]]]]
    }
    static func pixivInfo(count: Int, type: Int = 0) -> [String: Any] {
        ["error": false, "body": ["title": "多页插画", "userName": "画师", "pageCount": count, "illustType": type]]
    }
}

@MainActor
final class MediaTests: XCTestCase {
    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], Any)) -> MediaClient {
        MediaMockProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        config.httpCookieStorage = nil
        return MediaClient(session: URLSession(configuration: config))
    }

    func testLinkHostsAndPartAreValidated() throws {
        let link = try MediaLink.parse("看看 https://www.bilibili.com/video/BV1GJ411x7h7?p=3")
        XCTAssertEqual(link.provider, .bilibili)
        XCTAssertEqual(link.part, 3)
        XCTAssertThrowsError(try MediaLink.parse("https://www.bilibili.com.evil.test/video/BV1GJ411x7h7"))
        XCTAssertThrowsError(try MediaLink.parse("https://www.bilibili.com/video/BV1GJ411x7h7?p=0"))
        XCTAssertThrowsError(try MediaLink.parse("https://www.bilibili.com/bangumi/play/ep123"))
        XCTAssertEqual(try MediaLink.parse("https://www.pixiv.net/en/artworks/123456").id, "123456")
        XCTAssertEqual(try MediaLink.parse("https://www.pixiv.net/member_illust.php?illust_id=456").id, "456")
        XCTAssertTrue(try MediaLink.parse("https://b23.tv/abc").isShort)
    }

    func testBilibiliUsesRequestedPartAndKeepsEverySegmentAndActualQuality() async throws {
        let api = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SESSDATA=fake")
            if request.url!.path.hasSuffix("/view") { return (200, [:], MediaFixtures.view) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "cid" })?.value, "22")
            XCTAssertEqual(query.first(where: { $0.name == "qn" })?.value, "64")
            XCTAssertEqual(query.first(where: { $0.name == "fnval" })?.value, "1")
            return (200, [:], ["code": 0, "data": ["quality": 32, "accept_quality": [64, 32],
                "durl": [["url": "https://cdn.example.test/a.mp4", "size": 123],
                         ["url": "//cdn.example.test/b.mp4", "size": 456]]]])
        }
        let link = try MediaLink.parse("https://www.bilibili.com/video/BV1GJ411x7h7")
        let result = try await api.resolve(link, cookie: "SESSDATA=fake", part: 2, quality: 64)
        XCTAssertEqual(result.selectedPart, 2)
        XCTAssertEqual(result.actualQuality, 32)
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.assets[0].filename.contains("_P2_480P_片段1.mp4"))
        XCTAssertTrue(result.assets[1].filename.contains("片段2"))
        XCTAssertEqual(result.assets[1].url.scheme, "https")
        XCTAssertEqual(result.assets[0].headers["Referer"], "https://www.bilibili.com/")
        XCTAssertNil(result.assets[0].headers["Cookie"])
    }

    func testShortLinksDoNotReceiveAccountCookies() async throws {
        let api = client { request in
            if request.url?.host == "b23.tv" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (302, ["Location": "https://www.bilibili.com/video/BV1GJ411x7h7"], [:])
            }
            XCTAssertEqual(request.url?.host, "api.bilibili.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SESSDATA=fake")
            return (200, [:], request.url!.path.hasSuffix("/view") ? MediaFixtures.view : MediaFixtures.play)
        }
        let result = try await api.resolve(try MediaLink.parse("https://b23.tv/abc"), cookie: "SESSDATA=fake")
        XCTAssertEqual(result.assets.count, 1)
    }

    func testExternalShortRedirectIsRejected() async throws {
        let api = client { request in
            XCTAssertEqual(request.url?.host, "b23.tv", "Must not request an external redirect target")
            return (302, ["Location": "https://evil.example.test/file"], [:])
        }
        do {
            _ = try await api.resolve(try MediaLink.parse("https://b23.tv/abc"), cookie: "SESSDATA=fake")
            XCTFail("External target must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不支持")) }
    }

    func testPixivAllPagesKeepImageExtensionsAndReferer() async throws {
        let api = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "PHPSESSID=fake")
            if request.url!.path.hasSuffix("/pages") {
                return (200, [:], ["error": false, "body": [
                    ["urls": ["original": "https://i.pximg.net/img/one.png", "small": "https://i.pximg.net/small/one.jpg"]],
                    ["urls": ["original": "https://i.pximg.net/img/two.jpeg"]]
                ]])
            }
            return (200, [:], MediaFixtures.pixivInfo(count: 2))
        }
        let result = try await api.resolve(try MediaLink.parse("https://www.pixiv.net/artworks/123"), cookie: "PHPSESSID=fake")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.assets[0].filename.hasSuffix("_1.png"))
        XCTAssertTrue(result.assets[1].filename.hasSuffix("_2.jpeg"))
        XCTAssertEqual(result.assets[0].previewURL?.path, "/small/one.jpg")
        XCTAssertEqual(result.assets[0].headers["Referer"], "https://www.pixiv.net/")
        XCTAssertNil(result.assets[0].headers["Cookie"])
    }

    func testPixivMissingPagesAreNotReportedAsACompleteGallery() async throws {
        let api = client { request in
            if request.url!.path.hasSuffix("/pages") {
                return (200, [:], ["error": false, "body": [["urls": ["original": "https://i.pximg.net/one.jpg"]]]])
            }
            return (200, [:], MediaFixtures.pixivInfo(count: 2))
        }
        do {
            _ = try await api.resolve(try MediaLink.parse("https://www.pixiv.net/artworks/123"))
            XCTFail("Missing page must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("页数")) }
    }

    func testUgoiraIsExplicitlyUnsupported() async throws {
        let api = client { request in
            XCTAssertFalse(request.url!.path.hasSuffix("/pages"))
            return (200, [:], MediaFixtures.pixivInfo(count: 1, type: 2))
        }
        do {
            _ = try await api.resolve(try MediaLink.parse("https://www.pixiv.net/artworks/123"))
            XCTFail("Ugoira must not become a static image")
        } catch { XCTAssertTrue(error.localizedDescription.contains("动图")) }
    }

    func testDashOnlyResponseDoesNotBecomeASilentVideo() async throws {
        let api = client { request in
            if request.url!.path.hasSuffix("/view") { return (200, [:], MediaFixtures.view) }
            return (200, [:], ["code": 0, "data": ["dash": ["video": [], "audio": []]]])
        }
        do {
            _ = try await api.resolve(try MediaLink.parse("https://www.bilibili.com/video/BV1GJ411x7h7"))
            XCTFail("DASH requires a separate muxing pipeline")
        } catch { XCTAssertTrue(error.localizedDescription.contains("分轨")) }
    }

    func testAPIErrorDoesNotEchoServerSecrets() async throws {
        let api = client { _ in (200, [:], ["code": -403, "message": "SECRET_SESSION_COOKIE"]) }
        do {
            _ = try await api.resolve(try MediaLink.parse("https://www.bilibili.com/video/BV1GJ411x7h7"))
            XCTFail("Denied request must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_SESSION_COOKIE")) }
    }

    func testLoginRequiresBooleanAuthenticatedState() async throws {
        let api = client { _ in
            (200, [:], ["code": 0, "data": ["isLogin": false, "uname": "guest"]])
        }
        do {
            _ = try await api.validate(provider: .bilibili, cookie: "SESSDATA=fake")
            XCTFail("Guest must not be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("登录")) }
    }

    func testLongUnicodeNamesKeepTheirExtensionAndFitFilesystemLimits() {
        let value = FileNamePolicy.name(String(repeating: "中文🎬", count: 100) + ".mp4")
        XCTAssertLessThanOrEqual(value.utf8.count, 200)
        XCTAssertTrue(value.hasSuffix(".mp4"))
        XCTAssertFalse(FileNamePolicy.name("../folder\\file.jpg").contains("/"))
        XCTAssertEqual(FileNamePolicy.name(".."), "download.bin")
    }

    func testMovieByteRangesAndIntegerOverflow() {
        XCTAssertEqual(MovieContentRange.parse("bytes 10-19/100"), MovieContentRange(start: 10, end: 19, total: 100))
        XCTAssertEqual(MovieContentRange.parse("bytes 0-1/*")?.total, nil)
        XCTAssertNil(MovieContentRange.parse("bytes 10-9/100"))
        XCTAssertNil(MovieContentRange.parse("bytes -1-9/100"))
        XCTAssertNil(MovieContentRange.parse("bytes 0-100/100"))
        XCTAssertNil(MovieContentRange.parse("items 0-1/100"))
        XCTAssertEqual(MovieContentRange.header(offset: 10, length: 5), "bytes=10-14")
        XCTAssertEqual(MovieContentRange.header(offset: 10, length: nil), "bytes=10-")
        XCTAssertNil(MovieContentRange.header(offset: .max, length: 2))
        XCTAssertNil(MovieContentRange.header(offset: -1, length: 2))
    }
}
