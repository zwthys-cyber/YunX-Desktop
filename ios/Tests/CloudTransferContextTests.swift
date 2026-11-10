// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

@MainActor
final class CloudTransferContextTests: XCTestCase {
    private func context(account: UUID? = nil, share: Bool = true) -> CloudTransferContext {
        CloudTransferContext(provider: .quark, accountID: account,
            share: share ? CloudShare(provider: .quark, shareID: "share-fixture", passcode: "passcode-marker") : nil,
            file: CloudFile(id: "file-fixture", name: "original.bin", size: 128, isDirectory: false, parentID: "0", token: "expired-file-token-marker"),
            filename: "kept-name.bin", connections: 4)
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMockProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func vault() -> CredentialVault { CredentialVault(service: "yunx.test-cloud-refresh." + UUID().uuidString) }

    func testKeychainRoundTripRevocationAndTaskMetadataContainsOnlyContextID() throws {
        let service = "yunx.test-cloud-context." + UUID().uuidString
        let store = CloudTransferContexts(service: service), id = UUID(), value = context()
        defer { store.delete(id) }
        try store.save(value, id: id)
        XCTAssertEqual(try CloudTransferContexts(service: service).load(id), value)
        let request = try NativeHTTPSRequest(text: "https://files.example.test/fixture.bin", labels: [CloudTransferContext.label: id.uuidString])
        let body = String(decoding: try request.body(folder: URL(fileURLWithPath: "/tmp/fixture")), as: UTF8.self)
        XCTAssertTrue(body.contains(id.uuidString))
        XCTAssertFalse(body.contains("passcode-marker"))
        XCTAssertFalse(body.contains("expired-file-token-marker"))
        store.delete(id)
        XCTAssertThrowsError(try store.load(id))
        XCTAssertThrowsError(try CloudTransferContexts(service: service).load(id))
    }

    func testRefreshUsesCurrentOriginalAccountAndNewListingToken() async throws {
        let vault = vault()
        vault.add(platform: CloudProvider.quark.rawValue, remark: "fixture", secret: "fixture-old-cookie")
        let account = try XCTUnwrap(vault.accounts.first)
        defer { vault.delete(account.id); CloudMockProtocol.handler = nil }
        let value = context(account: account.id)
        vault.updateSecret(account.id, secret: "fixture-current-cookie")
        CloudMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "fixture-current-cookie")
            let path = request.url!.path
            if path.hasSuffix("/token") { return (200, [:], ["status": 200, "data": ["stoken": "fresh-share-token"]]) }
            if path.hasSuffix("/detail") {
                return (200, [:], ["status": 200, "data": ["list": [["fid": "file-fixture", "file_name": "renamed.bin", "size": 256, "pdir_fid": "0", "share_fid_token": "fresh-file-token"]]]])
            }
            XCTAssertTrue(path.hasSuffix("/download"))
            let payload = try Self.body(request)
            XCTAssertEqual(payload["fids_token"] as? [String], ["fresh-file-token"])
            XCTAssertEqual(payload["stoken"] as? String, "fresh-share-token")
            return (200, [:], ["status": 200, "data": [["download_url": "https://files.example.test/fresh.bin", "size": 256]]])
        }
        let (plan, updated) = try await value.refreshed(vault: vault, session: session())
        XCTAssertEqual(plan.filename, "kept-name.bin")
        XCTAssertEqual(plan.size, 256)
        XCTAssertEqual(plan.headers["Cookie"], "fixture-current-cookie")
        XCTAssertEqual(updated.file.token, "fresh-file-token")
        XCTAssertEqual(updated.accountID, account.id)
    }

    func testRemovedAccountNeverFallsBackToAnotherSavedAccountOrMakesARequest() async throws {
        let vault = vault()
        vault.add(platform: CloudProvider.quark.rawValue, remark: "other", secret: "other-account-cookie")
        let other = try XCTUnwrap(vault.accounts.first)
        defer { vault.delete(other.id); CloudMockProtocol.handler = nil }
        CloudMockProtocol.handler = { _ in XCTFail("Removed account must fail before networking"); throw CloudTransferContext.unavailable }
        do { _ = try await context(account: UUID()).refreshed(vault: vault, session: session()); XCTFail("Expected removed-account failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("账号已移除")) }
    }

    func testMissingFileStopsBeforeDownloadOrShareTransfer() async throws {
        let vault = vault()
        defer { CloudMockProtocol.handler = nil }
        CloudMockProtocol.handler = { request in
            if request.url!.path.hasSuffix("/token") { return (200, [:], ["status": 200, "data": ["stoken": "fresh"]]) }
            XCTAssertTrue(request.url!.path.hasSuffix("/detail"), "Only listing may be queried for a missing file")
            return (200, [:], ["status": 200, "data": ["list": []]])
        }
        do { _ = try await context().refreshed(vault: vault, session: session()); XCTFail("Expected missing-file failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未找到该文件")) }
    }

    nonisolated private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
