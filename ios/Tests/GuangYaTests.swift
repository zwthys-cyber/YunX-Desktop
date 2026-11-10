// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class GuangYaTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
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
    func testShareHostAndAccountDeviceHeaders() async throws {
        XCTAssertEqual(try CloudShare.parse("https://www.guangyapan.com/s/share-id?code=1234").passcode, "1234")
        XCTAssertThrowsError(try CloudShare.parse("https://www.guangyapan.com.evil.test/s/share"))
        let device = GuangYaDevice()
        XCTAssertEqual(GuangYaDevice(fields: device.fields).sign, device.sign)
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "account.guangyapan.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id"), device.id)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Sign"), device.sign)
            if request.url?.path == "/v1/user/me" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
                return (200, [:], ["sub": "test-user", "nickname": "测试用户"])
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.body(request)
            if request.url?.path == "/v1/shield/captcha/init" { return (200, [:], ["captcha_token": "test-captcha"]) }
            XCTAssertEqual(body["username"] as? String, "+86 13800000000")
            XCTAssertEqual(body["password"] as? String, " password ")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Captcha-Token"), "test-captcha")
            return (200, [:], ["access_token": "test-access", "refresh_token": "test-refresh"])
        }
        defer { MediaMockProtocol.handler = nil }
        let (token, fields) = try await GuangYaClient(fields: device.fields, session: session()).login(account: "13800000000", password: " password ")
        XCTAssertEqual(token, "test-access")
        XCTAssertEqual(fields["refreshToken"], "test-refresh")
        XCTAssertEqual(fields["deviceId"], device.id)
    }
    func testSharePaginationAndDownloadNeverUseAccountBearer() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.guangyapan.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "dt"), "4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "did")?.count, 32)
            let body = try Self.body(request)
            if request.url?.path == "/userres/v1/get_share_access_token" {
                XCTAssertEqual(body["code"] as? String, "1234")
                return (200, [:], ["code": 0, "data": ["accessToken": "share-only"]])
            }
            XCTAssertEqual(body["accessToken"] as? String, "share-only")
            if request.url?.path == "/userres/v1/get_share_download_url" {
                return (200, [:], ["code": 0, "data": ["signedURL": "https://cdn.example.test/file.bin"]])
            }
            let second = body["cursor"] as? String == "next-page"
            XCTAssertEqual(body["parentId"] as? String, "")
            return (200, [:], ["code": 0, "data": ["hasMore": !second, "cursor": second ? "" : "next-page", "files": [["fileId": second ? "2" : "1", "fileName": "file.bin", "fileSize": "10", "resType": "1"]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .guangya, cookie: "account-secret", session: session())
        let share = CloudShare(provider: .guangya, shareID: "share", passcode: "1234")
        let first = try await client.list(share: share)
        let second = try await client.list(share: share, page: 2)
        let end = try await client.list(share: share, page: 3)
        XCTAssertEqual(second.first?.id, "2"); XCTAssertTrue(end.isEmpty)
        let download = try await client.download(file: XCTUnwrap(first.first), share: share)
        XCTAssertEqual(download.size, 10)
        XCTAssertNil(download.headers["Authorization"])
        XCTAssertNil(download.headers["Cookie"])
    }
    func testRestrictedSharesAndInteractiveCaptchaStop() async throws {
        MediaMockProtocol.handler = { request in
            if request.url?.path == "/v1/shield/captcha/init" { return (200, [:], ["url": "https://account.guangyapan.com/verify"]) }
            return (200, [:], ["code": 207])
        }
        defer { MediaMockProtocol.handler = nil }
        do {
            _ = try await GuangYaClient(session: session()).login(account: "test", password: "test")
            XCTFail("Interactive captcha must stop automated login")
        } catch { XCTAssertTrue(error.localizedDescription.contains("安全验证")) }
        do {
            _ = try await CloudClient(provider: .guangya, session: session()).list(share: CloudShare(provider: .guangya, shareID: "s", passcode: ""))
            XCTFail("Restricted share must not appear empty or completed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("受限")) }
    }
    func testExpiredAccountRefreshesOnceAndPersistsDeviceAndRotatedToken() async throws {
        let device = GuangYaDevice()
        MediaMockProtocol.handler = { request in
            if request.url?.path == "/v1/auth/token" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Action"), "401")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try Self.body(request)
                XCTAssertEqual(body["refresh_token"] as? String, "old-refresh")
                return (200, [:], ["access_token": "new-access", "refresh_token": "new-refresh"])
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" { return (401, [:], [:]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, [:], ["sub": "user", "nickname": "refreshed"])
        }
        defer { MediaMockProtocol.handler = nil }
        var fields = device.fields; fields["refreshToken"] = "old-refresh"
        var persisted = false
        let client = GuangYaClient(token: "old-access", fields: fields, session: session(), changed: { token, fields in
            XCTAssertEqual(token, "new-access")
            XCTAssertEqual(fields["refreshToken"], "new-refresh")
            XCTAssertEqual(fields["deviceId"], device.id)
            persisted = true
            return true
        })
        let name = try await client.validate()
        XCTAssertEqual(name, "refreshed")
        XCTAssertTrue(persisted)
    }
    func testSMSLoginRequiresExplicitRegistrationConsent() async throws {
        MediaMockProtocol.handler = { request in
            let body = request.httpMethod == "POST" ? try Self.body(request) : [:]
            switch request.url?.path {
            case "/v1/shield/captcha/init":
                XCTAssertEqual(body["action"] as? String, "POST:/v1/auth/verification")
                return (200, [:], ["captcha_token": "test-captcha"])
            case "/v1/auth/verification":
                XCTAssertEqual(body["phone_number"] as? String, "+86 13800000000")
                return (200, [:], ["verification_id": "challenge", "is_user": false, "expires_in": 600])
            case "/v1/auth/verification/verify":
                XCTAssertEqual(body["verification_code"] as? String, "123456")
                return (200, [:], ["verification_token": "verified"])
            case "/v1/auth/signup":
                XCTAssertEqual(body["name"] as? String, "138****0000")
                XCTAssertEqual(body["verification_token"] as? String, "verified")
                XCTAssertNil(body["password"])
                return (200, [:], ["access_token": "test-access", "refresh_token": "test-refresh"])
            case "/v1/user/me": return (200, [:], ["sub": "new-user"])
            default: XCTFail("Unexpected auth endpoint"); return (500, [:], [:])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GuangYaClient(session: session())
        let challenge = try await client.sendSMS(phone: "13800000000")
        do {
            _ = try await client.loginSMS(challenge: challenge, code: "123456", allowRegistration: false)
            XCTFail("New account registration requires consent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("同意")) }
        let (token, _) = try await client.loginSMS(challenge: challenge, code: "123456", allowRegistration: true)
        XCTAssertEqual(token, "test-access")
    }
    func testShareSaveSeparatesAccountAndShareTokensAndWaitsForTask() async throws {
        MediaMockProtocol.handler = { request in
            let body = try Self.body(request)
            if request.url?.path == "/userres/v1/get_share_access_token" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], ["code": 0, "data": ["accessToken": "share-access"]])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-access")
            if request.url?.path == "/userres/v1/restore_share" {
                XCTAssertEqual(body["accessToken"] as? String, "share-access")
                XCTAssertEqual(body["fileIds"] as? [String], ["source-file"])
                XCTAssertEqual(body["parentId"] as? String, "target-folder")
                return (200, [:], ["code": 0, "data": ["taskId": "save-task"]])
            }
            XCTAssertEqual(request.url?.path, "/userres/v1/get_task_status")
            XCTAssertEqual(body["taskId"] as? String, "save-task")
            return (200, [:], ["code": 0, "data": ["status": 2, "detail": ["code": 0]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let file = CloudFile(id: "source-file", name: "test.bin", size: 10, isDirectory: false, parentID: "", token: "")
        let client = CloudClient(provider: .guangya, cookie: "account-access", session: session())
        try await client.mutate(.save(file: file, share: CloudShare(provider: .guangya, shareID: "share", passcode: ""), parent: "target-folder"))
        do {
            try await client.mutate(.rename(file: file, name: "../invalid"))
            XCTFail("Invalid filename must be rejected before network mutation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("名称")) }
    }
}
