// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class CloudMockProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw CloudError.message("Unexpected request; live network is disabled in tests.")
            }
            let (status, headers, object) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@MainActor
final class CloudDriveTests: XCTestCase {
    private func client(_ provider: CloudProvider, cookie: String = "",
                        changed: ((String) -> Void)? = nil) -> CloudClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockProtocol.self]
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        return CloudClient(provider: provider, cookie: cookie, session: session, cookieChanged: changed)
    }

    nonisolated private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testShareParsingAndExplicitPasscodeOverride() throws {
        let share = try CloudShare.parse("分享：https://pan.quark.cn/s/Ab123 提取码：aB12")
        XCTAssertEqual(share.provider, .quark)
        XCTAssertEqual(share.shareID, "Ab123")
        XCTAssertEqual(share.passcode, "aB12")
        XCTAssertEqual(try CloudShare.parse("https://drive.uc.cn/s/Ab123?pwd=1234", override: "5678").passcode, "5678")
        XCTAssertThrowsError(try CloudShare.parse("https://pan.quark.cn.evil.example/s/Ab123"))
        XCTAssertThrowsError(try CloudShare.parse("https://evil.example/?url=https%3A%2F%2Fpan.quark.cn%2Fs%2Fabc"))
    }

    func testUCTransferListingUsesTokenAndRequestedDirectoryPage() async throws {
        CloudMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "pc-api.uc.cn")
            if request.url!.path.hasSuffix("/token") {
                let payload = try self.body(request)
                XCTAssertEqual(payload["pwd_id"] as? String, "Share123")
                XCTAssertEqual(payload["passcode"] as? String, "a123")
                XCTAssertEqual(payload["share_for_transfer"] as? Bool, true)
                return (200, [:], ["status": 200, "data": ["stoken": "a+b/=?!"]])
            }
            XCTAssertEqual(request.url!.path, "/1/clouddrive/transfer_share/detail")
            let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(values.first(where: { $0.name == "stoken" })?.value, "a+b/=?!")
            XCTAssertEqual(values.first(where: { $0.name == "pdir_fid" })?.value, "folder123")
            XCTAssertEqual(values.first(where: { $0.name == "_page" })?.value, "2")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://fast.uc.cn")
            return (200, [:], ["status": 200, "data": ["detail_info": ["list": [
                ["fid": "f1", "file_name": "资料", "dir": true, "share_fid_token": "ft1"]
            ]]]])
        }
        let result = try await client(.uc).list(
            share: CloudShare(provider: .uc, shareID: "Share123", passcode: "a123"),
            parentID: "folder123", page: 2)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "f1")
        XCTAssertTrue(result[0].isDirectory)
        XCTAssertEqual(result[0].token, "ft1")
    }

    func testGuestDownloadRetainsResponseBoundPugsAndRequestHeaders() async throws {
        CloudMockProtocol.handler = { request in
            if request.url!.path.hasSuffix("/token") {
                return (200, [:], ["status": 200, "data": ["stoken": "st"]])
            }
            XCTAssertEqual(request.url!.path, "/1/clouddrive/file/download")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")!.contains("uc-cloud-drive"))
            let payload = try self.body(request)
            XCTAssertEqual(payload["fids_token"] as? [String], ["ft"])
            XCTAssertEqual(payload["stoken"] as? String, "st")
            return (200, ["Set-Cookie": "__pugs=guest123; Path=/; Secure"],
                    ["status": 200, "data": [
                        ["download_url": "https://cdn.example.test/file", "file_name": "测试.zip", "size": 456]
                    ]])
        }
        let file = CloudFile(id: "f1", name: "测试.zip", size: 456, isDirectory: false, parentID: "0", token: "ft")
        let result = try await client(.uc).download(
            file: file, share: CloudShare(provider: .uc, shareID: "s123", passcode: ""))
        XCTAssertEqual(result.headers["Cookie"], "__pugs=guest123")
        XCTAssertEqual(result.headers["Referer"], "https://drive.uc.cn/")
        XCTAssertEqual(result.filename, "测试.zip")
        XCTAssertEqual(result.size, 456)
    }

    func testRefreshedAccountCookieIsUsedForLaterDownload() async throws {
        var refreshed: String?
        CloudMockProtocol.handler = { request in
            if request.url!.path.hasSuffix("/token") {
                return (200, ["Set-Cookie": "__puus=new-session; Path=/; Secure"],
                        ["status": 200, "data": ["stoken": "st"]])
            }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")!.contains("__puus=new-session"))
            return (200, [:], ["status": 200, "data": [
                ["download_url": "https://cdn.example.test/file", "size": 1]
            ]])
        }
        let api = client(.quark, cookie: "__pus=account; __puus=old-session") { refreshed = $0 }
        let result = try await api.download(
            file: CloudFile(id: "f", name: "file", size: 1, isDirectory: false, parentID: "0", token: "ft"),
            share: CloudShare(provider: .quark, shareID: "s123", passcode: ""))
        XCTAssertTrue(refreshed?.contains("__puus=new-session") == true)
        XCTAssertTrue(result.headers["Cookie"]!.contains("__pus=account"))
        XCTAssertTrue(result.headers["Cookie"]!.contains("__puus=new-session"))
    }

    func testApplicationErrorNeverExposesServerEchoedCredentials() async throws {
        CloudMockProtocol.handler = { _ in
            (200, [:], ["status": 200, "code": 31001, "message": "SECRET_COOKIE", "data": ["list": []]])
        }
        do {
            _ = try await client(.quark, cookie: "cookie").list(share: nil)
            XCTFail("Expected an account error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("登录"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET_COOKIE"))
        }
    }

    func testTokenFailureDoesNotBecomeAnEmptyFolder() async throws {
        CloudMockProtocol.handler = { _ in (200, [:], ["status": 200, "data": [:]]) }
        do {
            _ = try await client(.quark).list(share: CloudShare(provider: .quark, shareID: "s123", passcode: ""))
            XCTFail("Missing token must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("令牌")) }
    }

    func testCrossOriginRedirectDropsOnlySensitiveHeaders() {
        let original = URL(string: "https://cdn.example.test/a")!
        let headers = ["Cookie": "secret", "Authorization": "Bearer token", "User-Agent": "agent", "Referer": "https://pan.quark.cn/"]
        XCTAssertEqual(DownloadHeaders.redirectHeaders(headers, original: original,
                                                       target: URL(string: "https://cdn.example.test/b")!), headers)
        let cross = DownloadHeaders.redirectHeaders(headers, original: original,
                                                     target: URL(string: "https://other.example.test/b")!)
        XCTAssertNil(cross["Cookie"])
        XCTAssertNil(cross["Authorization"])
        XCTAssertEqual(cross["User-Agent"], "agent")
        XCTAssertNil(DownloadHeaders.redirectHeaders(headers, original: original,
                                                      target: URL(string: "http://cdn.example.test/a")!)["Cookie"])
    }

    func testPreviousDownloadRecordsRemainDecodable() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "url": "https://example.test/file",
            "filename": "file", "state": "paused", "received": 123, "expected": 456
        ])
        let item = try JSONDecoder().decode(DownloadItem.self, from: data)
        XCTAssertEqual(item.received, 123)
        XCTAssertNil(item.requiresHeaders)
        XCTAssertNil(item.requiredSize)
    }
}

private final class MutationPolls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

extension CloudDriveTests {
    func testQuarkAndUCSaveUseFileTokensAndWaitForConfirmedCompletion() async throws {
        defer { CloudMockProtocol.handler = nil }
        for provider in [CloudProvider.quark, .uc] {
            let polls = MutationPolls()
            CloudMockProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, provider.apiHost)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test-only-cookie")
                let path = request.url!.path
                if path.hasSuffix("/token") { return (200, [:], ["status": 200, "data": ["stoken": "share-access"]]) }
                if path.hasSuffix("/save") {
                    let body = try self.body(request)
                    XCTAssertEqual(body["stoken"] as? String, "share-access")
                    XCTAssertEqual(body["fid_token_list"] as? [String], ["file-access"])
                    XCTAssertEqual(body["pdir_fid"] as? String, "share-parent")
                    XCTAssertEqual(body["to_pdir_fid"] as? String, "destination")
                    return (200, [:], ["status": 200, "data": ["task_id": "save-task"]])
                }
                XCTAssertEqual(path, "/1/clouddrive/task")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first(where: { $0.name == "task_id" })?.value, "save-task")
                return (200, [:], ["status": 200, "data": ["status": polls.next() < 2 ? 1 : 2]])
            }
            let client = client(provider, cookie: "test-only-cookie")
            let file = CloudFile(id: "file", name: "fixture.bin", size: 10, isDirectory: false, parentID: "share-parent", token: "file-access")
            try await client.mutate(.save(file: file, share: CloudShare(provider: provider, shareID: "share", passcode: ""), parent: "destination"))
            XCTAssertEqual(polls.count, 2)
        }
    }
    func testRenameCanAcknowledgeEmptyDataButFailedAsyncTaskNeverSucceeds() async throws {
        CloudMockProtocol.handler = { request in
            if request.url?.path.hasSuffix("/rename") == true { return (200, [:], ["status": 200, "data": NSNull()]) }
            if request.url?.path.hasSuffix("/move") == true { return (200, [:], ["status": 200, "data": ["task_id": "failed-task"]]) }
            return (200, [:], ["status": 200, "data": ["status": 3]])
        }
        defer { CloudMockProtocol.handler = nil }
        let client = client(.quark, cookie: "test-only-cookie")
        let file = CloudFile(id: "file", name: "old.bin", size: 10, isDirectory: false, parentID: "0", token: "")
        try await client.mutate(.rename(file: file, name: "new.bin"))
        do { try await client.mutate(.move(file: file, parent: "target")); XCTFail("Failed async operation must not appear successful") }
        catch { XCTAssertTrue(error.localizedDescription.contains("操作失败")) }
    }
}
