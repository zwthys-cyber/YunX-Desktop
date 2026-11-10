// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class ILanzouTests: XCTestCase {
    private let fixtureToken = "test:token+with/slash=&%"
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
    func testAESMatchesIndependentDesktopJavaAndTokenEncoding() throws {
        let url = try XCTUnwrap(Bundle(for: ILanzouTests.self).url(forResource: "ilanzou-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 4)
        for vector in vectors { XCTAssertEqual(try ILanzouProtocol.aesHex(XCTUnwrap(vector["plain"])), vector["hex"]) }
        XCTAssertEqual(ILanzouProtocol.encode("a:b+c/=&% ?"), "a:b%2Bc%2F%3D%26%25+%3F")
        XCTAssertEqual(try ILanzouProtocol.rawID("d:123"), "123")
        XCTAssertThrowsError(try ILanzouProtocol.rawID("f:../123"))
        XCTAssertEqual(try CloudShare.parse("https://www.ilanzou.net/s/share-id").provider, .ilanzou)
        XCTAssertThrowsError(try CloudShare.parse("https://www.ilanzou.com.evil.test/s/share"))
    }
    func testLoginPersistsOfficialUUIDAndEncodesReservedTokenCharacters() async throws {
        let token = fixtureToken
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "apis.ilanzou.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url?.path == "/unproved/getUuid" { return (200, [:], ["code": 200, "uuid": "fixture_uuid_123"]) }
            XCTAssertEqual(query.first(where: { $0.name == "uuid" })?.value, "fixture_uuid_123")
            if request.url?.path == "/unproved/login" {
                let body = try Self.body(request)
                XCTAssertEqual(body["loginName"] as? String, "account")
                XCTAssertEqual(body["loginPwd"] as? String, " password ")
                return (200, [:], ["code": 200, "data": ["appToken": token]])
            }
            XCTAssertEqual(query.first(where: { $0.name == "appToken" })?.value, token)
            XCTAssertTrue(request.url!.absoluteString.contains("appToken=test:token%2Bwith%2Fslash%3D%26%25"))
            return (200, [:], ["code": 200, "map": ["userId": 42, "nickName": "测试"]])
        }
        defer { MediaMockProtocol.handler = nil }
        let (saved, fields) = try await ILanzouClient(session: session()).login(account: " account ", password: " password ")
        XCTAssertEqual(saved, token); XCTAssertEqual(fields["uuid"], "fixture_uuid_123"); XCTAssertEqual(fields["userId"], "42")
    }
    func testShareNamespacePaginationAndRedirectDoNotLeakAppToken() async throws {
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "apix.ilanzou.com")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(query.contains { $0.name == "appToken" })
            XCTAssertEqual(query.first(where: { $0.name == "shareId" })?.value, "share")
            if request.url?.path == "/unproved/file/redirect" {
                XCTAssertEqual(query.first(where: { $0.name == "downloadId" })?.value, try ILanzouProtocol.aesHex("7|42"))
                XCTAssertFalse(query.contains { $0.name == "extra" })
                return (302, ["Location": "https://cdn.example.test/file.bin"], [:])
            }
            XCTAssertFalse(query.contains { $0.name == "folderId" })
            XCTAssertEqual(query.first(where: { $0.name == "devModel" })?.value, "Chrome")
            return (200, [:], ["code": 200, "totalPage": 1, "list": [
                ["fileType": 2, "folderId": 7, "folderName": "目录"],
                ["fileType": 1, "fileId": 7, "fileName": "file.bin", "fileSize": 1]
            ]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .ilanzou, cookie: fixtureToken, fields: ["uuid": "fixture_uuid_123", "userId": "42"], session: session())
        let share = CloudShare(provider: .ilanzou, shareID: "share", passcode: "")
        let files = try await client.list(share: share)
        XCTAssertEqual(files.map(\.id), ["d:7", "f:7"])
        let last = try await client.list(share: share, page: 2)
        XCTAssertTrue(last.isEmpty)
        let download = try await client.download(file: files[1], share: share)
        XCTAssertEqual(download.url.host, "cdn.example.test")
        XCTAssertEqual(download.size, 0, "Rounded KiB must not be used as exact download size")
        XCTAssertNil(download.headers["Authorization"]); XCTAssertNil(download.headers["Cookie"])
    }
    func testFileAndFolderMutationsKeepSeparateNamespaces() async throws {
        MediaMockProtocol.handler = { request in
            let body = try Self.body(request)
            XCTAssertEqual(request.url?.path, "/proved/file/folder/move")
            XCTAssertEqual(body["folderIds"] as? String, "7")
            XCTAssertEqual(body["fileIds"] as? String, "")
            XCTAssertEqual(body["targetId"] as? String, "8")
            return (200, [:], ["code": 200])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .ilanzou, cookie: fixtureToken, fields: ["uuid": "fixture_uuid_123"], session: session())
        let folder = CloudFile(id: "d:7", name: "目录", size: 0, isDirectory: true, parentID: "0", token: "")
        try await client.mutate(.move(file: folder, parent: "d:8"))
        do { try await client.mutate(.move(file: folder, parent: "d:7")); XCTFail("Self move must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("自身")) }
    }
    func testShortPersonalPageUsesReportedTotalPage() async throws {
        MediaMockProtocol.handler = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first(where: { $0.name == "offset" })?.value ?? "1"
            return (200, [:], ["code": 200, "totalPage": 2, "list": [["fileType": 1, "fileId": page, "fileName": "fixture.bin", "fileSize": 1]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = CloudClient(provider: .ilanzou, cookie: fixtureToken, fields: ["uuid": "fixture_uuid_123"], session: session())
        let first = try await client.listPage(share: nil)
        let second = try await client.listPage(share: nil, page: 2)
        XCTAssertTrue(first.hasMore); XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.files.count, 1); XCTAssertEqual(second.files.first?.id, "f:2")
    }
}
