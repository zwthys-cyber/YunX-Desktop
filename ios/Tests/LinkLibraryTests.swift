// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class LinkLibraryTests: XCTestCase {
    func testFavoritesSurviveHistoryLimitAndReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("links.json")
        let library = LinkLibrary(file: file)
        library.record(platform: "GitHub", text: "owner/favorite")
        let id = try XCTUnwrap(library.links.first?.id)
        library.toggle(id)
        for index in 0..<205 { library.record(platform: "GitHub", text: "owner/repo\(index)") }
        let restored = LinkLibrary(file: file)
        XCTAssertEqual(restored.links.count, 201)
        XCTAssertTrue(restored.links.contains { $0.id == id && $0.favorite })
        restored.clearHistory()
        XCTAssertEqual(restored.links.map(\.id), [id])
        restored.record(platform: "GitHub", text: "owner/favorite")
        XCTAssertEqual(restored.links.count, 1)
        XCTAssertTrue(restored.links[0].favorite)
        restored.delete([id])
        XCTAssertTrue(LinkLibrary(file: file).links.isEmpty)
    }
    func testCorruptHistoryIsNotSilentlyOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("links.json")
        let original = Data("broken".utf8)
        try original.write(to: file)
        let library = LinkLibrary(file: file)
        XCTAssertNotNil(library.error)
        library.record(platform: "GitHub", text: "owner/repo")
        XCTAssertEqual(try Data(contentsOf: file), original)
        library.clearHistory()
        XCTAssertNil(library.error)
        library.record(platform: "GitHub", text: "owner/repo")
        XCTAssertEqual(library.links.count, 1)
    }
}
