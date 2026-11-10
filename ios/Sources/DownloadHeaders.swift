// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security

/// Per-task request headers remain in Keychain, never in tasks.json.
enum DownloadHeaders {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.zwthys.yunx.download-headers",
         kSecAttrAccount as String: id.uuidString]
    }

    static func save(_ headers: [String: String], id: UUID) throws {
        let data = try JSONEncoder().encode(headers)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            values.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CloudError.message("无法安全保存下载凭证（\(status)），未创建任务。")
        }
    }

    static func load(_ id: UUID) throws -> [String: String] {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CloudError.message("下载凭证不可用，请解锁设备或重新解析文件。")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }

    static func redirectHeaders(_ headers: [String: String], original: URL, target: URL) -> [String: String] {
        let sameOrigin = original.scheme?.lowercased() == target.scheme?.lowercased() &&
            original.host?.lowercased() == target.host?.lowercased() && original.port == target.port
        if sameOrigin { return headers }
        return headers.filter { !["cookie", "authorization", "proxy-authorization"].contains($0.key.lowercased()) }
    }
}
