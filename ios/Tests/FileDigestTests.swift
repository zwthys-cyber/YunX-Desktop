// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CryptoKit
@testable import YunX

final class FileDigestTests: XCTestCase {
    func testKnownDigestAndMultipleReadChunks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try FileDigest.sha256(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let large = Data(repeating: 0xab, count: 2 * 1024 * 1024 + 17)
        try large.write(to: file)
        let expected = SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try FileDigest.sha256(file), expected)
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try FileDigest.sha256(file))
    }
}
