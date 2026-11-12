// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class ManagedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    func append(_ value: String) { lock.lock(); requests.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor
final class ManagedHTTPTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { XCTFail("managed transfer did not reach its expected state"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func withNativeMode(_ operation: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ManagedHTTPPolicy.preference)
        let rate = defaults.integer(forKey: "engineHTTPRateKiB")
        defaults.set(true, forKey: ManagedHTTPPolicy.preference)
        do {
            try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: 0)
            try await operation()
            try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: rate)
        } catch {
            try? await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: rate)
            if let previous { defaults.set(previous, forKey: ManagedHTTPPolicy.preference) } else { defaults.removeObject(forKey: ManagedHTTPPolicy.preference) }
            throw error
        }
        if let previous { defaults.set(previous, forKey: ManagedHTTPPolicy.preference) } else { defaults.removeObject(forKey: ManagedHTTPPolicy.preference) }
    }
    func testAuthenticatedNativeFileIsVerifiedAndPublishedWithoutOverwriting() async throws {
        try await withNativeMode {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let output = parent.appendingPathComponent("output", isDirectory: true)
            let cache = parent.appendingPathComponent("cache", isDirectory: true)
            let data = Data(repeating: 0xa7, count: 256*1024)
            let fixture = try NativeHTTPFixture(data: data, requiredHeader: "Cookie: __pus=managed-fixture")
            let url = try await fixture.start()
            defer { fixture.stop() }
            let store = DownloadStore(root: output, cache: cache, nativeEnabled: true)
            try Data("existing".utf8).write(to: output.appendingPathComponent("managed.bin"))
            XCTAssertTrue(store.add(url, filename: "managed.bin", headers: ["Cookie": "__pus=managed-fixture"], expectedSize: Int64(data.count)))
            let id = try XCTUnwrap(store.items.first?.id)
            do {
                try await wait { store.items.first?.state == .completed || store.items.first?.state == .failed }
                let item = try XCTUnwrap(store.items.first)
                XCTAssertEqual(item.state, .completed, item.error ?? "")
                XCTAssertEqual(item.nativeTransfer, true)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(item))), data)
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("managed.bin")), Data("existing".utf8))
                XCTAssertFalse(String(decoding: try Data(contentsOf: cache.appendingPathComponent("tasks.json")), as: UTF8.self).contains("managed-fixture"))
                try await store.quiesceForStorage()
                let remaining = try await NativeEngine.shared.managedTask(id)
                XCTAssertNil(remaining)
                XCTAssertThrowsError(try DownloadHeaders.load(id))
                store.delete(id)
                try await store.quiesceForStorage()
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(item.filename)), data)
            } catch {
                store.delete(id); try? await store.quiesceForStorage(); throw error
            }
        }
    }
    func testPausedNativeOwnerSurvivesStoreReloadAndDisablingTheLimit() async throws {
        try await withNativeMode {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let output = parent.appendingPathComponent("output", isDirectory: true), cache = parent.appendingPathComponent("cache", isDirectory: true)
            let data = Data(repeating: 0x7d, count: 1024*1024), log = ManagedRequestLog()
            let fixture = try NativeHTTPFixture(data: data, observer: { log.append($0) })
            let url = try await fixture.start()
            defer { fixture.stop() }
            try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: 64)
            let store = DownloadStore(root: output, cache: cache, nativeEnabled: true)
            XCTAssertTrue(store.add(url, filename: "resume.bin", expectedSize: Int64(data.count)))
            let id = try XCTUnwrap(store.items.first?.id)
            do {
                try await wait { (store.items.first?.received ?? 0) > 16*1024 && store.items.first?.nativeTaskID != nil }
                store.pause(id)
                try await wait { store.items.first?.state == .paused }
                try await store.quiesceForStorage()
                let pausedID = try XCTUnwrap(store.items.first?.nativeTaskID)
                let previousRequests = log.snapshot().count
                try await NativeEngine.shared.setHTTPBandwidthLimit(kibPerSecond: 0)
                UserDefaults.standard.set(false, forKey: ManagedHTTPPolicy.preference)
                let restored = DownloadStore(root: output, cache: cache, nativeEnabled: true)
                XCTAssertEqual(restored.items.first?.state, .paused)
                XCTAssertEqual(restored.items.first?.nativeTaskID, pausedID)
                restored.start(id)
                do {
                    try await wait { restored.items.first?.state == .completed || restored.items.first?.state == .failed }
                    let item = try XCTUnwrap(restored.items.first)
                    XCTAssertEqual(item.state, .completed, item.error ?? "")
                    XCTAssertEqual(item.nativeTransfer, true)
                    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.fileURL(item))), data)
                    XCTAssertTrue(log.snapshot().dropFirst(previousRequests).contains { $0.contains("Range: bytes=") && !$0.contains("Range: bytes=0-") })
                    try await restored.quiesceForStorage()
                    restored.delete(id); try await restored.quiesceForStorage()
                } catch { restored.delete(id); try? await restored.quiesceForStorage(); throw error }
            } catch { store.delete(id); try? await store.quiesceForStorage(); throw error }
        }
    }
    func testWrongSizeNeverPublishesAndDeleteWaitsForNativeCleanup() async throws {
        try await withNativeMode {
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let output = parent.appendingPathComponent("output", isDirectory: true), cache = parent.appendingPathComponent("cache", isDirectory: true)
            let fixture = try NativeHTTPFixture(data: Data(repeating: 3, count: 4096))
            let url = try await fixture.start()
            defer { fixture.stop() }
            let store = DownloadStore(root: output, cache: cache, nativeEnabled: true)
            XCTAssertTrue(store.add(url, filename: "wrong.bin", expectedSize: 4097))
            let id = try XCTUnwrap(store.items.first?.id)
            do {
                try await wait { store.items.first?.state == .failed }
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
                store.delete(id)
                try await store.quiesceForStorage()
                let remaining = try await NativeEngine.shared.managedTask(id)
                XCTAssertNil(remaining)
                XCTAssertFalse(FileManager.default.fileExists(atPath: NativeEngine.shared.managedDownloads.appendingPathComponent(id.uuidString).path))
            } catch { store.delete(id); try? await store.quiesceForStorage(); throw error }
        }
    }
}
