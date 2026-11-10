// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security
import Yunxengine

/// Native task metadata stores only the UUID. Credential values and the
/// original URL binding stay in this device's Keychain.
final class NativeRequestHeaders: @unchecked Sendable {
    static let shared = NativeRequestHeaders()
    static let label = "yunxHeaderContext"
    private struct Envelope: Codable {
        let schema: Int
        let original: String
        let headers: [String: String]
    }
    private let service: String
    private let lock = NSLock()
    private var cached: [UUID: Envelope] = [:]
    private var revoked = Set<UUID>()
    private var purged = Set<UUID>()
    init(service: String = "io.github.zwthys.yunx.native-request-headers") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    private static func safe(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    static func validate(_ headers: [String: String]) throws {
        let allowed: Set<String> = ["authorization", "cookie", "referer", "user-agent", "accept", "accept-language", "origin"]
        var seen = Set<String>(), size = 0
        for (key, value) in headers {
            guard allowed.contains(key.lowercased()), seen.insert(key.lowercased()).inserted,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw failure }
            size += key.utf8.count + value.utf8.count
            guard size <= 64 * 1024 else { throw failure }
        }
    }
    private static var failure: CloudError { .message("原生下载凭证不可用，请解锁设备或重新解析文件。") }

    func save(_ headers: [String: String], original: URL, id: UUID) throws {
        guard Self.safe(original) else { throw Self.failure }
        try Self.validate(headers)
        let envelope = Envelope(schema: 1, original: original.absoluteString, headers: headers)
        let data = try JSONEncoder().encode(envelope)
        lock.lock(); defer { lock.unlock() }
        let values: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query(id); values.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure }
        cached[id] = envelope; revoked.remove(id); purged.remove(id)
    }
    func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        revoked.insert(id); cached.removeValue(forKey: id)
        guard !purged.contains(id) else { return }
        let status = SecItemDelete(query(id) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { purged.insert(id) }
    }
    private func envelope(_ id: UUID) throws -> Envelope {
        lock.lock(); defer { lock.unlock() }
        guard !revoked.contains(id) else { throw Self.failure }
        if let value = cached[id] { return value }
        var attributes = query(id); attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 128 * 1024,
              let decoded = try? JSONDecoder().decode(Envelope.self, from: data), decoded.schema == 1 else { throw Self.failure }
        try Self.validate(decoded.headers)
        cached[id] = decoded
        return decoded
    }
    func headers(id: UUID, original: String, target: URL) throws -> [String: String] {
        let saved = try envelope(id)
        guard saved.original == original, let origin = URL(string: original), Self.safe(origin), Self.safe(target),
              origin.scheme?.lowercased() != "https" || target.scheme?.lowercased() == "https" else { throw Self.failure }
        let effectivePort: (URL) -> Int = { $0.port ?? ($0.scheme?.lowercased() == "https" ? 443 : 80) }
        let sameOrigin = origin.scheme?.lowercased() == target.scheme?.lowercased() &&
            origin.host?.lowercased() == target.host?.lowercased() && effectivePort(origin) == effectivePort(target)
        return saved.headers.filter { sameOrigin || !["cookie", "authorization"].contains($0.key.lowercased()) }
    }
    func runtimeJSON(id: String?, original: String?, target: String?) -> String {
        do {
            guard let id, let uuid = UUID(uuidString: id), let original, let target, let url = URL(string: target) else { throw Self.failure }
            let values = try headers(id: uuid, original: original, target: url)
            let data = try JSONSerialization.data(withJSONObject: ["headers": values])
            return String(decoding: data, as: UTF8.self)
        } catch { return "{\"error\":true}" }
    }
}

final class IOSHeaderResolver: NSObject, YunxengineHeaderResolverProtocol, @unchecked Sendable {
    private let store: NativeRequestHeaders
    init(store: NativeRequestHeaders = .shared) { self.store = store; super.init() }
    func headers(_ contextID: String?, originalURL: String?, targetURL: String?) -> String {
        store.runtimeJSON(id: contextID, original: originalURL, target: targetURL)
    }
}
