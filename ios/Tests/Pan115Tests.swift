// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class Pan115Polls: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor
final class Pan115Tests: XCTestCase {
    private func client() -> CloudClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]; config.httpCookieStorage = nil
        return CloudClient(provider: .pan115, cookie: "UID=fixture-user; CID=fixture-client; SEID=fixture-session", session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    nonisolated private static func query(_ request: URLRequest) -> [String: String] {
        (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }
    func testCryptoMatchesJavaPublicExponentAndSyntheticServerResponseAcrossBlocks() throws {
        let url = try XCTUnwrap(Bundle(for: Pan115Tests.self).url(forResource: "pan115-vectors", withExtension: "json"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let key = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["key"])))
        let payload = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["requestPayload"])))
        XCTAssertEqual(try Pan115Crypto.encode(String(decoding: payload, as: UTF8.self), key: key), vector["requestEncoded"])
        let decoded = try Pan115Crypto.decode(XCTUnwrap(vector["responseEncoded"]), key: key, modulus: XCTUnwrap(vector["syntheticModulus"]))
        XCTAssertEqual(decoded, try XCTUnwrap(Data(base64Encoded: XCTUnwrap(vector["responsePlain"]))))
        XCTAssertThrowsError(try Pan115Crypto.decode("invalid", key: key))
        XCTAssertThrowsError(try Pan115Crypto.encode("fixture", key: Data()))
        XCTAssertThrowsError(try Pan115Crypto.decode(String(repeating: "A", count: 172), key: key))
    }
    func testShareHostURLAndCommandAccessCodes() throws {
        let normal = try CloudShare.parse("https://115cdn.com/s/sw123456789?password=abcd")
        XCTAssertEqual(normal.provider, .pan115); XCTAssertEqual(normal.passcode, "abcd")
        XCTAssertEqual(try CloudShare.parse("https://115.com/sw123456789-n307/").passcode, "n307")
        XCTAssertEqual(try CloudShare.parse("https://115rc.com/s/sw123456789 访问码：abcd", override: "manual").passcode, "manual")
        XCTAssertThrowsError(try CloudShare.parse("https://115.com.evil.test/s/sw123456789"))
    }
    func testPersonalListUsesOffsetAndDistinctDirectoryID() async throws {
        MediaMockProtocol.handler = { request in
            let second = Self.query(request)["offset"] == "1"
            if second { return (200, [:], ["state": true, "count": 2, "data": [["fid": "file", "cid": "0", "n": "fixture.bin", "s": 10, "pc": "pickcode"]]]) }
            XCTAssertEqual(Self.query(request)["cid"], "0")
            return (200, [:], ["state": true, "count": 2, "data": [["cid": "folder", "pid": "0", "n": "folder"]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), first = try await client.listPage(share: nil)
        XCTAssertTrue(first.hasMore); XCTAssertTrue(try XCTUnwrap(first.files.first).isDirectory)
        let second = try await client.listPage(share: nil, page: 2)
        XCTAssertFalse(second.hasMore); XCTAssertEqual(second.files.first?.token, "pickcode")
    }
    func testShareUsesOwnerIdentityAndBindsDownloadOnlyCookieToCDNPath() async throws {
        MediaMockProtocol.handler = { request in
            switch request.url?.path {
            case "/1/web/1.0/api/chrome":
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (200, [:], ["data": ["win": ["version_code": "40.1.2"]]])
            case "/share/snap": return (200, [:], ["state": true, "data": ["count": 1, "userinfo": ["user_id": "owner"], "list": [["fid": "file", "fc": 1, "n": "fixture.bin", "s": 10]]]])
            default:
                XCTAssertEqual(Self.query(request)["user_id"], "owner")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 115Browser/40.1.2")
                return (200, ["Set-Cookie": "download-key=fixture-ticket; Path=/object/; Secure"], ["state": true, "data": ["file_url_302": "https://cdn.example.test/object/file", "fn": "fixture.bin", "fs": 10]])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), share = CloudShare(provider: .pan115, shareID: "swfixture", passcode: "1234")
        let files = try await client.list(share: share)
        let plan = try await client.download(file: XCTUnwrap(files.first), share: share)
        XCTAssertEqual(plan.headers["Cookie"], "download-key=fixture-ticket")
        XCTAssertFalse(plan.headers["Cookie"]?.contains("SEID") == true)
    }
    func testClientFailureFallsBackToWebDownloadWithoutSendingLoginToExternalCDN() async throws {
        MediaMockProtocol.handler = { request in
            if request.url?.host == "appversion.115.com" { return (200, [:], [:]) }
            if request.url?.host == "proapi.115.com" { XCTAssertEqual(request.httpMethod, "POST"); return (200, [:], ["state": false, "errno": 50029]) }
            XCTAssertEqual(request.url?.path, "/files/download")
            return (200, ["Set-Cookie": "unrelated=must-not-send; Path=/other/; Secure"], ["state": true, "data": ["file_url": "https://cdn.example.test/object/file", "file_name": "fixture.bin", "file_size": 10]])
        }
        defer { MediaMockProtocol.handler = nil }
        let plan = try await client().download(file: CloudFile(id: "42", name: "fixture.bin", size: 10, isDirectory: false, parentID: "0", token: "pickcode"), share: nil)
        XCTAssertNil(plan.headers["Cookie"])
    }
    func testMoveDoesNotInterpretMissingCountAsCompletion() async throws {
        let polls = Pan115Polls()
        MediaMockProtocol.handler = { request in
            if request.httpMethod == "POST" { return (200, [:], ["state": true, "move_proid": "move-task"]) }
            return (200, [:], ["state": true, "data": ["percent": polls.next() == 1 ? 0 : 100]])
        }
        defer { MediaMockProtocol.handler = nil }
        try await client().mutate(.move(file: CloudFile(id: "42", name: "fixture", size: 1, isDirectory: false, parentID: "0", token: ""), parent: "target"))
        XCTAssertEqual(polls.count, 2)
    }
    func testInvalidCodeNeverReturnsEmptyDirectory() async throws {
        MediaMockProtocol.handler = { _ in (200, [:], ["state": false, "errno": 4100008]) }
        defer { MediaMockProtocol.handler = nil }
        do { _ = try await client().list(share: CloudShare(provider: .pan115, shareID: "swfixture", passcode: "bad")); XCTFail("Must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("访问码")) }
    }
}
