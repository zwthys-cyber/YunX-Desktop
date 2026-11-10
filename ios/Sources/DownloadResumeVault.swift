// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit
import Security

/// URLSession's opaque resume archive may contain the original authenticated
/// request. Protect it just like the separately stored request headers.
struct DownloadResumeVault {
    static let shared = DownloadResumeVault()
    let service: String
    init(service: String = "io.github.zwthys.yunx.download-resume-key") { self.service = service }
    private static let magic = Data("YUNX-RESUME-AESGCM-1\n".utf8)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "key-v1"]
    }
    private func key(create: Bool) throws -> SymmetricKey {
        var attributes = query
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw unavailable }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound, create else { throw unavailable }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw unavailable }
        var addition = query
        addition[kSecValueData as String] = bytes
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(create: false) }
        guard added == errSecSuccess else { throw unavailable }
        return SymmetricKey(data: bytes)
    }
    private var unavailable: CloudError { .message("下载断点密钥不可用，请解锁设备后重试；原断点已保留。") }

    func write(_ data: Data, to url: URL, id: UUID) throws {
        guard data.count <= 16 * 1024 * 1024 - 256 else { throw CloudError.message("下载断点过大，未覆盖原文件。") }
        let sealed = try AES.GCM.seal(data, using: key(create: true), authenticating: Data(id.uuidString.utf8))
        guard let combined = sealed.combined else { throw unavailable }
        try (Self.magic + combined).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func read(from url: URL, id: UUID) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw CloudError.message("下载断点过大，原文件已保留。") }
        let data = try Data(contentsOf: url)
        guard data.starts(with: Self.magic) else {
            // Preserve old installations' valid URLSession archives and encrypt
            // them atomically before they are handed back to the system.
            guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  object is [String: Any] else { throw CloudError.message("下载断点格式无效，原文件已保留。") }
            try write(data, to: url, id: id)
            return data
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
            return try AES.GCM.open(sealed, using: key(create: false), authenticating: Data(id.uuidString.utf8))
        } catch {
            throw CloudError.message("下载断点无法解密或校验失败，原文件已保留；请解锁设备后重试。")
        }
    }
}
