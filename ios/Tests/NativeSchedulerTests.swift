// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class SchedulerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class NativeSchedulerTests: XCTestCase {
    func testNativeTaskWaitsForURLSessionSlotThenTransfersRealBytes() async throws {
        let content = Data(repeating: 0x4f, count: 131072)
        let requests = SchedulerRequests()
        let fixture = try NativeHTTPFixture(data: content, observer: { _ in requests.record() })
        let url = try await fixture.start()
        defer { fixture.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldDownloadProtocol.self]
        let store = DownloadStore(root: root.appendingPathComponent("Downloads"), cache: root.appendingPathComponent("Support"), configuration: config)
        let previous = store.maximumConcurrent
        store.maximumConcurrent = 1
        defer { store.maximumConcurrent = previous }
        XCTAssertTrue(store.add(URL(string: "https://held.invalid/file")!))
        let held = try XCTUnwrap(store.items.first?.id)
        defer { store.delete(held) }
        let folder = NativeEngine.shared.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let body: [String: Any] = ["req": ["url": url.absoluteString], "opts": ["path": folder.path, "name": "queued.bin", "skipAutoCategorize": true]]
        let created = try await NativeEngine.shared.invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: body))
        let id = try XCTUnwrap(JSONDecoder().decode(EngineEnvelope<String>.self, from: created).data)
        do {
            let waiting = try await NativeEngine.shared.tasks().first { $0.id == id }
            XCTAssertEqual(waiting?.status, "wait")
            XCTAssertEqual(requests.value, 0, "A queued task must not briefly start and then pause")
            store.delete(held)
            let deadline = Date().addingTimeInterval(15)
            var finished = false
            while Date() < deadline {
                if try await NativeEngine.shared.tasks().first(where: { $0.id == id })?.status == "done" { finished = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(finished)
            XCTAssertGreaterThan(requests.value, 0)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("queued.bin")), content)
            _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(id)", query: "force=true")
        } catch {
            _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/\(id)", query: "force=true")
            throw error
        }
    }
}
