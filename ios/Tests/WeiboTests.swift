// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class WeiboTests: XCTestCase {
    private func client() -> MediaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        return MediaClient(session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    func testStatusRetweetOriginalsAndMotionPartsKeepCredentialIsolation() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "m.weibo.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-cookie")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            return (200, ["Content-Type": "application/json"], ["ok": 1, "data": ["retweeted_status": [
                "text": "<b>测试</b>", "user": ["screen_name": "测试作者"],
                "pics": [["large": ["url": "https://cdn.example.test/original.png"], "videoSrc": "https://video.weibo.com/media/play?livephoto=fixture"]]
            ]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let link = try MediaLink.parse("https://m.weibo.cn/detail/ABC1234")
        let result = try await client().resolve(link, cookie: "test-cookie")
        XCTAssertEqual(result.author, "测试作者")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.assets.first?.livePhotoVideoURL?.host, "video.weibo.com")
        XCTAssertTrue(result.assets[0].filename.hasSuffix(".png"))
        XCTAssertEqual(result.assets[1].kind, .video)
        for asset in result.assets {
            XCTAssertNil(asset.headers["Cookie"])
            XCTAssertNil(asset.headers["Authorization"])
        }
    }
    func testFidKeepsEveryReturnedQualityAndRejectsSpoofedHosts() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "h5.video.weibo.com")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, ["Content-Type": "application/json"], ["data": ["Component_Play_Playinfo": ["title": "视频", "urls": ["720P": "https://cdn.example.test/720.mp4", "1080P": "https://cdn.example.test/1080.mp4"]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let link = try MediaLink.parse("https://video.weibo.com/show?fid=1034:123456789")
        XCTAssertEqual(link.kind, "fid")
        let result = try await client().resolve(link)
        XCTAssertEqual(Set(result.assets.map(\.label)), ["720P", "1080P"])
        XCTAssertThrowsError(try MediaLink.parse("https://weibo.com.evil.test/123/ABC1234"))
        XCTAssertEqual(WeiboClient.midToID("62"), "10")
        XCTAssertEqual(WeiboClient.midToID("10000001"), "10001")
    }
    func testVerificationPageAndIncompleteGalleryAreRejected() async throws {
        let link = try MediaLink.parse("https://m.weibo.cn/detail/ABC1234")
        MediaMockProtocol.handler = { _ in (200, ["Content-Type": "text/html"], ["secret": "test-secret-cookie"]) }
        defer { MediaMockProtocol.handler = nil }
        do { _ = try await client().resolve(link); XCTFail("Expected verification page rejection") }
        catch { XCTAssertFalse(error.localizedDescription.contains("test-secret-cookie")) }
        MediaMockProtocol.handler = { _ in (200, ["Content-Type": "application/json"], ["data": ["pics": [["large": [:]]]]]) }
        do { _ = try await client().resolve(link); XCTFail("Expected incomplete gallery rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("原图")) }
    }
}
