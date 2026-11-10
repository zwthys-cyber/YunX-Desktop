// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class BilibiliDASHTests: XCTestCase {
    private func client() -> MediaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        return MediaClient(session: URLSession(configuration: config))
    }
    func testRequestedPartUsesActualDashQualityAACAndSeparatePreview() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-cookie")
            if request.url!.path.hasSuffix("/view") {
                return (200, [:], ["code": 0, "data": ["bvid": "BV1234567890", "title": "作品", "pages": [["cid": 101, "part": "第一集"], ["cid": 202, "part": "第二集"]]]])
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "cid" }?.value, "202")
            if query.first(where: { $0.name == "fnval" })?.value == "4048" {
                return (200, [:], ["code": 0, "data": ["quality": 120, "dash": [
                    "video": [
                        ["id": 120, "codecid": 12, "baseUrl": "https://cdn.example.test/hevc.m4s"],
                        ["id": 120, "codecid": 7, "baseUrl": "https://cdn.example.test/avc.m4s"],
                        ["id": 80, "codecid": 7, "baseUrl": "https://cdn.example.test/1080.m4s"],
                        ["id": 127, "codecid": 13, "baseUrl": "https://cdn.example.test/av1.m4s"]
                    ],
                    "audio": [
                        ["id": 30251, "codecs": "fLaC", "bandwidth": 9999999, "baseUrl": "https://cdn.example.test/flac.m4s"],
                        ["id": 30280, "codecs": "mp4a.40.2", "bandwidth": 192000, "baseUrl": "https://cdn.example.test/aac.m4s"]
                    ]
                ]]])
            }
            return (200, [:], ["code": 0, "data": ["quality": 80, "durl": [["url": "https://cdn.example.test/preview.mp4", "size": 100]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let result = try await client().resolve(MediaLink.parse("https://www.bilibili.com/video/BV1234567890?p=2"), cookie: "test-cookie", quality: 120, preferDASH: true)
        XCTAssertEqual(result.selectedPart, 2)
        XCTAssertEqual(result.actualQuality, 120)
        XCTAssertEqual(result.qualities.map(\.id), [120, 80])
        let asset = try XCTUnwrap(result.assets.first)
        XCTAssertEqual(asset.url.lastPathComponent, "avc.m4s")
        XCTAssertEqual(asset.audioURL?.lastPathComponent, "aac.m4s")
        XCTAssertEqual(asset.previewURL?.lastPathComponent, "preview.mp4")
        XCTAssertTrue(asset.filename.contains("_P2_4K"))
        XCTAssertNil(asset.headers["Cookie"])
    }
    func testMissingAudioFallsBackToAllSingleFileSegmentsWithNotice() async throws {
        MediaMockProtocol.handler = { request in
            if request.url!.path.hasSuffix("/view") { return (200, [:], ["code": 0, "data": ["bvid": "BV1234567890", "title": "作品", "cid": 101]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.first(where: { $0.name == "fnval" })?.value == "4048" {
                return (200, [:], ["code": 0, "data": ["dash": ["video": [["id": 80, "codecid": 7, "baseUrl": "https://cdn.example.test/silent.m4s"]], "audio": []]]])
            }
            return (200, [:], ["code": 0, "data": ["quality": 32, "durl": [["url": "https://cdn.example.test/one.mp4", "size": 10], ["url": "https://cdn.example.test/two.mp4", "size": 20]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let result = try await client().resolve(MediaLink.parse("https://www.bilibili.com/video/BV1234567890"), cookie: "test-cookie", preferDASH: true)
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.assets.allSatisfy { $0.audioURL == nil })
        XCTAssertEqual(result.actualQuality, 32)
        XCTAssertTrue(result.notice?.contains("回退") == true)
    }
}
