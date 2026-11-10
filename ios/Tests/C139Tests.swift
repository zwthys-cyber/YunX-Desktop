// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class C139Tests: XCTestCase {
    private let account = "13900000000"
    private var authorization: String { "Basic " + Data("pc:\(account):fixture-token".utf8).base64EncodedString() }
    private func client(guest: Bool = false) -> CloudClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PageMockProtocol.self]
        return CloudClient(provider: .c139, cookie: guest ? "" : "authorization=" + authorization + "; unrelated=must-not-send", session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    nonisolated private static func body(_ request: URLRequest, encrypted: Bool) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        if encrypted { data = try C139Protocol.decrypt(String(decoding: data, as: UTF8.self)) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    nonisolated private static func response(_ data: [String: Any], share: Bool = false, encrypted: Bool = false) throws -> (Int, [String: String], Data) {
        let root: [String: Any] = [share ? "resultCode" : "code": "0", "success": true, "data": data]
        let raw = try JSONSerialization.data(withJSONObject: root)
        return (200, [:], encrypted ? Data(try C139Protocol.encrypt(raw).utf8) : raw)
    }
    func testIndependentJavaSignatureCBCAndGzipVectors() throws {
        let url = try XCTUnwrap(Bundle(for: C139Tests.self).url(forResource: "c139-vectors", withExtension: "json"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let plain = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["plainBase64"])))
        XCTAssertEqual(try C139Protocol.decrypt(XCTUnwrap(vector["cipher"])), plain)
        XCTAssertEqual(try C139Protocol.decrypt(XCTUnwrap(vector["gzipCipher"])), plain)
        XCTAssertEqual(try C139Protocol.encrypt(plain, iv: Data((0..<16).map(UInt8.init))), vector["cipher"])
        XCTAssertEqual(try C139Protocol.sign(String(decoding: plain, as: UTF8.self), timestamp: XCTUnwrap(vector["timestamp"]), random: XCTUnwrap(vector["random"])), vector["sign"])
        XCTAssertThrowsError(try C139Protocol.decrypt("invalid"))
        XCTAssertThrowsError(try C139Protocol.encrypt(plain, iv: Data()))
    }
    func testFragmentLinkAndIdentityRejectMismatchedCredentials() throws {
        let share = try CloudShare.parse("https://yun.139.com/shareweb/#/w/i/abc-_DEF 提取码：1234")
        XCTAssertEqual(share.provider, .c139); XCTAssertEqual(share.shareID, "abc-_DEF"); XCTAssertEqual(share.passcode, "1234")
        XCTAssertEqual(try CloudShare.parse("https://yun.139.com/shareweb/?pwd=1234#/w/i/abc").passcode, "1234")
        XCTAssertThrowsError(try CloudShare.parse("https://yun.139.com.evil.test/shareweb/#/w/i/abc"))
        XCTAssertEqual(try C139Protocol.identity(cookie: "authorization=" + authorization, fields: [:]).account, account)
        XCTAssertThrowsError(try C139Protocol.identity(cookie: "authorization=" + authorization, fields: ["account": "other"]))
        XCTAssertThrowsError(try C139Protocol.identity(cookie: "Os_SSo_Sid=fixture; RMKEY=fixture", fields: [:]))
    }
    func testAnonymousShareIsEncryptedWithoutAccountHeadersAndIncludesSubdirectories() async throws {
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "share-kd-njs.yun.139.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "hcy-cool-flag"), "1")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "mcloud-sign"))
            let body = try Self.body(request, encrypted: true), info = try XCTUnwrap(body["getOutLinkInfoReq"] as? [String: Any])
            XCTAssertEqual(info["account"] as? String, ""); XCTAssertEqual(info["passwd"] as? String, "1234")
            if info["pCaID"] as? String == "root" {
                return try Self.response(["caLst": [["caID": "folder", "caName": "folder"]], "coLst": [["coID": "file", "coName": "fixture.bin", "coSize": 10]]], share: true, encrypted: true)
            }
            XCTAssertEqual(info["pCaID"] as? String, "folder")
            return try Self.response(["caLst": [], "coLst": []], share: true)
        }
        defer { PageMockProtocol.handler = nil }
        let client = client(), share = CloudShare(provider: .c139, shareID: "fixture", passcode: "1234")
        let root = try await client.listPage(share: share)
        XCTAssertEqual(root.files.count, 2); XCTAssertTrue(root.files[0].isDirectory); XCTAssertFalse(root.hasMore)
        let child = try await client.listPage(share: share, parentID: "folder")
        XCTAssertTrue(child.files.isEmpty)
    }
    func testPrivateCursorContinuesShortPageAndCDNReceivesNoCredentials() async throws {
        let authorization = self.authorization
        PageMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), authorization)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "mcloud-client"), "10701")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-yun-channel-source"), "10000034")
            let body = try Self.body(request, encrypted: false)
            let signParts = try XCTUnwrap(request.value(forHTTPHeaderField: "mcloud-sign")).split(separator: ",").map(String.init)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            XCTAssertEqual(signParts.count, 3); XCTAssertEqual(C139Protocol.sign(json, timestamp: signParts[0], random: signParts[1]), signParts[2])
            if request.url?.path.hasSuffix("getDownloadUrl") == true { return try Self.response(["url": "https://cdn.example.test/file", "size": 10]) }
            let page = try XCTUnwrap(body["pageInfo"] as? [String: Any]), second = page["pageCursor"] as? String == "next"
            return try Self.response(["items": [["fileId": second ? "second" : "first", "name": "fixture.bin", "type": "file", "size": 10]], "nextPageCursor": second ? "" : "next"])
        }
        defer { PageMockProtocol.handler = nil }
        let client = client(), first = try await client.listPage(share: nil)
        XCTAssertTrue(first.hasMore)
        let second = try await client.listPage(share: nil, page: 2)
        XCTAssertFalse(second.hasMore); XCTAssertEqual(second.files.first?.id, "second")
        let plan = try await client.download(file: XCTUnwrap(first.files.first), share: nil)
        XCTAssertNil(plan.headers["Authorization"]); XCTAssertNil(plan.headers["Cookie"])
    }
    func testTaskAtOneHundredPercentStillRejectsFailedItems() async throws {
        PageMockProtocol.handler = { request in
            if request.url?.path.hasSuffix("batchMove") == true { return try Self.response(["taskId": "move"]) }
            return try Self.response(["taskInfo": ["status": "Succeed", "progress": 100], "batchFileResults": [["fileId": "file", "errCode": "failed"]]])
        }
        defer { PageMockProtocol.handler = nil }
        do { try await client().mutate(.move(file: CloudFile(id: "file", name: "fixture", size: 1, isDirectory: false, parentID: "/", token: ""), parent: "target")); XCTFail("Failed item must prevent success") } catch { XCTAssertTrue(error.localizedDescription.contains("失败项")) }
    }
    func testBadPasscodeIsNotAnEmptyFolder() async throws {
        PageMockProtocol.handler = { _ in (200, [:], try JSONSerialization.data(withJSONObject: ["resultCode": "9188", "success": false])) }
        defer { PageMockProtocol.handler = nil }
        do { _ = try await client(guest: true).list(share: CloudShare(provider: .c139, shareID: "fixture", passcode: "bad")); XCTFail("Must reject") } catch { XCTAssertTrue(error.localizedDescription.contains("提取码")) }
    }
}
