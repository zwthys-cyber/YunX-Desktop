// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class DownloadStorageTests: XCTestCase {
    func testLocalFoldersCannotEscapeThroughTraversalOrSymlinks() throws {
        let (root, documents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Selected"), withIntermediateDirectories: false)
        XCTAssertEqual(try DownloadStorage.localParent("documents/Selected", documents: documents), documents.appendingPathComponent("Selected").resolvingSymlinksInPath())
        for path in ["documents/../outside", "documents//child", "/documents/child", "other/child"] {
            XCTAssertThrowsError(try DownloadStorage.localParent(path, documents: documents))
        }
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertThrowsError(try DownloadStorage.localParent("documents/outside", documents: documents))
    }
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in DownloadStorage.names {
            let folder = documents.appendingPathComponent(name).appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((name + "-fixture").utf8).write(to: folder.appendingPathComponent("file.part"))
        }
        return (root, documents)
    }
    func testVerifiedMigrationKeepsStablePathsAndOriginals() throws {
        let (root, documents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target")
        try DownloadStorage.copyVerified(documents: documents, destination: target)
        let transaction = UUID()
        try DownloadStorage.installAliases(documents: documents, target: target, transaction: transaction)
        for name in DownloadStorage.names {
            let relative = "nested/file.part"
            let stable = documents.appendingPathComponent(name).appendingPathComponent(relative)
            XCTAssertEqual(try Data(contentsOf: stable), Data((name + "-fixture").utf8))
            let backup = documents.appendingPathComponent("YunX-original-" + transaction.uuidString + "-" + name).appendingPathComponent(relative)
            XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: stable))
        }
        // Replay after a commit crash is safe and does not duplicate/overwrite files.
        try DownloadStorage.installAliases(documents: documents, target: target, transaction: transaction)
    }
    func testInterruptedAliasCommitResumesAfterOriginalWasMoved() throws {
        let (root, documents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target")
        try DownloadStorage.copyVerified(documents: documents, destination: target)
        let transaction = UUID(), name = "Downloads"
        try FileManager.default.moveItem(at: documents.appendingPathComponent(name), to: documents.appendingPathComponent("YunX-original-" + transaction.uuidString + "-" + name))
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent(".yunx-link-" + transaction.uuidString + "-" + name), withDestinationURL: target.appendingPathComponent(name))
        try DownloadStorage.installAliases(documents: documents, target: target, transaction: transaction)
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("Downloads/nested/file.part")), Data("Downloads-fixture".utf8))
    }
    func testSymlinkOrOccupiedDestinationNeverCommits() throws {
        let (root, documents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("outside.txt")
        try Data("not-download-data".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("Downloads/nested/link"), withDestinationURL: secret)
        let target = root.appendingPathComponent("Target")
        XCTAssertThrowsError(try DownloadStorage.copyVerified(documents: documents, destination: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".yunx-verified").path))
        XCTAssertThrowsError(try DownloadStorage.copyVerified(documents: documents, destination: target))
        XCTAssertEqual(try Data(contentsOf: secret), Data("not-download-data".utf8))
    }
    func testIncompleteTargetCannotChangeAnyOriginalPath() throws {
        let (root, documents) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target")
        try DownloadStorage.copyVerified(documents: documents, destination: target)
        try FileManager.default.removeItem(at: target.appendingPathComponent("P2P"))
        XCTAssertThrowsError(try DownloadStorage.installAliases(documents: documents, target: target, transaction: UUID()))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: documents.appendingPathComponent("Downloads").path))
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("Downloads/nested/file.part")), Data("Downloads-fixture".utf8))
    }
}
