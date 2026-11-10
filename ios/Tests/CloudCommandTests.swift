// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class CloudCommandTests: XCTestCase {
    private func client() -> CloudCommandClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockProtocol.self]
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return CloudCommandClient(session: URLSession(configuration: config))
    }
    override func tearDown() { CloudMockProtocol.handler = nil; super.tearDown() }
    func testCandidateDoesNotSendLinksOrLongText() {
        XCTAssertFalse(CloudCommandClient.candidate("https://unknown.invalid/中文"))
        XCTAssertFalse(CloudCommandClient.candidate(String(repeating: "字", count: 121)))
        XCTAssertFalse(CloudCommandClient.candidate("ordinary text"))
        XCTAssertEqual(CloudCommandClient.xunleiKeyword("「张三丰资源」"), "张三丰资源")
        XCTAssertNil(CloudCommandClient.xunleiKeyword("绝对有效 咐置松君杂货铺叩苓"))
    }
    func testXunleiFirstAndExplicitPasscodeOverride() async throws {
        CloudMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api-shoulei-ssl.xunlei.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "wd" }?.value, "张三丰资源")
            return (200, [:], ["ext": ["kouling_type": "share_page"], "location": "https://pan.xunlei.com/s/abc123?pwd=1111"])
        }
        let share = try await client().resolve("「张三丰资源」", passcode: "2222")
        XCTAssertEqual(share.provider, .xunlei); XCTAssertEqual(share.passcode, "2222")
    }
    func testFallbackRejectsUnknownPlatformAndInjectedID() async throws {
        for data in [["platform": "evil", "pwdId": "abc"], ["platform": "qk", "pwdId": "abc?pwd=bad"], ["platform": "uc", "pwdId": "valid123"]] {
            CloudMockProtocol.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                if request.url?.host == "api-shoulei-ssl.xunlei.com" { return (200, [:], ["ext": ["kouling_type": "search_url"]]) }
                XCTAssertEqual(request.url?.host, "starsea-api.qwq.pics")
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], ["success": true, "data": data])
            }
            do {
                let share = try await client().resolve("测试口令")
                XCTAssertEqual(data["pwdId"], "valid123")
                XCTAssertEqual(share.provider, .uc); XCTAssertEqual(share.shareID, "valid123")
            } catch { XCTAssertNotEqual(data["pwdId"], "valid123") }
        }
    }
}
