// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class AuthBackupTests: XCTestCase {
    func testDesktopJavaV1AndV2Compatibility() throws {
        let url = try XCTUnwrap(Bundle(for: AuthBackupTests.self).url(forResource: "backup-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(vectors.keys), ["v1", "v2"])
        for value in vectors.values {
            let accounts = try AuthBackup.decode(Data(value.utf8), password: "fixture-密码-123")
            XCTAssertEqual(accounts.count, 1)
            XCTAssertEqual(accounts[0].platform, "夸克")
            XCTAssertEqual(accounts[0].secret, "test-only-cookie=fixture")
            XCTAssertEqual(accounts[0].remark, "测试账号")
        }
    }
    func testRoundtripPreservesMultiAccountsAndAuxiliaryTokens() throws {
        var first = SavedCredential(platform: "迅雷", remark: "主账号", secret: "test-access-token")
        first.isPrimary = true
        first.backupFields = ["refreshToken": "test-refresh", "deviceId": "test-device", "authType": "web"]
        let second = SavedCredential(platform: "迅雷", remark: "副账号", secret: "second-test-token")
        let github = SavedCredential(platform: "GitHub", remark: "测试", secret: "test-github-token")
        let encrypted = try AuthBackup.encode([first, second, github], password: "test-password")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("test-access-token"))
        let restored = try AuthBackup.decode(encrypted, password: "test-password")
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.map(\.id), [first.id, second.id, github.id])
        XCTAssertEqual(restored[0].isPrimary, true)
        XCTAssertEqual(restored[0].backupFields?["refreshToken"], "test-refresh")
        XCTAssertEqual(restored[1].secret, second.secret)
    }
    func testWrongPasswordAndTamperingAreRejected() throws {
        let encrypted = try AuthBackup.encode([], password: "test-password")
        XCTAssertThrowsError(try AuthBackup.decode(encrypted, password: "wrong-password"))
        var raw = try XCTUnwrap(Data(base64Encoded: encrypted))
        raw[raw.count - 1] ^= 1
        XCTAssertThrowsError(try AuthBackup.decode(raw.base64EncodedData(), password: "test-password"))
        XCTAssertThrowsError(try AuthBackup.decrypt(Data("not-base64".utf8), password: "test-password"))
        XCTAssertThrowsError(try AuthBackup.encrypt(Data(), password: "short"))
        XCTAssertThrowsError(try AuthBackup.decrypt(Data(repeating: 0, count: AuthBackup.maximumBytes + 1), password: "test-password"))
    }
}
