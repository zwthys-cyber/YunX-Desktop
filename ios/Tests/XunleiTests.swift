// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import JavaScriptCore
@testable import YunX

private final class XunleiPolls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class XunleiTests: XCTestCase {
    private let device = "0123456789abcdef0123456789abcdef"
    private let access = "test-access-token-0001"
    private func fields() -> [String: String] {
        ["deviceId": device, "authType": "webToken", "captchaToken": "test-captcha-token-0001", "captchaExpiresAt": String(Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)), "refreshToken": "test-refresh-token-0001", "userId": "test-user", "nickname": "测试账号"]
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        return URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
    }
    nonisolated private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testKnownDesktopCaptchaVectorCredentialImportAndTrustedHosts() throws {
        XCTAssertEqual(XunleiProtocol.captchaSign(device: "550cfe136e9d74e95be5393738639de7", timestamp: "1792243618981", web: true), "1.4181a24198c7edfbbba2afbcf1f4fab0")
        XCTAssertTrue(XunleiProtocol.trusted(URL(string: "https://i.xunlei.com/")!))
        XCTAssertFalse(XunleiProtocol.trusted(URL(string: "https://pan.xunlei.com.evil.test/")!))
        XCTAssertFalse(XunleiProtocol.trusted(URL(string: "https://user:secret@pan.xunlei.com/")!))
        XCTAssertFalse(XunleiProtocol.trusted(URL(string: "https://pan.xunlei.com:8443/")!))
        let raw = try JSONSerialization.data(withJSONObject: ["data": ["credentials": ["access_token": access, "refresh_token": "test-refresh-token-0001", "device_id": device]]])
        let quoted = try JSONEncoder().encode(String(decoding: raw, as: UTF8.self))
        let credential = try XunleiWebCredential(raw: String(decoding: quoted, as: UTF8.self))
        XCTAssertEqual(credential.access, access); XCTAssertEqual(credential.fields["deviceId"], device)
        XCTAssertEqual(credential.fields["authType"], "webToken")
        XCTAssertThrowsError(try XunleiWebCredential(object: ["access_token": access]))
    }
    func testOfficialPageExtractionRejectsWrongSubAndKeepsOnlyNeededFields() throws {
        let context = try XCTUnwrap(JSContext())
        let credential: [String: Any] = ["access_token": access, "refresh_token": "test-refresh-token-0001", "sub": "user-a", "password": "must-not-export"]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: credential), as: UTF8.self)
        let captcha = String(decoding: try JSONSerialization.data(withJSONObject: ["token": "test-captcha-token-0001", "expires_at": "2099-01-01T00:00:00Z"]), as: UTF8.self)
        var storage = ["current_sub": "user-a", "credentials_" + XunleiProtocol.webID + "@user-a": raw, "captcha_" + XunleiProtocol.webID: captcha]
        context.setObject(storage, forKeyedSubscript: "fixture" as NSString)
        context.evaluateScript("var localStorage={getItem:function(key){return fixture[key]||null;}};var document={cookie:'deviceid=div101.\(device)tail'};")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "xunlei-credentials", withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let object = try XCTUnwrap(context.evaluateScript(script)?.toDictionary() as? [String: Any])
        XCTAssertNil(context.exception)
        XCTAssertNil(object["password"])
        let parsed = try XunleiWebCredential(object: object)
        XCTAssertEqual(parsed.fields["deviceId"], device)
        XCTAssertEqual(parsed.fields["captchaToken"], "test-captcha-token-0001")
        storage["current_sub"] = "user-b"; storage["credentials_" + XunleiProtocol.webID + "@user-b"] = raw
        context.setObject(storage, forKeyedSubscript: "fixture" as NSString)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript(script)).isNull)
    }
    func testAnonymousShareShortPagesAndSubdirectoriesNeverSendBearer() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api-pan.xunlei.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "X-Captcha-Token"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url?.path.hasSuffix("/detail") == true {
                XCTAssertEqual(query.first(where: { $0.name == "pass_code_token" })?.value, "share-only")
                XCTAssertEqual(query.first(where: { $0.name == "parent_id" })?.value, "folder")
                return (200, [:], ["files": [["id": "child", "name": "child.bin", "kind": "drive#file", "size": 10]]])
            }
            let second = query.first(where: { $0.name == "page_token" })?.value == "next-page"
            return (200, [:], ["pass_code_token": "share-only", "next_page_token": second ? "" : "next-page", "files": [["id": second ? "second" : "first", "name": "fixture.bin", "kind": "drive#file", "size": 10]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .xunlei, session: session())
        let share = try CloudShare.parse("https://pan.xunlei.com/s/share-id?pwd=1234")
        let first = try await client.listPage(share: share)
        let second = try await client.listPage(share: share, page: 2)
        XCTAssertTrue(first.hasMore); XCTAssertFalse(second.hasMore)
        let child = try await client.listPage(share: share, parentID: "folder")
        XCTAssertEqual(child.files.first?.id, "child")
    }
    func testMissingPasscodeDoesNotMasqueradeAsEmptyDirectory() async throws {
        MediaMockProtocol.handler = { _ in (200, [:], ["share_status": "PASS_CODE_ERROR", "files": []]) }
        defer { MediaMockProtocol.handler = nil }
        do {
            _ = try await CloudClient(provider: .xunlei, session: session()).listPage(share: CloudShare(provider: .xunlei, shareID: "share", passcode: "bad"))
            XCTFail("Invalid passcode must not be reported as an empty directory")
        } catch { XCTAssertTrue(error.localizedDescription.contains("提取码")) }
    }
    func testValidatedPersonalDownloadNeverForwardsAccountHeadersToCDN() async throws {
        let device = self.device, access = self.access
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + access)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), device)
            if request.url?.path.hasSuffix("/about") == true { return (200, [:], ["kind": "drive#about", "quota": [:]]) }
            return (200, [:], ["id": "file", "name": "fixture.bin", "size": 10, "links": ["application/octet-stream": ["url": "https://cdn.example.test/file.bin"]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .xunlei, cookie: access, fields: fields(), session: session())
        let name = try await client.validateAccount()
        XCTAssertEqual(name, "测试账号")
        let plan = try await client.download(file: CloudFile(id: "file", name: "fixture.bin", size: 10, isDirectory: false, parentID: "", token: ""), share: nil)
        XCTAssertEqual(plan.url.host, "cdn.example.test")
        XCTAssertNil(plan.headers["Authorization"]); XCTAssertNil(plan.headers["X-Captcha-Token"]); XCTAssertNil(plan.headers["Cookie"])
    }
    func testExpiredAccessRefreshesWithWebClientAndPersistsRotatedTokens() async throws {
        let device = self.device, access = self.access
        MediaMockProtocol.handler = { request in
            if request.url?.path == "/v1/auth/token" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try Self.body(request)
                XCTAssertEqual(body["client_id"] as? String, XunleiProtocol.webID)
                XCTAssertEqual(body["refresh_token"] as? String, "test-refresh-token-0001")
                return (200, [:], ["access_token": "new-test-access-token-0001", "refresh_token": "new-test-refresh-token-0001"])
            }
            if request.url?.path == "/v1/shield/captcha/init" {
                let body = try Self.body(request)
                XCTAssertEqual(body["client_id"] as? String, XunleiProtocol.webID)
                XCTAssertEqual(body["device_id"] as? String, device)
                XCTAssertEqual(body["action"] as? String, "GET:/drive/v1/about")
                XCTAssertEqual((body["meta"] as? [String: Any])?["user_id"] as? String, "test-user")
                return (200, [:], ["captcha_token": "new-test-captcha-token-0001"])
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer " + access { return (401, [:], ["error": "unauthenticated"]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-test-access-token-0001")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Captcha-Token"), "new-test-captcha-token-0001")
            return (200, [:], ["kind": "drive#about", "quota": [:]])
        }
        defer { MediaMockProtocol.handler = nil }
        var saved: [String: String]?
        let client = CloudClient(provider: .xunlei, cookie: access, fields: fields(), session: session(), credentialChanged: { token, fields in
            XCTAssertEqual(token, "new-test-access-token-0001"); saved = fields; return true
        })
        _ = try await client.validateAccount()
        XCTAssertEqual(saved?["refreshToken"], "new-test-refresh-token-0001")
        XCTAssertEqual(saved?["deviceId"], device)
        XCTAssertEqual(saved?["captchaToken"], "new-test-captcha-token-0001")
    }
    func testRunningTaskWithZeroErrorCodeDoesNotCompleteEarly() async throws {
        let polls = XunleiPolls()
        MediaMockProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let body = try Self.body(request)
                XCTAssertEqual((body["to"] as? [String: Any])?["space"] as? String, "")
                return (200, [:], ["task_id": "move-task"])
            }
            return (200, [:], ["phase": polls.next() == 1 ? "PHASE_TYPE_RUNNING" : "PHASE_TYPE_COMPLETE", "error_code": 0])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .xunlei, cookie: access, fields: fields(), session: session())
        try await client.mutate(.move(file: CloudFile(id: "file", name: "fixture.bin", size: 10, isDirectory: false, parentID: "", token: ""), parent: "target"))
        XCTAssertEqual(polls.count, 2)
    }
}
