// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class DownloadPersistenceTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockProtocol.self]
        return config
    }
    func testUnreadableIndexIsPreservedAndCannotBeOverwrittenByNewTask() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Downloads")
        let cache = folder.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let index = cache.appendingPathComponent("tasks.json")
        let original = Data("unreadable-original-record".utf8)
        try original.write(to: index)
        let store = DownloadStore(root: root, cache: cache, configuration: configuration())
        XCTAssertFalse(store.add(URL(string: "https://example.test/fixture.bin")!))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: index), original)
    }
    func testFailedIndexWriteDoesNotCreateOrResumeUnrecordedDownloads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Downloads")
        let cache = folder.appendingPathComponent("Support")
        let store = DownloadStore(root: root, cache: cache, configuration: configuration())
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("tasks.json"), withIntermediateDirectories: true)
        XCTAssertFalse(store.add(URL(string: "https://example.test/fixture.bin")!))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.storageError)
    }
    func testDeleteAndResumeRollbackWhenIndexCannotBeSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let index = cache.appendingPathComponent("tasks.json")
        let item = DownloadItem(id: UUID(), url: URL(string: "https://example.test/fixture.bin")!, filename: "fixture.bin", state: .paused)
        try JSONEncoder().encode([item]).write(to: index)
        let store = DownloadStore(root: folder.appendingPathComponent("Downloads"), cache: cache, configuration: configuration())
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        store.delete(item.id)
        XCTAssertEqual(store.items.map(\.id), [item.id])
        store.start(item.id)
        XCTAssertEqual(store.items.first?.state, .paused)
        store.resumeAll()
        XCTAssertEqual(store.items.first?.state, .paused)
        XCTAssertNotNil(store.storageError)
    }
}
