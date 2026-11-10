// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class LanzouTests: XCTestCase {
    private func client(cookie: String = "") -> CloudClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PageMockProtocol.self]; config.httpCookieStorage = nil
        return CloudClient(provider: .lanzou, cookie: cookie, session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    nonisolated private static func text(_ value: String, headers: [String: String] = [:]) -> (Int, [String: String], Data) { (200, headers, Data(value.utf8)) }
    nonisolated private static func json(_ value: [String: Any], headers: [String: String] = [:]) throws -> (Int, [String: String], Data) { (200, headers, try JSONSerialization.data(withJSONObject: value)) }
    nonisolated private static func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return String(decoding: data, as: UTF8.self).split(separator: "&").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
        }
    }
    func testJavaChallengeVectorHostAndSizeParsing() throws {
        let url = try XCTUnwrap(Bundle(for: LanzouTests.self).url(forResource: "lanzou-vectors", withExtension: "json"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertEqual(LanzouProtocol.challenge("var arg1='\(try XCTUnwrap(vector["arg"]))';"), vector["cookie"])
        XCTAssertNil(LanzouProtocol.challenge("var arg1='invalid'"))
        XCTAssertEqual(LanzouProtocol.size("1.5 M"), 1_572_864)
        XCTAssertTrue(LanzouProtocol.shareHost("pan.lanzoui.com")); XCTAssertFalse(LanzouProtocol.shareHost("pan.lanzoui.com.evil.test"))
        let share = try CloudShare.parse("https://abc.lanzouq.com/iFixture 密码：1234")
        XCTAssertEqual(share.provider, .lanzou); XCTAssertEqual(share.sourceURL?.host, "abc.lanzouq.com")
        XCTAssertThrowsError(try CloudShare.parse("https://abc.lanzouq.com.evil.test/iFixture"))
    }
    func testPersonalPagingKeepsFolderAndFileIDsSeparateAndPreservesPHPSESSID() async throws {
        PageMockProtocol.handler = { request in
            if request.url?.path == "/mydisk.php" { return Self.text("url:'/doupload.php?uid=123', data:{'vei':'a+b/c='}", headers: ["Set-Cookie": "PHPSESSID=fixture-session; Path=/; Secure"]) }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("PHPSESSID=fixture-session") == true)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first(where: { $0.name == "vei" })?.value, "a+b/c=")
            let form = Self.form(request)
            if form["task"] == "47" { return try Self.json(["zt": 1, "text": [["fol_id": "42", "name": "folder"]]]) }
            if form["pg"] == "2" { return try Self.json(["zt": 2, "text": []]) }
            return try Self.json(["zt": 1, "text": [["id": "42", "name_all": "fixture.bin", "size": "1 K"]]])
        }
        defer { PageMockProtocol.handler = nil }
        let client = client(cookie: "ylogin=fixture; phpdisk_info=fixture")
        _ = try await client.validateAccount()
        let first = try await client.listPage(share: nil)
        XCTAssertEqual(first.files.map(\.id), ["d:42", "f:42"]); XCTAssertTrue(first.hasMore)
        let second = try await client.listPage(share: nil, page: 2)
        XCTAssertFalse(second.hasMore); XCTAssertTrue(second.files.isEmpty)
    }
    func testSharePageChallengeRetriesOnlyWithHostScopedPublicCookie() async throws {
        let fixture = try XCTUnwrap(Bundle(for: LanzouTests.self).url(forResource: "lanzou-vectors", withExtension: "json"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        let arg = try XCTUnwrap(vector["arg"]), value = try XCTUnwrap(vector["cookie"])
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "abc.lanzoui.com")
            if request.value(forHTTPHeaderField: "Cookie") == nil { return Self.text("var arg1='\(arg)';") }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "acw_sc__v2=" + value)
            return Self.text("<title>fixture.bin - 蓝奏云</title>")
        }
        defer { PageMockProtocol.handler = nil }
        let result = try await client().listPage(share: CloudShare.parse("https://abc.lanzoui.com/iFixture"))
        XCTAssertEqual(result.files.first?.name, "fixture.bin")
    }
    func testFolderShareUsesActualPageParametersAndEndStatus() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.httpMethod == "GET" { return Self.text("<title>folder - 蓝奏云</title><script>var lx='2';var fid='42';var t='time';var k='key';</script>filemoreajax") }
            let form = Self.form(request)
            XCTAssertEqual(form["fid"], "42"); XCTAssertEqual(form["pwd"], "1234")
            if form["pg"] == "2" { return try Self.json(["zt": 2]) }
            return try Self.json(["zt": 1, "text": [["id": "iFile", "name_all": "fixture.bin", "size": "1 K"]]])
        }
        defer { PageMockProtocol.handler = nil }
        let client = client(cookie: "ylogin=must-not-send; phpdisk_info=must-not-send"), share = try CloudShare.parse("https://abc.lanzoui.com/bFolder?pwd=1234")
        let first = try await client.listPage(share: share)
        XCTAssertTrue(first.hasMore); XCTAssertEqual(first.files.first?.id, "iFile")
        let second = try await client.listPage(share: share, page: 2)
        XCTAssertTrue(second.files.isEmpty); XCTAssertFalse(second.hasMore)
    }
    func testSameOriginIframeAndCrossOriginAPIReceiveNoAccountCredentials() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("ylogin") == true)
            if request.httpMethod == "HEAD" { return Self.text("", headers: ["Content-Type": "application/octet-stream", "Content-Length": "10"]) }
            if request.url?.host == "apifile.woozooo.com" {
                let form = Self.form(request)
                XCTAssertEqual(form["sign"], "page-sign"); XCTAssertEqual(form["websignkey"], "page-key")
                return try Self.json(["zt": 1, "dom": "https://node.example.test", "url": "fixture"])
            }
            if request.url?.path == "/frame" { return Self.text("var wp_sign='page-sign';var ajaxdata='page-key';var domain1='https://apifile.woozooo.com/ajaxm.php?file=42';") }
            return Self.text("<title>fixture.bin - 蓝奏云</title><iframe src='/frame'></iframe>")
        }
        defer { PageMockProtocol.handler = nil }
        let client = client(cookie: "ylogin=must-not-send; phpdisk_info=must-not-send"), share = try CloudShare.parse("https://abc.lanzoui.com/iFixture")
        let plan = try await client.download(file: CloudFile(id: "iFixture", name: "fixture.bin", size: 10, isDirectory: false, parentID: "0", token: ""), share: share)
        XCTAssertEqual(plan.url.host, "node.example.test"); XCTAssertEqual(plan.headers["Cookie"], "down_ip=1")
    }
    func testForeignIframeCannotBeReadAsDownloadPage() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "abc.lanzoui.com")
            return Self.text("<title>fixture.bin</title><iframe src='https://evil.test/frame'></iframe>")
        }
        defer { PageMockProtocol.handler = nil }
        let share = try CloudShare.parse("https://abc.lanzoui.com/iFixture")
        do { _ = try await client().download(file: CloudFile(id: "iFixture", name: "fixture.bin", size: 1, isDirectory: false, parentID: "0", token: ""), share: share); XCTFail("Foreign iframe must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("同源")) }
    }
    func testBadPasswordDoesNotBecomeAnEmptyShare() async throws {
        PageMockProtocol.handler = { request in
            if request.httpMethod == "GET" { return Self.text("var lx='2';var fid='42';var t='t';var k='k';filemoreajax") }
            return try Self.json(["zt": 3])
        }
        defer { PageMockProtocol.handler = nil }
        let share = try CloudShare.parse("https://abc.lanzoui.com/bFixture?pwd=bad")
        do { _ = try await client().list(share: share); XCTFail("Bad password must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("提取码")) }
    }
}
