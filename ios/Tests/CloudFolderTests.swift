// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class CloudFolderTests: XCTestCase {
    private func file(_ id: String, directory: Bool = false) -> CloudFile {
        CloudFile(id: id, name: id, size: 10, isDirectory: directory, parentID: "0", token: "test")
    }
    func testRecursiveCollectionDeduplicatesAndStopsCycles() async throws {
        let files = try await CloudFolderCollector().collect(rootID: "0") { id, _ in
            if id == "0" { return [self.file("folder", directory: true), self.file("a"), self.file("a")] }
            return [self.file("0", directory: true), self.file("b")]
        }
        XCTAssertEqual(files.map { $0.file.id }, ["a", "b"])
        XCTAssertEqual(files[1].relativeFolders, ["folder"])
    }
    func testBatchLimitRejectsInsteadOfTruncating() async throws {
        var collector = CloudFolderCollector()
        collector.fileLimit = 1
        do {
            _ = try await collector.collect(rootID: "0") { _, _ in [self.file("a"), self.file("b")] }
            XCTFail("Expected file limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("文件超过")) }
    }
    func testRepeatingFullPageDoesNotLoopForever() async throws {
        do {
            _ = try await CloudFolderCollector().collect(rootID: "0") { _, _ in
                (0..<50).map { self.file(String($0)) }
            }
            XCTFail("Expected duplicate page rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("分页重复")) }
    }
    func testShortPageWithExplicitContinuationIsNotTruncated() async throws {
        let files = try await CloudFolderCollector().collectPages(rootID: "0") { _, page in
            CloudPage(files: [self.file(page == 1 ? "a" : "b")], hasMore: page == 1)
        }
        XCTAssertEqual(files.map { $0.file.id }, ["a", "b"])
    }
    func testEmptyContinuationPageIsRejectedInsteadOfClaimingComplete() async throws {
        do {
            _ = try await CloudFolderCollector().collectPages(rootID: "0") { _, _ in CloudPage(files: [], hasMore: true) }
            XCTFail("Empty continuation must not complete a batch")
        } catch { XCTAssertTrue(error.localizedDescription.contains("分页重复")) }
    }
}
