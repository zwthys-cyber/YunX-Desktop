// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class BaiduCookiePolicyTests: XCTestCase {
    private func cookie(_ domain: String, _ value: String, path: String = "/", expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: "STOKEN", .value: value]
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
    func testPassportAndUnrelatedPathsCannotOverwritePanCredential() throws {
        let cookies = try [cookie(".baidu.com", "root"), cookie("pan.baidu.com", "pan"),
            cookie("passport.baidu.com", "passport"), cookie("pan.baidu.com", "disk", path: "/disk"),
            cookie("evilbaidu.com", "unrelated")]
        XCTAssertEqual(BaiduCookiePolicy.loginValues(cookies)["STOKEN"], "pan")
    }
    func testExpiredCookiesAreExcludedFromLoginButScopeStillControlsDeletion() throws {
        let expired = try cookie(".baidu.com", "old", expires: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(BaiduCookiePolicy.matchesPanScope(expired))
        XCTAssertFalse(BaiduCookiePolicy.appliesToPan(expired))
        XCTAssertTrue(BaiduCookiePolicy.loginValues([expired]).isEmpty)
        XCTAssertFalse(BaiduCookiePolicy.matchesPanScope(try cookie("pan.baidu.com", "old", path: "/disk", expires: Date(timeIntervalSince1970: 1))))
    }
    func testPathMatchingRequiresDirectoryBoundary() throws {
        XCTAssertFalse(BaiduCookiePolicy.matchesPanScope(try cookie("pan.baidu.com", "wrong", path: "/api/get")))
        XCTAssertTrue(BaiduCookiePolicy.matchesPanScope(try cookie("pan.baidu.com", "valid", path: "/api")))
    }
}
