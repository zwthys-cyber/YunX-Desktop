// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class Pan123Tests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        return URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
    }
    nonisolated private static func body(_ request: URLRequest) throws -> [String: Any] {
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
    func testShareHostsAndWrappedDownloadURLs() throws {
        XCTAssertEqual(try CloudShare.parse("https://www.123865.com/s/abc-DEF?pwd=1234").provider, .pan123)
        XCTAssertThrowsError(try CloudShare.parse("https://www.123865.com.evil.test/s/abc"))
        let direct = "https://cdn.example.test/file.bin?key=one&two=three"
        let base64 = Data(direct.utf8).base64EncodedString()
        XCTAssertEqual(try Pan123Signature.downloadURL(base64).absoluteString, direct)
        var parts = URLComponents(string: "https://www.123865.com/download-v2")!
        parts.queryItems = [URLQueryItem(name: "params", value: base64)]
        XCTAssertEqual(try Pan123Signature.downloadURL(parts.url!.absoluteString).absoluteString, direct)
        XCTAssertThrowsError(try Pan123Signature.downloadURL("http://cdn.example.test/file"))
        XCTAssertEqual(Pan123Signature.crc32("123456789"), "cbf43926")
        let first = Pan123Signature.make(path: "/b/api/user/info", timestamp: 1_700_000_000, random: 123)
        let second = Pan123Signature.make(path: "/b/api/file/list/new", timestamp: 1_700_000_000, random: 123)
        XCTAssertEqual(first.0, second.0)
        XCTAssertNotEqual(first.1, second.1)
    }
    func testLoginPreservesPasswordAndUsesOfficialLoginHost() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "user.123pan.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "app-version"), "132")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.body(request)
            XCTAssertEqual(body["password"] as? String, " pass word ")
            XCTAssertEqual(body["passport"] as? String, "account")
            return (200, [:], ["code": 200, "data": ["token": "test.jwt.token"]])
        }
        defer { MediaMockProtocol.handler = nil }
        let token = try await Pan123Client(token: "", session: session()).login(account: " account ", password: " pass word ")
        XCTAssertEqual(token, "test.jwt.token")
    }
    func testCursorPaginationAndShareDownloadDoNotLeakJWT() async throws {
        let direct = "https://cdn.example.test/file.bin"
        MediaMockProtocol.handler = { request in
            if request.url!.path == "/b/api/share/get" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertFalse(query.contains { $0.name == "SharePwd" })
                let page = query.first { $0.name == "Page" }!.value!
                if page == "2" { XCTAssertEqual(query.first { $0.name == "next" }?.value, "cursor-value") }
                return (200, [:], ["code": 0, "data": ["Next": page == "1" ? "cursor-value" : "-1", "InfoList": [["FileId": page, "FileName": "file.bin", "Size": 10, "Type": 0, "S3KeyFlag": "s3", "Etag": "etag"]]]])
            }
            XCTAssertEqual(request.url?.host, "www.123865.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "auth-key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "platform"), "android")
            return (200, [:], ["code": 0, "data": ["DownloadURL": Data(direct.utf8).base64EncodedString()]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = Pan123Client(token: "test-token", session: session())
        let share = CloudShare(provider: .pan123, shareID: "share", passcode: "")
        let first = try await client.list(share: share, parent: "0", page: 1)
        let second = try await client.list(share: share, parent: "0", page: 2)
        let end = try await client.list(share: share, parent: "0", page: 3)
        XCTAssertEqual(second.first?.id, "2")
        XCTAssertTrue(end.isEmpty)
        let download = try await client.download(file: XCTUnwrap(first.first), share: share)
        XCTAssertEqual(download.url.absoluteString, direct)
        XCTAssertNil(download.headers["Authorization"])
        XCTAssertNil(download.headers["Cookie"])
    }
    func testShortPagesRetainExplicitNextCursor() async throws {
        MediaMockProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let second = query.first(where: { $0.name == "Page" })?.value == "2"
            return (200, [:], ["code": 0, "data": ["Next": second ? "-1" : "next", "InfoList": [["FileId": second ? "2" : "1", "FileName": "fixture.bin", "Size": 10, "Type": 0, "Etag": "etag"]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .pan123, session: session())
        let share = CloudShare(provider: .pan123, shareID: "share", passcode: "")
        let first = try await client.listPage(share: share)
        let second = try await client.listPage(share: share, page: 2)
        XCTAssertEqual(first.files.count, 1); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.files.count, 1); XCTAssertFalse(second.hasMore)
    }
    func testPlatformErrorDoesNotEchoCredentials() async throws {
        MediaMockProtocol.handler = { _ in (200, [:], ["code": 401, "message": "test-secret-token", "data": [:]]) }
        defer { MediaMockProtocol.handler = nil }
        do {
            _ = try await Pan123Client(token: "test-secret-token", session: session()).validate()
            XCTFail("Expected platform rejection")
        } catch { XCTAssertFalse(error.localizedDescription.contains("test-secret-token")) }
    }
}

private final class Pan123MutationPolls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

extension Pan123Tests {
    func testShareTransferUsesNumericOfficialSubdomainWithoutClientSignature() async throws {
        let polls = Pan123MutationPolls()
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "1816216065.mshare.123pan.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-account")
            XCTAssertNil(request.value(forHTTPHeaderField: "auth-key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "auth-value"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "loginuuid"))
            if request.httpMethod == "POST" {
                let body = try Self.body(request)
                XCTAssertEqual(body["shareKey"] as? String, "share-key")
                XCTAssertEqual(body["sharePwd"] as? String, "")
                let file = try XCTUnwrap((body["fileList"] as? [[String: Any]])?.first)
                XCTAssertEqual(file["fileID"] as? Int, 7)
                XCTAssertEqual(file["fileId"] as? Int, 7)
                XCTAssertEqual(file["parentFileId"] as? Int, 8)
                XCTAssertEqual(file["S3KeyFlag"] as? String, "1816216065-0")
                return (200, [:], ["code": 0, "data": ["taskID": 99]])
            }
            // Ambiguous status 3 alone must not be reported as complete.
            return (200, [:], ["code": 0, "data": ["status": polls.next() == 1 ? 3 : 2]])
        }
        defer { MediaMockProtocol.handler = nil }
        let metadata = try JSONSerialization.data(withJSONObject: ["s3": "1816216065-0", "etag": "test-etag", "storage": "node"]).base64EncodedString()
        let file = CloudFile(id: "7", name: "fixture.bin", size: 10, isDirectory: false, parentID: "0", token: metadata)
        let client = CloudClient(provider: .pan123, cookie: "test-account", session: session())
        try await client.mutate(.save(file: file, share: CloudShare(provider: .pan123, shareID: "share-key", passcode: ""), parent: "8"))
        XCTAssertEqual(polls.count, 2)
    }
    func testCreateFolderSignsUploadRequestAndRenameAcceptsNullData() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "yun.123pan.cn")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "auth-key"))
            let body = try Self.body(request)
            if request.url?.path == "/b/api/file/upload_request" {
                XCTAssertEqual(body["type"] as? Int, 1)
                XCTAssertEqual(body["parentFileId"] as? Int, 0)
                XCTAssertEqual(body["fileName"] as? String, "new folder")
                XCTAssertEqual(body["NotReuse"] as? Bool, true)
                return (200, [:], ["code": 0, "data": ["Info": ["FileId": 10]]])
            }
            XCTAssertEqual(request.url?.path, "/b/api/file/rename")
            XCTAssertEqual(body["fileName"] as? String, "new.bin")
            return (200, [:], ["code": 0, "data": NSNull()])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .pan123, cookie: "test-account", session: session())
        try await client.mutate(.createFolder(name: "new folder", parent: "0"))
        try await client.mutate(.rename(file: CloudFile(id: "7", name: "old.bin", size: 10, isDirectory: false, parentID: "0", token: ""), name: "new.bin"))
    }
}
