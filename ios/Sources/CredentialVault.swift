// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import Combine

struct SavedCredential: Codable, Identifiable {
    var id = UUID()
    var platform: String
    var remark: String
    var secret: String
}

/// 凭证只写入应用自己的 Keychain 项，不扫描其他应用或浏览器。
final class CredentialVault: ObservableObject {
    @Published private(set) var accounts: [SavedCredential] = []
    @Published var message: String?
    private let service = "io.github.zwthys.yunx.accounts"
    private let account = "vault-v1"

    init() {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = result as? Data else {
            message = "无法读取钥匙串（\(status)）"
            return
        }
        do { accounts = try JSONDecoder().decode([SavedCredential].self, from: data) }
        catch { message = "凭证数据损坏，未覆盖原始钥匙串" }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func add(platform: String, remark: String, secret: String) {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = accounts
        updated.append(SavedCredential(platform: platform, remark: remark, secret: value))
        persist(updated)
    }

    func updateSecret(_ id: UUID, secret: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        updated[index].secret = secret
        persist(updated)
    }

    func delete(_ id: UUID) {
        persist(accounts.filter { $0.id != id })
    }

    private func persist(_ updated: [SavedCredential]) {
        do {
            let data = try JSONEncoder().encode(updated)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var insert = baseQuery
                attributes.forEach { insert[$0.key] = $0.value }
                status = SecItemAdd(insert as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                message = "凭证保存失败（\(status)）"
                return
            }
            accounts = updated
            message = nil
        } catch { message = "凭证编码失败" }
    }
}
