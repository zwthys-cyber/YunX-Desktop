// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class NativeBandwidthTests: XCTestCase {
    func testRealNativeHTTPDownloadRespectsSharedRateAndPreservesBytes() async throws {
        let content = Data(repeating: 0x3d, count: 131072)
        let fixture = try NativeHTTPFixture(data: content)
        let url = try await fixture.start()
        defer { fixture.stop() }
        let previous = UserDefaults.standard.integer(forKey: "engineHTTPRateKiB")
        let folder = NativeEngine.shared.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var taskID: String?
        do {
            try await NativeEngine.shared.ensureStarted()
            try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: 64)
            let start = ProcessInfo.processInfo.systemUptime
            let body: [String: Any] = ["req": ["url": url.absoluteString],
                                      "opts": ["path": folder.path, "name": "limited.bin", "skipAutoCategorize": true,
                                               "extra": ["connections": 4]]]
            let response = try await NativeEngine.shared.invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: body))
            let id = try XCTUnwrap(JSONDecoder().decode(EngineEnvelope<String>.self, from: response).data)
            taskID = id
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
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 1.5)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("limited.bin")), content)
            _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(id)", query: "force=true")
            try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: previous)
        } catch {
            if let taskID { _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(taskID)", query: "force=true") }
            try? await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: previous)
            throw error
        }
    }
}
