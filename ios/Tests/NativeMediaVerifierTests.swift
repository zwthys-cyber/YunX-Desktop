// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class NativeMediaVerifierTests: XCTestCase {
    func testRealImageAndHTMLAreCheckedWithoutTrustingFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("picture.jpg")
        let verifier = IOSMediaVerifier(root: root)
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/sOkAAAAASUVORK5CYII=")).write(to: file)
        XCTAssertEqual(verifier.verify(file.path, kind: "image"), 1)
        try Data("<html>sign in required</html>".utf8).write(to: file)
        XCTAssertEqual(verifier.verify(file.path, kind: "image"), 2)
        XCTAssertEqual(verifier.verify(file.path, kind: "video"), 2)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(verifier.verify(file.path, kind: "image"), 0)
    }
    func testVerifierRejectsOtherFilesAndEscapingTaskSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("secret.bin")
        try Data([1, 2, 3]).write(to: file)
        let verifier = IOSMediaVerifier(root: root)
        XCTAssertEqual(verifier.verify(file.path, kind: "image"), 2)
        let link = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertEqual(verifier.verify(link.appendingPathComponent("secret.bin").path, kind: "image"), 2)
        XCTAssertEqual(verifier.verify(file.path, kind: "unsupported"), 2)
    }
    func testNativeMediaPolicyCannotBeOverriddenByCallerLabels() throws {
        for kind in ["image", "video"] {
            let request = try NativeHTTPSRequest(text: "https://example.test/media", labels: ["yunxExpectedMedia": "zip"], expectedMedia: kind)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body(folder: URL(fileURLWithPath: "/tmp/fixture"))) as? [String: Any])
            let req = try XCTUnwrap(object["req"] as? [String: Any])
            XCTAssertEqual((req["labels"] as? [String: String])?["yunxExpectedMedia"], kind)
        }
    }
}
