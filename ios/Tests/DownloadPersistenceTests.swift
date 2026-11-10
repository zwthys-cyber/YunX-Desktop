// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class HeldDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { }
    override func stopLoading() { }
}

@MainActor
final class DownloadPersistenceTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockProtocol.self]
        return config
    }
    func testDifferentSessionTaskCannotOverwriteCurrentDownload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldDownloadProtocol.self]
        let store = DownloadStore(root: folder.appendingPathComponent("Downloads"), cache: folder.appendingPathComponent("Support"), configuration: config)
        XCTAssertTrue(store.add(URL(string: "https://example.invalid/fixture.bin")!))
        let item = try XCTUnwrap(store.items.first)
        defer { store.delete(item.id) }
        let other = URLSession(configuration: config)
        defer { other.invalidateAndCancel() }
        let stale = other.downloadTask(with: item.url)
        stale.taskDescription = item.id.uuidString
        // Each session begins its task identifiers at 1; object identity must win.
        XCTAssertEqual(stale.taskIdentifier, 1)
        store.urlSession(other, downloadTask: stale, didWriteData: 999, totalBytesWritten: 999, totalBytesExpectedToWrite: 1000)
        store.urlSession(other, task: stale, didCompleteWithError: URLError(.timedOut))
        XCTAssertEqual(store.items.first?.state, .downloading)
        XCTAssertEqual(store.items.first?.received, 0)
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
