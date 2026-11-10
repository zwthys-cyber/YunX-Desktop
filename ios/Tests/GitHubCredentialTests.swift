// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Security
@testable import YunX

@MainActor
final class GitHubCredentialTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }
    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "vault-v1"]
    }
    func test401RemovesOnlyTheRejectedSavedCredentialAndBlocksOldClient() async throws {
        let service = "io.github.zwthys.yunx.test-vault.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary); MediaMockProtocol.handler = nil }
        let vault = CredentialVault(service: service)
        vault.add(platform: "GitHub", remark: "rejected", secret: "old-fixture-token")
        vault.add(platform: "GitHub", remark: "other", secret: "unrelated-fixture-token")
        let id = try XCTUnwrap(vault.accounts.first?.id)
        let client = GitHubClient.saved(id: id, vault: vault, session: session())
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-fixture-token")
            return (401, [:], ["message": "Bad credentials"])
        }
        do { _ = try await client.repositories(owner: "fixture", organization: false, page: 1); XCTFail("401 accepted") } catch { }
        XCTAssertFalse(vault.accounts.contains { $0.id == id })
        XCTAssertEqual(vault.accounts.map(\.remark), ["other"])
        MediaMockProtocol.handler = { _ in XCTFail("Removed credentials must not issue requests"); return (200, [:], []) }
        do { _ = try await client.repositories(owner: "fixture", organization: false, page: 1); XCTFail("Deleted account reused") } catch { }
    }
    func testLate401AndPermission403DoNotDeleteReplacementToken() async throws {
        let service = "io.github.zwthys.yunx.test-vault.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary); MediaMockProtocol.handler = nil }
        let vault = CredentialVault(service: service)
        vault.add(platform: "GitHub", remark: "preserve", secret: "old-fixture-token")
        let id = try XCTUnwrap(vault.accounts.first?.id)
        let client = GitHubClient.saved(id: id, vault: vault, session: session())
        MediaMockProtocol.handler = { _ in
            if Thread.isMainThread { vault.updateSecret(id, secret: "replacement-token") }
            else { DispatchQueue.main.sync { vault.updateSecret(id, secret: "replacement-token") } }
            return (401, [:], ["message": "Old request rejected"])
        }
        do { _ = try await client.repositories(owner: "fixture", organization: false, page: 1); XCTFail("401 accepted") } catch { }
        XCTAssertEqual(vault.accounts.first?.secret, "replacement-token")
        XCTAssertEqual(vault.accounts.first?.remark, "preserve")
        MediaMockProtocol.handler = { _ in (403, [:], ["message": "Permission required"]) }
        do { _ = try await client.repositories(owner: "fixture", organization: false, page: 1); XCTFail("403 accepted") } catch { }
        XCTAssertEqual(vault.accounts.first?.secret, "replacement-token")
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer replacement-token")
            return (200, [:], [])
        }
        _ = try await client.repositories(owner: "fixture", organization: false, page: 1)
    }
    func testDownloadPlanUsesCurrentCredentialRatherThanInitialSnapshot() async throws {
        let service = "io.github.zwthys.yunx.test-vault.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary); MediaMockProtocol.handler = nil }
        let vault = CredentialVault(service: service)
        vault.add(platform: "GitHub", remark: "fixture", secret: "initial-token")
        let id = try XCTUnwrap(vault.accounts.first?.id)
        let client = GitHubClient.saved(id: id, vault: vault, session: session())
        vault.updateSecret(id, secret: "current-token")
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
            return (200, [:], ["name": "file", "path": "file", "type": "file", "size": 3, "download_url": NSNull()])
        }
        let plan = try await client.fileDownload(GitHubRepository(owner: "fixture", name: "repo"), path: "file")
        XCTAssertEqual(plan.headers["Authorization"], "Bearer current-token")
    }
    func testUnreadableVaultCannotBeOverwrittenByAddingOrRestoringAccounts() throws {
        let service = "io.github.zwthys.yunx.test-vault.\(UUID().uuidString)"
        defer { SecItemDelete(query(service) as CFDictionary) }
        let original = Data("unreadable-original-vault".utf8)
        var insert = query(service); insert[kSecValueData as String] = original
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
        let vault = CredentialVault(service: service)
        vault.add(platform: "GitHub", remark: "must-not-overwrite", secret: "fixture")
        _ = vault.restore([SavedCredential(platform: "GitHub", remark: "restore", secret: "fixture")])
        var read = query(service); read[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, original)
        XCTAssertNotNil(vault.message)
    }
}
