// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class DownloadFileSaveTests: XCTestCase {
    private func fixture(kind: String? = nil, size: Int64? = nil) throws -> (URL, URL, URL, UUID, Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("Output"), cache = folder.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("URLSession-body")
        let bytes = Data(repeating: 0x47, count: 768 * 1024 + 3)
        try bytes.write(to: temporary)
        let id = UUID()
        try DownloadFileSave.retain(temporary, cache: cache, id: id, proposed: "result.bin", kind: kind, mime: nil, requiredSize: size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(DownloadFileSave.pending(cache: cache, id: id))
        return (folder, root, cache, id, bytes)
    }

    func testRetainedBodySurvivesPublicationUntilIndexCommitAndRecoversWithoutCopy() throws {
        let (folder, root, cache, id, bytes) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try DownloadFileSave.finish(cache: cache, id: id, root: root)
        let output = root.appendingPathComponent(first.filename)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        let inode = try FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber
        XCTAssertTrue(DownloadFileSave.pending(cache: cache, id: id))
        // Simulate a crash after the output rename and before tasks.json commits.
        let recovered = try DownloadFileSave.finish(cache: cache, id: id, root: root)
        XCTAssertEqual(recovered.filename, first.filename)
        XCTAssertEqual(recovered.size, Int64(bytes.count))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber, inode)
        DownloadFileSave.discard(cache: cache, id: id)
        XCTAssertFalse(DownloadFileSave.pending(cache: cache, id: id))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testExistingUserFileAndChangedPublishedOutputAreNeverOverwritten() throws {
        let (folder, root, cache, id, bytes) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = root.appendingPathComponent("result.bin"), user = Data("user-owned".utf8)
        try user.write(to: original)
        let result = try DownloadFileSave.finish(cache: cache, id: id, root: root)
        XCTAssertNotEqual(result.filename, "result.bin")
        XCTAssertEqual(try Data(contentsOf: original), user)
        let output = root.appendingPathComponent(result.filename)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        try user.write(to: output)
        XCTAssertThrowsError(try DownloadFileSave.finish(cache: cache, id: id, root: root))
        XCTAssertEqual(try Data(contentsOf: output), user)
        XCTAssertTrue(DownloadFileSave.pending(cache: cache, id: id))
    }

    func testCancellationKeepsCompleteBodyForSavingWithoutNetwork() async throws {
        let (folder, root, cache, id, bytes) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Cancellation ends the gate, then the real saver must reject entry.
        let gate = AsyncStream<Void>.makeStream()
        let worker = Task.detached { () async throws -> DownloadFileSave.Result in
            for await _ in gate.stream { break }
            return try DownloadFileSave.finish(cache: cache, id: id, root: root)
        }
        worker.cancel()
        gate.continuation.finish()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(DownloadFileSave.pending(cache: cache, id: id))
        let output = try DownloadFileSave.finish(cache: cache, id: id, root: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(output.filename)), bytes)
    }

    func testInvalidMediaAndWrongPlatformSizeNeverPublishOutput() throws {
        for (kind, size) in [("zip" as String?, nil as Int64?), (nil, Int64(1))] {
            let (folder, root, cache, id, _) = try fixture(kind: kind, size: size)
            defer { try? FileManager.default.removeItem(at: folder) }
            XCTAssertThrowsError(try DownloadFileSave.finish(cache: cache, id: id, root: root))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
            XCTAssertTrue(DownloadFileSave.pending(cache: cache, id: id))
        }
    }

    func testLongDuplicateNameKeepsItsUniqueSuffix() throws {
        let (folder, root, cache, id, bytes) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Replace the not-yet-published receipt with a maximum-length safe name.
        let name = String(repeating: "a", count: 196) + ".bin"
        let directory = cache.appendingPathComponent("CompletedBodies/" + id.uuidString)
        let receipt = DownloadFileSave.Receipt(proposed: name, kind: nil, mime: nil, requiredSize: nil)
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"))
        let user = Data("existing".utf8)
        try user.write(to: root.appendingPathComponent(name))
        let output = try DownloadFileSave.finish(cache: cache, id: id, root: root)
        XCTAssertTrue(output.filename.contains(id.uuidString))
        XCTAssertLessThanOrEqual(output.filename.utf8.count, 255)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), user)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(output.filename)), bytes)
    }

    @MainActor
    func testStoreResumesRetainedSaveAfterRestartWithoutNetworkCredentials() async throws {
        for alreadyPublished in [false, true] {
            let (folder, root, cache, id, bytes) = try fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            if alreadyPublished { _ = try DownloadFileSave.finish(cache: cache, id: id, root: root) }
            var item = DownloadItem(id: id, url: URL(string: "https://expired.invalid/file")!, filename: "result.bin", state: .downloading)
            item.requiresHeaders = true // No Keychain credential is installed: no network may be started.
            try JSONEncoder().encode([item]).write(to: cache.appendingPathComponent("tasks.json"))
            let store = DownloadStore(root: root, cache: cache, configuration: .ephemeral)
            XCTAssertEqual(store.items.first?.state, .paused)
            XCTAssertEqual(store.items.first?.pendingSave, true)
            store.start(id)
            let deadline = Date().addingTimeInterval(10)
            while store.items.first?.state != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(store.items.first?.state, .completed)
            XCTAssertNil(store.items.first?.pendingSave)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("result.bin")), bytes)
            XCTAssertFalse(DownloadFileSave.pending(cache: cache, id: id))
            try await store.quiesceForStorage()
        }
    }
}
