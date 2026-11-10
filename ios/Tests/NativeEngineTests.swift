// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CryptoKit
@testable import YunX

@MainActor
final class NativeEngineTests: XCTestCase {
    func testP2PInputsRejectIncompleteOrUnrelatedLinks() throws {
        XCTAssertEqual(try P2PInput.link("magnet:?xt=urn:btih:0123456789012345678901234567890123456789"), "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")
        XCTAssertNoThrow(try P2PInput.link("ed2k://|file|fixture.bin|3|0123456789abcdef0123456789abcdef|/"))
        XCTAssertThrowsError(try P2PInput.link("https://example.test/"))
        XCTAssertThrowsError(try P2PInput.link("magnet:?dn=missing-hash"))
        XCTAssertThrowsError(try P2PInput.link("magnet:?xt=urn:btih:"))
        XCTAssertThrowsError(try P2PInput.link("ed2k://|file|x|-1|broken|/"))
        XCTAssertEqual(try P2PInput.trackers("udp://tracker.example.test:80\nudp://tracker.example.test:80"), ["udp://tracker.example.test:80"])
        XCTAssertThrowsError(try P2PInput.trackers("file:///private/data"))
    }
    func testNativeRuntimeAndLocalTorrentMetadataWithoutLivePeers() async throws {
        UserDefaults.standard.set(false, forKey: "engineDHT")
        let info = try await NativeEngine.shared.invoke("GET", path: "/api/v1/info")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: info) as? [String: Any])
        XCTAssertEqual(root["code"] as? Int, 0)
        XCTAssertEqual((root["data"] as? [String: Any])?["os"] as? String, "ios")
        let listening = await NativeEngine.shared.managementServerRunning()
        XCTAssertFalse(listening, "The embedded engine must not open a management HTTP listener")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.torrent")
        var torrent = Data("d4:infod6:lengthi3e4:name8:test.txt12:piece lengthi16384e6:pieces20:".utf8)
        torrent.append(contentsOf: Insecure.SHA1.hash(data: Data("abc".utf8)))
        torrent.append(Data("ee".utf8))
        try torrent.write(to: file)
        let request: [String: Any] = ["req": ["url": file.absoluteString, "extra": ["trackers": [String]()]]]
        let result = try await NativeEngine.shared.invoke("POST", path: "/api/v1/resolve", body: JSONSerialization.data(withJSONObject: request))
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let data = try XCTUnwrap(resolved["data"] as? [String: Any])
        let resource = try XCTUnwrap(data["res"] as? [String: Any])
        let files = try XCTUnwrap(resource["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["name"] as? String, "test.txt")
        XCTAssertEqual(files.first?["size"] as? Int, 3)
    }
}
