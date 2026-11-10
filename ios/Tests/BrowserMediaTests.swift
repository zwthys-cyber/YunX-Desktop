// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import JavaScriptCore
@testable import YunX

@MainActor
final class BrowserMediaTests: XCTestCase {
    private func extract(_ name: String, fixture: [String: Any], setup: String) throws -> [String: Any] {
        let context = try XCTUnwrap(JSContext())
        context.setObject(fixture, forKeyedSubscript: "fixture" as NSString)
        context.evaluateScript("var window=this;var document={querySelector:function(){return null;},querySelectorAll:function(){return [];},title:'test'};" + setup)
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let value = context.evaluateScript(script)
        XCTAssertNil(context.exception)
        return try XCTUnwrap(value?.toDictionary() as? [String: Any])
    }
    func testDouyinSSRRetainsPairedMotionAndRejectsDifferentWork() throws {
        let fixture: [String: Any] = ["app": ["videoDetail": ["aweme_id": "123456", "desc": "作品", "author": ["nickname": "作者"],
            "images": [["url_list": ["https://cdn.example.test/image.png"], "video": ["playAddr": [["src": "https://cdn.example.test/motion.mp4"]]]]]]]]
        let object = try extract("douyin-extract", fixture: fixture, setup: "var location={pathname:'/note/123456'};window.SSR_RENDER_DATA=fixture;")
        let link = try MediaLink.parse("https://www.douyin.com/note/123456")
        let result = try BrowserMediaPayload.result(object, expected: link, current: link.url)
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.assets[0].kind, .image)
        XCTAssertEqual(result.assets[1].kind, .video)
        XCTAssertTrue(result.assets.allSatisfy { $0.headers["Cookie"] == nil })
        let other = try MediaLink.parse("https://www.douyin.com/note/654321")
        XCTAssertThrowsError(try BrowserMediaPayload.result(object, expected: other, current: link.url))
        var dom = object; dom["src"] = "dom"
        XCTAssertThrowsError(try BrowserMediaPayload.result(dom, expected: link, current: link.url))
    }
    func testXHSPageStatePreservesTextAndShareToken() throws {
        let id = "0123456789abcdef01234567"
        let fixture: [String: Any] = ["note": ["noteDetailMap": [id: ["note": ["noteId": id, "title": "undefined 仍是原文", "user": ["nickname": "作者"], "imageList": [["urlDefault": "https://cdn.example.test/a.webp"], ["url": "https://cdn.example.test/b.jpg"]]]]]]]
        let object = try extract("xhs-extract", fixture: fixture, setup: "var location={pathname:'/explore/\(id)'};window.__INITIAL_STATE__=fixture;")
        let link = try MediaLink.parse("https://www.xiaohongshu.com/explore/\(id)?xsec_token=test-share-token")
        let result = try BrowserMediaPayload.result(object, expected: link, current: link.url)
        XCTAssertEqual(result.title, "undefined 仍是原文")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.source.absoluteString.contains("xsec_token=test-share-token"))
        XCTAssertTrue(result.assets.allSatisfy { $0.headers["Cookie"] == nil })
    }
    func testBrowserNavigationAndPayloadDoNotAcceptLookalikeSites() throws {
        XCTAssertFalse(BrowserMediaWebView.allowed(URL(string: "https://www.douyin.com.evil.test/note/123456")!, provider: .douyin))
        XCTAssertFalse(BrowserMediaWebView.allowed(URL(string: "http://www.douyin.com/note/123456")!, provider: .douyin))
        XCTAssertThrowsError(try MediaLink.parse("https://www.xiaohongshu.com.evil.test/explore/0123456789abcdef01234567"))
        let link = try MediaLink.parse("https://www.douyin.com/note/123456")
        let object: [String: Any] = ["workID": "123456", "src": "ssr", "images": ["https://cdn.example.test/image.jpg"], "motions": ["", "unexpected"]]
        XCTAssertThrowsError(try BrowserMediaPayload.result(object, expected: link, current: link.url))
    }
}
