// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class HLSPlaybackTests: XCTestCase {
    func testPlaylistRewritesKeysMapsVariantsAndRelativeSegments() throws {
        let playlist = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio/main.m3u8\"\n../video/part.ts?signature=test\n"
        var targets: [URL] = []
        let output = try HLSPlaylist.rewrite(playlist, base: URL(string: "https://cdn.example.test/level/main.m3u8")!) { url in
            targets.append(url)
            return URL(string: "http://127.0.0.1:12345/token/\(targets.count)")!
        }
        XCTAssertEqual(targets.map(\.path), ["/level/key.bin", "/level/init.mp4", "/level/audio/main.m3u8", "/video/part.ts"])
        XCTAssertTrue(output.contains("URI=\"http://127.0.0.1:12345/token/1\""))
        XCTAssertTrue(targets.last!.absoluteString.contains("signature=test"))
        XCTAssertThrowsError(try HLSPlaylist.rewrite("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://protected\"", base: URL(string: "https://cdn.example.test/a.m3u8")!) { $0 })
        XCTAssertThrowsError(try HLSPlaylist.rewrite("verification page", base: URL(string: "https://cdn.example.test/a.m3u8")!) { $0 })
    }
    func testLocalProxyPreservesMediaHeadersAndRejectsInvalidToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PageMockProtocol.self]
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "cdn.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.acfun.cn/")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path.hasSuffix("m3u8") {
                return (200, ["Content-Type": "application/vnd.apple.mpegurl"], Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n".utf8))
            }
            return (200, ["Content-Type": "video/mp2t", "Content-Length": "3"], Data("abc".utf8))
        }
        defer { PageMockProtocol.handler = nil }
        let proxy = try HLSLoopbackProxy(url: URL(string: "https://cdn.example.test/main.m3u8")!, headers: ["Referer": "https://www.acfun.cn/"], configuration: config)
        let local = try await proxy.start()
        do {
            let (data, response) = try await URLSession.shared.data(from: local)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            let segment = try XCTUnwrap(lines.first { $0.hasPrefix("http://127.0.0.1:") }.flatMap(URL.init(string:)))
            let (body, _) = try await URLSession.shared.data(from: segment)
            XCTAssertEqual(body, Data("abc".utf8))
            var invalid = URLComponents(url: local, resolvingAgainstBaseURL: false)!
            invalid.path = "/invalid-token/resource.m3u8"
            let (_, rejected) = try await URLSession.shared.data(from: invalid.url!)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
            await proxy.stop()
        } catch { await proxy.stop(); throw error }
    }
    func testAccountCredentialsAreNotAcceptedByPlaybackProxy() throws {
        XCTAssertThrowsError(try HLSLoopbackProxy(url: URL(string: "https://cdn.example.test/main.m3u8")!, headers: ["Cookie": "test-secret"]))
    }
}
