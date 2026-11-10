// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import JavaScriptCore
@testable import YunX

@MainActor
final class ResourceBrowserTests: XCTestCase {
    private func extract(_ setup: String) throws -> [String: Any] {
        let context = try XCTUnwrap(JSContext())
        // JavaScriptCore has no Web URL/DOM. Supply only those fixture interfaces;
        // network and credential access deliberately throw if the real script uses them.
        let resolver: @convention(block) (String, String) -> NSDictionary? = { raw, base in
            guard let base = URL(string: base), let url = URL(string: raw, relativeTo: base)?.absoluteURL else { return nil }
            return ["href": url.absoluteString, "protocol": (url.scheme ?? "") + ":", "pathname": url.path, "username": url.user ?? "", "password": url.password ?? ""] as NSDictionary
        }
        context.setObject(resolver, forKeyedSubscript: "resolveFixtureURL" as NSString)
        context.evaluateScript("""
        function URL(raw, base) { var value=resolveFixtureURL(raw,base);if(!value)throw new Error('bad URL');Object.assign(this,value); }
        var location={href:'https://page.example.test/view?secret=page-only'};
        var images=[],media=[],anchors=[],entries=[];
        var document={baseURI:location.href,images:images,querySelectorAll:function(selector){return selector==='a[href]'?anchors:media;}};
        Object.defineProperty(document,'cookie',{get:function(){throw new Error('Cookie access forbidden');}});
        var performance={getEntriesByType:function(){return entries;}};
        function fetch(){throw new Error('Network forbidden');}
        function XMLHttpRequest(){throw new Error('Network forbidden');}
        """ + setup)
        let value = context.evaluateScript(try ResourceBrowserScript.script())
        XCTAssertNil(context.exception)
        return try XCTUnwrap(value?.toDictionary() as? [String: Any])
    }
    func testLoadedResourcesAreClassifiedDeduplicatedWithoutReadingCredentials() throws {
        let object = try extract("""
        images.push({currentSrc:'https://cdn.example.test/a.jpg',src:''});
        images.push({currentSrc:'blob:https://page.example.test/uuid',src:''});
        media.push({tagName:'VIDEO',currentSrc:'https://cdn.example.test/stream.m3u8'});
        anchors.push({href:'/files/archive.zip'},{href:'https://user:pass@cdn.example.test/private.zip'});
        entries.push({name:'https://cdn.example.test/a.jpg',initiatorType:'img'},{name:'https://cdn.example.test/font.woff2'},{name:'https://cdn.example.test/ignored.json'});
        """)
        let current = try XCTUnwrap(URL(string: "https://page.example.test/view?secret=page-only"))
        let resources = try BrowserResource.parse(object, current: current)
        XCTAssertEqual(resources.count, 4)
        XCTAssertEqual(resources.map(\.kind), [.image, .video, .archive, .font])
        XCTAssertTrue(resources[1].isHLS)
        XCTAssertEqual(resources[2].url.path, "/files/archive.zip")
        XCTAssertTrue(resources.allSatisfy { $0.headers["Cookie"] == nil && $0.headers["Authorization"] == nil })
        XCTAssertEqual(resources[0].headers["Referer"], "https://page.example.test/")
    }
    func testScriptBoundsLargeListsAndReportsOmittedResources() throws {
        let object = try extract("for(var i=0;i<250;i++)images.push({src:'https://cdn.example.test/'+i+'.jpg'});")
        XCTAssertEqual((object["resources"] as? [Any])?.count, 200)
        XCTAssertEqual((object["omitted"] as? NSNumber)?.intValue, 50)
    }
    func testPageNavigationRaceAndInvalidRowsAreRejected() throws {
        let current = URL(string: "https://page.example.test/a")!
        let row = ["url": "https://cdn.example.test/file.zip", "kind": "archive"]
        XCTAssertThrowsError(try BrowserResource.parse(["page": "https://page.example.test/b", "resources": [row]], current: current))
        XCTAssertThrowsError(try BrowserResource.parse(["page": current.absoluteString, "resources": [["url": "javascript:alert(1)", "kind": "video"]]], current: current))
        XCTAssertThrowsError(try BrowserResource.parse(["page": current.absoluteString, "resources": Array(repeating: row, count: 201)], current: current))
        XCTAssertNil(BrowserResource.safeURL("https://user:password@example.test/file"))
        XCTAssertNil(BrowserResource.safeURL("http://example.test/file"))
    }
}
