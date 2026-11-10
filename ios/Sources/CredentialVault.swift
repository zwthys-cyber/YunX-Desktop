// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import Combine

struct SavedCredential: Codable, Identifiable {
    var id = UUID()
    var platform: String
    var remark: String
    var secret: String
    var isPrimary: Bool?
    var backupFields: [String: String]?
}

/// 凭证只写入应用自己的 Keychain 项，不扫描其他应用或浏览器。
final class CredentialVault: ObservableObject {
    @Published private(set) var accounts: [SavedCredential] = []
    @Published var message: String?
    private let service: String
    private let account = "vault-v1"
    private var unreadable = false

    init(service: String = "io.github.zwthys.yunx.accounts") {
        self.service = service
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = result as? Data else {
            unreadable = true
            message = "无法读取钥匙串（\(status)）"
            return
        }
        do { accounts = try JSONDecoder().decode([SavedCredential].self, from: data) }
        catch { unreadable = true; message = "凭证数据损坏，未覆盖原始钥匙串" }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func add(platform: String, remark: String, secret: String, fields: [String: String]? = nil) {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = accounts
        updated.append(SavedCredential(platform: platform, remark: remark, secret: value, backupFields: fields))
        persist(updated)
    }

    func updateSecret(_ id: UUID, secret: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        updated[index].secret = secret
        persist(updated)
    }

    @discardableResult
    func updateCredential(_ id: UUID, secret: String, fields: [String: String]) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        var updated = accounts
        updated[index].secret = secret
        var merged = updated[index].backupFields ?? [:]
        merged.merge(fields) { _, value in value }
        updated[index].backupFields = merged
        persist(updated)
        return message == nil
    }

    func setPrimary(_ id: UUID) {
        guard let chosen = accounts.first(where: { $0.id == id }) else { return }
        var updated = accounts
        for index in updated.indices where updated[index].platform == chosen.platform {
            updated[index].isPrimary = updated[index].id == id
        }
        persist(updated)
    }

    func rename(_ id: UUID, remark: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        updated[index].remark = remark
        persist(updated)
    }

    @discardableResult
    func restore(_ incoming: [SavedCredential]) -> Int {
        var updated = accounts
        var restored = 0
        for var item in incoming {
            if let index = updated.firstIndex(where: { $0.platform == item.platform && $0.secret == item.secret }) {
                item.id = updated[index].id
                updated[index] = item
            } else {
                if updated.contains(where: { $0.id == item.id }) { item.id = UUID() }
                updated.append(item)
            }
            if item.isPrimary == true {
                for index in updated.indices where updated[index].platform == item.platform && updated[index].id != item.id {
                    updated[index].isPrimary = false
                }
            }
            restored += 1
        }
        persist(updated)
        return message == nil ? restored : 0
    }

    func delete(_ id: UUID) {
        persist(accounts.filter { $0.id != id })
    }

    private func persist(_ updated: [SavedCredential]) {
        guard !unreadable else { message = "原凭证无法读取，已保留原始钥匙串；请解锁或排查备份后重启。"; return }
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
