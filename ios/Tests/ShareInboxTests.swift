// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private final class InboxWrites: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func saved() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@MainActor
final class ShareInboxTests: XCTestCase {
    func testSharedQueueSurvivesReopenAndDeletesOnlySelectedRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShareInbox(root: root)
        let first = try store.append("https://pan.baidu.com/s/1fixture?pwd=1234"), second = try store.append("https://cdn.example.test/file.zip")
        XCTAssertEqual(try ShareInbox(root: root).items().map(\.id), [first.id, second.id])
        try store.remove(first.id)
        XCTAssertEqual(try store.items(), [second])
    }
    func testConcurrentExtensionAndHostWritesRespectQueueCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShareInbox(root: root), writes = InboxWrites()
        DispatchQueue.concurrentPerform(iterations: 110) { index in
            if (try? store.append("https://cdn.example.test/file-\(index).zip")) != nil { writes.saved() }
        }
        XCTAssertEqual(writes.total, 100)
        XCTAssertEqual(try store.items().count, 100)
        XCTAssertThrowsError(try store.append("https://cdn.example.test/overflow.zip"))
    }
    func testOversizedOrUnavailableQueueDoesNotClaimSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ShareInbox(root: nil).append("fixture"))
        XCTAssertThrowsError(try ShareInbox(root: root).append(String(repeating: "中", count: 11000)))
        XCTAssertThrowsError(try ShareInbox(root: root).append("  \n"))
    }
    func testSymlinkRecordCannotReadOutsideContainerAndDeletionPreservesTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShareInbox(root: root), item = try store.append("fixture")
        let outside = root.appendingPathComponent("outside.txt"), record = root.appendingPathComponent("ShareInbox/" + item.id.uuidString + ".json")
        try Data("must-remain".utf8).write(to: outside)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
        XCTAssertThrowsError(try store.items())
        try store.remove(item.id)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "must-remain")
    }
    func testRoutingPreservesPasscodesAndDoesNotTreatUnknownTextAsDownload() throws {
        XCTAssertEqual(InboxDestination.parse("百度 https://pan.baidu.com/s/1fixture 提取码：1234").kind, .cloud)
        XCTAssertEqual(InboxDestination.parse("https://www.bilibili.com/video/BV1GJ411x7h7").kind, .media)
        XCTAssertEqual(InboxDestination.parse("仓库 https://github.com/zwthys-cyber/YunX-Desktop").kind, .github)
        XCTAssertEqual(InboxDestination.parse("https://github.com/zwthys-cyber").kind, .githubOwner)
        XCTAssertEqual(InboxDestination.parse("https://cdn.example.test/file.zip").kind, .download)
        XCTAssertEqual(InboxDestination.parse("magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)).kind, .p2p)
        XCTAssertEqual(InboxDestination.parse("https://user:password@cdn.example.test/file.zip").kind, .unknown)
        XCTAssertEqual(InboxDestination.parse("尚未识别的文字").kind, .unknown)
    }
}
