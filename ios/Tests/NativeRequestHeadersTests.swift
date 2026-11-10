// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class NativeRequestHeadersTests: XCTestCase {
    func testContextSurvivesReloadAndRevokesAfterDeletion() throws {
        let service = "yunx.test-native-headers.\(UUID().uuidString)", id = UUID()
        let original = URL(string: "https://files.example.test/file?signature=fixture")!
        let values = ["Cookie": "fixture-cookie=private", "Authorization": "Bearer fixture", "User-Agent": "YunX-Fixture", "Sec-Ch-Ua": "fixture-browser-hint"]
        let store = NativeRequestHeaders(service: service)
        defer { store.delete(id) }
        try store.save(values, original: original, id: id)
        let reloaded = NativeRequestHeaders(service: service)
        XCTAssertEqual(try reloaded.headers(id: id, original: original.absoluteString, target: original), values)
        reloaded.delete(id)
        XCTAssertThrowsError(try reloaded.headers(id: id, original: original.absoluteString, target: original))
    }
    func testCredentialsAreBoundToOriginalAndExactOrigin() throws {
        let store = NativeRequestHeaders(service: "yunx.test-native-headers.\(UUID().uuidString)"), id = UUID()
        defer { store.delete(id) }
        let original = URL(string: "https://files.example.test/private")!
        try store.save(["Cookie": "fixture=private", "Authorization": "Bearer fixture", "Referer": "https://viewer.example.test/"], original: original, id: id)
        let same = try store.headers(id: id, original: original.absoluteString, target: URL(string: "https://files.example.test:443/other")!)
        XCTAssertNotNil(same["Cookie"])
        for raw in ["https://files.example.test:444/other", "https://sub.files.example.test/other", "https://cdn.example.test/file"] {
            let redirected = try store.headers(id: id, original: original.absoluteString, target: URL(string: raw)!)
            XCTAssertNil(redirected["Cookie"]); XCTAssertNil(redirected["Authorization"])
            XCTAssertEqual(redirected["Referer"], "https://viewer.example.test/")
        }
        XCTAssertThrowsError(try store.headers(id: id, original: "https://files.example.test/different", target: original))
        XCTAssertThrowsError(try store.headers(id: id, original: original.absoluteString, target: URL(string: "http://127.0.0.1/file")!))
        XCTAssertThrowsError(try store.headers(id: id, original: original.absoluteString, target: URL(string: "https://user:password@files.example.test/file")!))
    }
    func testInvalidHeadersDoNotOverwriteContextAndMetadataHasNoValues() throws {
        let store = NativeRequestHeaders(service: "yunx.test-native-headers.\(UUID().uuidString)"), id = UUID()
        defer { store.delete(id) }
        let original = URL(string: "https://files.example.test/file")!
        try store.save(["Cookie": "fixture=preserved"], original: original, id: id)
        for invalid in [["Host": "elsewhere.test"], ["Range": "bytes=0-1"], ["Cookie": "x\r\ny"], ["Cookie": "one", "cookie": "two"]] {
            XCTAssertThrowsError(try store.save(invalid, original: original, id: id))
        }
        XCTAssertEqual(try store.headers(id: id, original: original.absoluteString, target: original)["Cookie"], "fixture=preserved")
        let request = try NativeHTTPSRequest(text: original.absoluteString, headers: ["Referer": "https://viewer.example.test/private-referrer-marker"])
        let encoded = try request.body(folder: URL(fileURLWithPath: "/tmp/fixture"), headerContext: id)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-referrer-marker"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let req = try XCTUnwrap(root["req"] as? [String: Any])
        XCTAssertEqual((req["labels"] as? [String: String])?[NativeRequestHeaders.label], id.uuidString)
        XCTAssertEqual((req["extra"] as? [String: Any])?["header"] as? [String: String], [:])
    }
}

private final class NativeHeaderObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var found = false
    func record(_ request: String) {
        if request.contains("\r\nCookie:") || request.contains("\r\nAuthorization:") {
            lock.lock(); found = true; lock.unlock()
        }
    }
    var leaked: Bool { lock.lock(); defer { lock.unlock() }; return found }
}

@MainActor
final class NativeHeadersRuntimeTests: XCTestCase {
    func testRealHeaderBridgeTransfersBytesAndStripsCrossOriginRedirectsWithoutPersistingSecrets() async throws {
        for redirect in [false, true] {
            let content = Data(repeating: 0x6b, count: 131072)
            let cookie = "local-fixture=" + UUID().uuidString
            let observation = NativeHeaderObservation()
            let target = try NativeHTTPFixture(data: content, requiredHeader: redirect ? nil : "Cookie: " + cookie,
                                              observer: { if redirect { observation.record($0) } })
            let targetURL = try await target.start()
            defer { target.stop() }
            let origin: NativeHTTPFixture?
            if redirect { origin = try NativeHTTPFixture(data: content, requiredHeader: "Cookie: " + cookie, redirectTo: targetURL) }
            else { origin = nil }
            let url: URL
            if let origin { url = try await origin.start() } else { url = targetURL }
            defer { origin?.stop() }
            let context = UUID()
            defer { NativeRequestHeaders.shared.delete(context) }
            let cloudContext = UUID(), passcode = "cloud-passcode-" + UUID().uuidString
            defer { CloudTransferContexts.shared.delete(cloudContext) }
            let folder = NativeEngine.shared.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var taskID: String?
            do {
                try await NativeEngine.shared.ensureStarted()
                try NativeRequestHeaders.shared.save(["Cookie": cookie], original: url, id: context)
                try CloudTransferContexts.shared.save(CloudTransferContext(provider: .quark, accountID: nil,
                    share: CloudShare(provider: .quark, shareID: "fixture", passcode: passcode),
                    file: CloudFile(id: "fixture", name: "private.bin", size: Int64(content.count), isDirectory: false, parentID: "0", token: "local-file-token"),
                    filename: "private.bin", connections: 2), id: cloudContext)
                let body: [String: Any] = ["req": ["url": url.absoluteString, "labels": [NativeRequestHeaders.label: context.uuidString, CloudTransferContext.label: cloudContext.uuidString]],
                                          "opts": ["path": folder.path, "name": "private.bin", "skipAutoCategorize": true]]
                let created = try await NativeEngine.shared.invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: body))
                let id = try XCTUnwrap(JSONDecoder().decode(EngineEnvelope<String>.self, from: created).data); taskID = id
                let deadline = Date().addingTimeInterval(20)
                var finished = false
                while Date() < deadline {
                    if let task = try await NativeEngine.shared.tasks().first(where: { $0.id == id }) {
                        if task.status == "done" { finished = true; break }
                        if task.status == "error" { break }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(finished)
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("private.bin")), content)
                XCTAssertFalse(observation.leaked)
                let snapshot = try await NativeEngine.shared.invoke("GET", path: "/api/v1/tasks/" + id)
                XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains(cookie))
                XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains(passcode))
                XCTAssertThrowsError(try NativeRequestHeaders.shared.headers(id: context, original: url.absoluteString, target: url))
                try await NativeEngine.shared.quiesceForStorage()
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/Engine")
                let files = try XCTUnwrap(FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.isRegularFileKey]))
                for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                    XCTAssertNil(bytes.range(of: Data(cookie.utf8)), "Native engine persisted credential bytes")
                    XCTAssertNil(bytes.range(of: Data(passcode.utf8)), "Native engine persisted share passcode bytes")
                }
                _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(id)", query: "force=true")
                XCTAssertThrowsError(try CloudTransferContexts.shared.load(cloudContext))
            } catch {
                if let taskID { _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(taskID)", query: "force=true") }
                throw error
            }
        }
    }
}
