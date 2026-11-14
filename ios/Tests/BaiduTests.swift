// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class BaiduCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class BaiduTests: XCTestCase {
    private func client(cookie: String = "BDUSS=test-only; STOKEN=fixture") -> CloudClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        return CloudClient(provider: .baidu, cookie: cookie, session: URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil))
    }
    nonisolated private static func query(_ request: URLRequest) -> [String: String] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }
    nonisolated private static func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return String(decoding: data, as: UTF8.self).split(separator: "&").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            result[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
        }
    }
    nonisolated private static func row(id: String = "42", path: String = "/folder", folder: Bool = true) -> [String: Any] {
        ["fs_id": id, "server_filename": folder ? "folder" : "fixture.bin", "path": path, "isdir": folder ? 1 : 0, "size": 10]
    }
    func testShareParserAndExactFormEncoding() throws {
        let share = try CloudShare.parse("https://pan.baidu.com/s/1abc-_DEF?pwd=1234")
        XCTAssertEqual(share.shareID, "1abc-_DEF"); XCTAssertEqual(share.provider, .baidu); XCTAssertEqual(share.passcode, "1234")
        XCTAssertThrowsError(try CloudShare.parse("https://pan.baidu.com/s/abc"))
        XCTAssertThrowsError(try CloudShare.parse("https://pan.baidu.com.evil.test/s/1abc"))
        XCTAssertEqual(FormEncoding.encode("a+b= c:中文"), "a%2Bb%3D+c%3A%E4%B8%AD%E6%96%87")
        XCTAssertEqual(ILanzouProtocol.encode("a:b c"), "a:b+c")
    }
    func testShareSecretAndChildDirectoryPreserveEncodingAndPagination() async throws {
        let verifies = BaiduCounter()
        MediaMockProtocol.handler = { request in
            let query = Self.query(request)
            if request.url?.path == "/share/verify" {
                _ = verifies.next(); XCTAssertEqual(query["surl"], "abc-_DEF")
                XCTAssertEqual(Self.form(request)["pwd"], "1234")
                return (200, [:], ["errno": 0, "randsk": "share%2Bkey%3D"])
            }
            XCTAssertEqual(query["sekey"], "share+key=")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("BDCLND=share%2Bkey%3D") == true)
            XCTAssertEqual(query["root"], query["dir"] == "/" ? "1" : "0")
            return (200, [:], ["errno": 0, "share_id": 7, "uk": 8, "has_more": query["page"] == "1" && query["dir"] == "/" ? 1 : 0, "list": [Self.row()]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(cookie: ""), share = CloudShare(provider: .baidu, shareID: "1abc-_DEF", passcode: "1234")
        let first = try await client.listPage(share: share)
        XCTAssertTrue(first.hasMore); XCTAssertEqual(first.files.first?.id, "/folder")
        let second = try await client.listPage(share: share, page: 2)
        XCTAssertFalse(second.hasMore)
        _ = try await client.listPage(share: share, parentID: "/folder")
        XCTAssertEqual(verifies.count, 1)
    }
    func testExpiredCSRFRefreshesOnceAndKeepsActualPage() async throws {
        let profiles = BaiduCounter(), lists = BaiduCounter()
        MediaMockProtocol.handler = { request in
            if request.url?.path == "/api/gettemplatevariable" { return (200, [:], ["errno": 0, "result": ["username": "fixture", "bdstoken": profiles.next() == 1 ? "old" : "new"]]) }
            let query = Self.query(request); XCTAssertEqual(query["page"], "2")
            if lists.next() == 1 { XCTAssertEqual(query["bdstoken"], "old"); return (200, [:], ["errno": -6]) }
            XCTAssertEqual(query["bdstoken"], "new")
            return (200, [:], ["errno": 0, "list": [Self.row()]])
        }
        defer { MediaMockProtocol.handler = nil }
        _ = try await client().listPage(share: nil, page: 2)
        XCTAssertEqual(profiles.count, 2); XCTAssertEqual(lists.count, 2)
    }
    func testRejectedPersonalLoginOffersReloginWithoutPasscodeAdvice() async throws {
        let requests = BaiduCounter()
        MediaMockProtocol.handler = { request in
            _ = requests.next()
            XCTAssertEqual(request.url?.path, "/api/gettemplatevariable")
            return (200, [:], ["errno": -6])
        }
        defer { MediaMockProtocol.handler = nil }
        do {
            _ = try await client().listPage(share: nil)
            XCTFail("Rejected login must not appear as an empty directory")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重新网页登录"))
            XCTAssertTrue(error.localizedDescription.contains("-6"))
            XCTAssertFalse(error.localizedDescription.contains("提取码"))
        }
        XCTAssertEqual(requests.count, 1)
    }
    func testFreshClientPrimesShareRootBeforeDeepFolderTransfer() async throws {
        let roots = BaiduCounter()
        MediaMockProtocol.handler = { request in
            switch request.url?.path {
            case "/api/gettemplatevariable": return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"]])
            case "/share/transfer":
                XCTAssertEqual(Self.query(request)["shareid"], "7")
                XCTAssertEqual(Self.query(request)["from"], "8")
                XCTAssertEqual(Self.form(request)["fsidlist"], "[\"42\"]")
                return (200, [:], ["errno": 0, "extra": ["list": [["to_fs_id": 99]]]])
            default:
                if Self.query(request)["dir"] == "/" {
                    _ = roots.next()
                    return (200, [:], ["errno": 0, "share_id": 7, "uk": 8, "list": [Self.row()]])
                }
                return (200, [:], ["errno": 0, "list": [Self.row(path: "/folder/fixture.bin", folder: false)]])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), share = CloudShare(provider: .baidu, shareID: "1share", passcode: "")
        let files = try await client.list(share: share, parentID: "/folder")
        try await client.mutate(.save(file: XCTUnwrap(files.first), share: share, parent: "/target"))
        XCTAssertEqual(roots.count, 1)
    }
    func testDownloadSkipsEncryptedCandidateAndDoesNotForwardCookie() async throws {
        MediaMockProtocol.handler = { request in
            if request.url?.host == "cdn.example.test" {
                XCTAssertEqual(request.url?.path, "/plain")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-0")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                return (206, ["Content-Range": "bytes 0-0/10", "Content-Type": "application/octet-stream"], [:])
            }
            if request.url?.host == "d.pcs.baidu.com" {
                XCTAssertEqual(Self.query(request)["path"], "/fixture.bin")
                return (200, [:], ["errno": 0, "urls": [["url": "https://cdn.example.test/encrypted", "encrypt": 1, "rank": 1], ["url": "https://cdn.example.test/plain", "encrypt": 0, "rank": 2]]])
            }
            if request.url?.path == "/api/gettemplatevariable" { return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"]]) }
            return (200, [:], ["errno": 0, "list": [Self.row(path: "/fixture.bin", folder: false)]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), files = try await client.list(share: nil)
        let plan = try await client.download(file: XCTUnwrap(files.first), share: nil)
        XCTAssertEqual(plan.url.path, "/plain"); XCTAssertNil(plan.headers["Cookie"]); XCTAssertNil(plan.headers["Authorization"])
        XCTAssertFalse(plan.allowsBackground)
    }
    func testFolderTransferUsesFSIDAndRenameJSONCannotBeInjected() async throws {
        MediaMockProtocol.handler = { request in
            switch request.url?.path {
            case "/api/gettemplatevariable": return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"]])
            case "/share/transfer":
                let form = Self.form(request)
                XCTAssertEqual(form["fsidlist"], "[\"42\"]"); XCTAssertEqual(form["path"], "/target")
                return (200, [:], ["errno": 0, "extra": ["list": [["to_fs_id": 99]]]])
            case "/api/filemanager":
                XCTAssertEqual(Self.query(request)["async"], "0")
                let form = Self.form(request)
                let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(form["filelist"]).utf8)) as? [[String: String]])
                XCTAssertEqual(entries.first?["newname"], "quoted\"name"); XCTAssertEqual(entries.first?["path"], "/folder")
                return (200, [:], ["errno": 0])
            default: return (200, [:], ["errno": 0, "share_id": 7, "uk": 8, "list": [Self.row()]])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), share = CloudShare(provider: .baidu, shareID: "1share", passcode: "")
        let files = try await client.list(share: share)
        let folder = try XCTUnwrap(files.first)
        try await client.mutate(.save(file: folder, share: share, parent: "/target"))
        try await client.mutate(.rename(file: folder, name: "quoted\"name"))
        do { try await client.mutate(.move(file: folder, parent: "/folder/child")); XCTFail("Self descendant move must fail") } catch { }
    }
    func testRejectedFirstCDNFallsBackToNextWithoutSendingAccountCookie() async throws {
        let probes = BaiduCounter()
        MediaMockProtocol.handler = { request in
            switch request.url?.host {
            case "d.pcs.baidu.com": return (200, [:], ["errno": 0, "urls": [["url": "https://cdn.example.test/rejected", "encrypt": 0, "rank": 1], ["url": "https://cdn.example.test/working", "encrypt": 0, "rank": 2]]])
            case "cdn.example.test":
                _ = probes.next()
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-0")
                if request.url?.path == "/rejected" { return (403, ["Content-Length": "82"], ["error": "rejected"]) }
                return (206, ["Content-Range": "bytes 0-0/10"], [:])
            default: return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"], "list": [Self.row(path: "/fixture.bin", folder: false)]])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), files = try await client.list(share: nil)
        let plan = try await client.download(file: XCTUnwrap(files.first), share: nil)
        XCTAssertEqual(plan.url.path, "/working"); XCTAssertEqual(probes.count, 2)
    }
    func testMetadataFallbackUsesBaiduDownloadUAAndResolvesHTTPSRedirect() async throws {
        MediaMockProtocol.handler = { request in
            if ["cdn.example.test", "other.example.test"].contains(request.url?.host ?? "") {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), "CDN must not receive account credentials")
            }
            switch request.url?.host {
            case "d.pcs.baidu.com": return (200, [:], ["errno": 0, "urls": []])
            case "cdn.example.test":
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pan.baidu.com")
                return (302, ["Location": "https://other.example.test/final"], [:])
            case "other.example.test":
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pan.baidu.com")
                return (206, ["Content-Range": "bytes 0-0/10"], [:])
            default:
                if request.url?.path == "/api/filemetas" { return (200, [:], ["errno": 0, "info": [["dlink": "https://cdn.example.test/start"]]]) }
                return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"], "list": [Self.row(path: "/fixture.bin", folder: false)]])
            }
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), files = try await client.list(share: nil)
        let plan = try await client.download(file: XCTUnwrap(files.first), share: nil)
        XCTAssertEqual(plan.url.host, "other.example.test")
        XCTAssertFalse(plan.allowsBackground)
        XCTAssertNil(plan.headers["Range"])
    }
    func testAllDeniedLinksFailBeforeCreatingDownloadPlan() async throws {
        MediaMockProtocol.handler = { request in
            if request.url?.host == "cdn.example.test" { return (403, ["Content-Length": "82"], ["error": "rejected"]) }
            if request.url?.host == "d.pcs.baidu.com" { return (200, [:], ["errno": 0, "urls": [["url": "https://cdn.example.test/denied", "encrypt": 0]]]) }
            if request.url?.path == "/api/filemetas" { return (200, [:], ["errno": 0, "info": [["dlink": "https://cdn.example.test/also-denied"]]]) }
            return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"], "list": [Self.row(path: "/fixture.bin", folder: false)]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), files = try await client.list(share: nil)
        do { _ = try await client.download(file: XCTUnwrap(files.first), share: nil); XCTFail("Must not queue a rejected address") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
            XCTAssertTrue(error.localizedDescription.contains("未创建下载任务"))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }
    }
    func testPreflightRejectsWrongSizeRangeAndUnsafeRedirects() async throws {
        for mode in ["size", "range", "redirect"] {
            MediaMockProtocol.handler = { request in
                XCTAssertEqual(request.url?.scheme, "https")
                if request.url?.host == "cdn.example.test" {
                    if mode == "size" { return (200, ["Content-Length": "82"], [:]) }
                    if mode == "range" { return (206, ["Content-Range": "bytes 0-0/82"], [:]) }
                    return (302, ["Location": "http://unsafe.example.test/private"], [:])
                }
                if request.url?.host == "d.pcs.baidu.com" { return (200, [:], ["errno": 0, "urls": [["url": "https://cdn.example.test/download", "encrypt": 0]]]) }
                if request.url?.path == "/api/filemetas" { return (200, [:], ["errno": 0, "info": [["dlink": "https://cdn.example.test/fallback"]]]) }
                return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"], "list": [Self.row(path: "/fixture.bin", folder: false)]])
            }
            defer { MediaMockProtocol.handler = nil }
            let client = client(), files = try await client.list(share: nil)
            do { _ = try await client.download(file: XCTUnwrap(files.first), share: nil); XCTFail("Invalid response must be rejected: " + mode) }
            catch { XCTAssertTrue(error.localizedDescription.contains("未创建下载任务")) }
        }
    }
    func testCancelledProbeDoesNotRequestMetadataFallback() async throws {
        MediaMockProtocol.handler = { request in
            if request.url?.host == "cdn.example.test" { throw URLError(.cancelled) }
            if request.url?.host == "d.pcs.baidu.com" { return (200, [:], ["errno": 0, "urls": [["url": "https://cdn.example.test/download", "encrypt": 0]]]) }
            XCTAssertNotEqual(request.url?.path, "/api/filemetas")
            return (200, [:], ["errno": 0, "result": ["bdstoken": "fixture"], "list": [Self.row(path: "/fixture.bin", folder: false)]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = client(), files = try await client.list(share: nil)
        do { _ = try await client.download(file: XCTUnwrap(files.first), share: nil); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testInvalidPasscodeIsNotReportedAsEmptyDirectory() async throws {
        MediaMockProtocol.handler = { _ in (200, [:], ["errno": -9]) }
        defer { MediaMockProtocol.handler = nil }
        do { _ = try await client(cookie: "").list(share: CloudShare(provider: .baidu, shareID: "1share", passcode: "bad")); XCTFail("Must reject invalid share") } catch { XCTAssertTrue(error.localizedDescription.contains("提取码")) }
    }
}
