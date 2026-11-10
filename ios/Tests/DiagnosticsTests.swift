// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class DiagnosticsTests: XCTestCase {
    func testRotationIsBoundedAndExportNeverCopiesUnknownFields() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let diagnostics = Diagnostics(directory: folder, limit: 1024, retained: 3)
        for _ in 0..<100 { await diagnostics.record(.downloadFailed, code: -1009) }
        let eventFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.lastPathComponent.hasPrefix("events-") }
        XCTAssertEqual(eventFiles.count, 3)
        for file in eventFiles { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 1024) }
        let injected = Data("{\"time\":\"2026-01-01T00:00:00Z\",\"kind\":\"downloadFailed\",\"url\":\"https://example.test/?token=private-value\",\"headers\":{\"Cookie\":\"test-secret\"}}\n".utf8)
        try injected.write(to: folder.appendingPathComponent("events-0.jsonl"))
        let url = try await diagnostics.export()
        let output = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(output.contains("private-value"))
        XCTAssertFalse(output.contains("test-secret"))
        XCTAssertFalse(output.contains("example.test"))
        XCTAssertTrue(output.contains("downloadFailed"))
        XCTAssertTrue(output.contains("containsRequestData"))
        XCTAssertLessThanOrEqual(output.utf8.count, 3 * 1024 + 128)
        try await diagnostics.clear()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
