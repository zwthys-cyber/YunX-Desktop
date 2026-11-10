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
    func testPlatformErrorDoesNotEchoCredentials() async throws {
        MediaMockProtocol.handler = { _ in (200, [:], ["code": 401, "message": "test-secret-token", "data": [:]]) }
        defer { MediaMockProtocol.handler = nil }
        do {
            _ = try await Pan123Client(token: "test-secret-token", session: session()).validate()
            XCTFail("Expected platform rejection")
        } catch { XCTAssertFalse(error.localizedDescription.contains("test-secret-token")) }
    }
}
