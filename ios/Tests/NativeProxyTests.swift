// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class ProxyObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var authenticated = false
    func record(_ request: String) {
        let expected = "Basic " + Data("fixture-user:fixture:@/password".utf8).base64EncodedString()
        if request.contains("http://origin.invalid/") && request.contains("Proxy-Authorization: " + expected) {
            lock.lock(); authenticated = true; lock.unlock()
        }
    }
    var received: Bool { lock.lock(); defer { lock.unlock() }; return authenticated }
}

@MainActor
final class NativeProxyTests: XCTestCase {
    func testSwiftResolverRoutesRealNativeDownloadWithoutPersistingCredentials() async throws {
        let content = Data(repeating: 0x5a, count: 131072)
        let observation = ProxyObservation()
        let fixture = try NativeHTTPFixture(data: content, observer: { observation.record($0) })
        let endpoint = try await fixture.start()
        defer { fixture.stop() }
        var profile = NetworkProxyProfile(); profile.mode = .manual; profile.host = "127.0.0.1"
        profile.port = UInt16(try XCTUnwrap(endpoint.port)); profile.username = "fixture-user"; profile.password = "fixture:@/password"
        try await NativeEngine.shared.refreshNetworkProxy(profile: profile, startIfNeeded: true)
        let folder = NativeEngine.shared.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var taskID: String?
        do {
            let body: [String: Any] = ["req": ["url": "http://origin.invalid/payload"], "opts": ["path": folder.path, "name": "proxy.bin", "skipAutoCategorize": true]]
            let response = try await NativeEngine.shared.invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: body))
            let id = try XCTUnwrap(JSONDecoder().decode(EngineEnvelope<String>.self, from: response).data); taskID = id
            let deadline = Date().addingTimeInterval(30)
            var finished = false
            while Date() < deadline {
                if let task = try await NativeEngine.shared.tasks().first(where: { $0.id == id }) {
                    if task.status == "done" { finished = true; break }
                    if task.status == "error" { break }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(finished)
            XCTAssertTrue(observation.received)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("proxy.bin")), content)
            let configuration = String(decoding: try await NativeEngine.shared.invoke("GET", path: "/api/v1/config"), as: UTF8.self)
            XCTAssertFalse(configuration.contains(profile.username)); XCTAssertFalse(configuration.contains(profile.password))
            _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(id)", query: "force=true")
            try await NativeEngine.shared.refreshNetworkProxy()
            try await NativeEngine.shared.quiesceForStorage()
            let restarted = String(decoding: try await NativeEngine.shared.invoke("GET", path: "/api/v1/config"), as: UTF8.self)
            XCTAssertFalse(restarted.contains(profile.password))
        } catch {
            if let taskID { _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(taskID)", query: "force=true") }
            try? await NativeEngine.shared.refreshNetworkProxy()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
