// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Security
@testable import YunX

final class DownloadResumeVaultTests: XCTestCase {
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "key-v1"]
    }
    func testResumeRoundTripIsEncryptedAndBoundToTaskIdentity() throws {
        let service = "yunx.test-resume.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SecItemDelete(query(service) as CFDictionary); try? FileManager.default.removeItem(at: url) }
        let vault = DownloadResumeVault(service: service), id = UUID()
        let secret = Data("Authorization: Bearer synthetic-resume-secret".utf8)
        try vault.write(secret, to: url, id: id)
        let encrypted = try Data(contentsOf: url)
        XCTAssertNil(encrypted.range(of: secret))
        XCTAssertEqual(try vault.read(from: url, id: id), secret)
        XCTAssertThrowsError(try vault.read(from: url, id: UUID()))
        var changed = encrypted; changed[changed.count - 1] ^= 1
        try changed.write(to: url)
        XCTAssertThrowsError(try vault.read(from: url, id: id))
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }
    func testLegacyPropertyListIsMigratedWithoutLosingArchive() throws {
        let service = "yunx.test-resume.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SecItemDelete(query(service) as CFDictionary); try? FileManager.default.removeItem(at: url) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["NSURLSessionResumeOriginalRequest": Data("private request".utf8)], format: .binary, options: 0)
        try data.write(to: url)
        let vault = DownloadResumeVault(service: service), id = UUID()
        XCTAssertEqual(try vault.read(from: url, id: id), data)
        XCTAssertNotEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try vault.read(from: url, id: id), data)
    }
    func testMissingOrMalformedKeyNeverReplacesExistingEncryptedArchive() throws {
        let service = "yunx.test-resume.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { SecItemDelete(query(service) as CFDictionary); try? FileManager.default.removeItem(at: url) }
        let vault = DownloadResumeVault(service: service), id = UUID()
        try vault.write(Data("resume".utf8), to: url, id: id)
        let original = try Data(contentsOf: url)
        XCTAssertEqual(SecItemDelete(query(service) as CFDictionary), errSecSuccess)
        XCTAssertThrowsError(try vault.read(from: url, id: id))
        XCTAssertEqual(try Data(contentsOf: url), original)
        var addition = query(service)
        addition[kSecValueData as String] = Data([1, 2, 3])
        XCTAssertEqual(SecItemAdd(addition as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try vault.write(Data("new".utf8), to: url, id: id))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
