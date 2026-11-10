// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security

/// A task label contains only a random ID. Share passcodes and file tokens
/// remain in Keychain; account secrets are always read from the current vault.
struct CloudTransferContext: Codable, Equatable {
    static let label = "yunxCloudTransfer"
    var schema = 1
    let provider: CloudProvider
    let accountID: UUID?
    let share: CloudShare?
    var file: CloudFile
    let filename: String
    let connections: Int

    func validated() throws -> Self {
        guard schema == 1, (1...512).contains(connections), !file.isDirectory, !file.id.isEmpty,
              file.size >= 0, filename == FileNamePolicy.name(filename),
              share == nil || share?.provider == provider,
              accountID != nil || share != nil else { throw Self.unavailable }
        if let share {
            guard !share.shareID.isEmpty else { throw Self.unavailable }
            if let source = share.sourceURL {
                guard ["https", "http"].contains(source.scheme?.lowercased() ?? ""), source.user == nil, source.password == nil,
                      let host = source.host?.lowercased(), provider.acceptsShareHost(host) else { throw Self.unavailable }
            }
        }
        return self
    }
    static var unavailable: CloudError { .message("网盘来源记录不可用，请重新解析原分享或个人目录。") }

    /// Explicitly requested by the user. This refreshes a listing and direct
    /// link, never chooses a different account or silently transfers a share.
    @MainActor
    func refreshed(vault: CredentialVault, session: URLSession? = nil) async throws -> (CloudDownload, Self) {
        _ = try validated()
        if share != nil && [CloudProvider.baidu, .xunlei].contains(provider) {
            throw CloudError.message("此分享需先明确转存，再从个人目录下载。")
        }
        func selected() throws -> SavedCredential? {
            guard let accountID else { return nil }
            guard let value = vault.accounts.first(where: { $0.id == accountID && $0.platform == provider.rawValue }) else {
                throw CloudError.message("原任务账号已移除，请重新解析并选择账号。")
            }
            guard !value.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudError.message("原任务账号凭证已失效，请重新登录后刷新。")
            }
            return value
        }
        let initial = try selected()
        var acceptedSecret = initial?.secret
        func requireCurrentAccount() throws {
            guard try selected()?.secret == acceptedSecret else {
                throw CloudError.message("原任务账号在请求期间已更新，请重新刷新直链。")
            }
        }
        let client = CloudClient(provider: provider, cookie: initial?.secret ?? "", fields: initial?.backupFields ?? [:], session: session,
            credentialChanged: { token, fields in
                guard let accountID, let old = try? selected(), old.secret == acceptedSecret,
                      vault.updateCredential(accountID, secret: token, fields: fields) else { return false }
                acceptedSecret = token
                return true
            }, cookieChanged: { token in
                guard let accountID, let old = try? selected(), old.secret == acceptedSecret else { return }
                vault.updateSecret(accountID, secret: token)
                if vault.accounts.first(where: { $0.id == accountID })?.secret == token { acceptedSecret = token }
            })
        var visited = Set<String>()
        for page in 1...200 {
            try Task.checkCancellation()
            try requireCurrentAccount()
            let result = try await client.listPage(share: share, parentID: file.parentID, page: page)
            try Task.checkCancellation()
            try requireCurrentAccount()
            if let current = result.files.first(where: { $0.id == file.id && !$0.isDirectory }) {
                let plan = try await client.download(file: current, share: share)
                try Task.checkCancellation()
                try requireCurrentAccount()
                var updated = self
                updated.file = current
                return (CloudDownload(url: plan.url, filename: filename, size: plan.size, headers: plan.headers), updated)
            }
            let fresh = result.files.filter { visited.insert($0.id).inserted }
            guard !result.hasMore || !fresh.isEmpty else { throw CloudError.message("平台分页重复，已停止刷新直链。") }
            if !result.hasMore { throw CloudError.message("原目录中未找到该文件，可能已移动、删除或权限变化，请重新解析。") }
        }
        throw CloudError.message("目录分页已达上限，请重新定位文件。")
    }
}

final class CloudTransferContexts: @unchecked Sendable {
    static let shared = CloudTransferContexts()
    private let service: String
    private let lock = NSLock()
    private var revoked = Set<UUID>()
    init(service: String = "io.github.zwthys.yunx.cloud-transfer-contexts") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func save(_ context: CloudTransferContext, id: UUID) throws {
        let data = try JSONEncoder().encode(context.validated())
        guard data.count <= 128 * 1024 else { throw CloudTransferContext.unavailable }
        lock.lock(); defer { lock.unlock() }
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query(id); values.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudTransferContext.unavailable }
        revoked.remove(id)
    }
    func load(_ id: UUID) throws -> CloudTransferContext {
        lock.lock(); defer { lock.unlock() }
        guard !revoked.contains(id) else { throw CloudTransferContext.unavailable }
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 128 * 1024 else { throw CloudTransferContext.unavailable }
        do { return try JSONDecoder().decode(CloudTransferContext.self, from: data).validated() }
        catch { throw CloudTransferContext.unavailable }
    }
    func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        revoked.insert(id)
        SecItemDelete(query(id) as CFDictionary)
    }
}
