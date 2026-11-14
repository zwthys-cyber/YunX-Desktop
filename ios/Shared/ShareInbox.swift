// SPDX-License-Identifier: AGPL-3.0-only
// Compiled separately into the host and share extension; contains no account access.
import Foundation
import Darwin

struct ShareInboxItem: Codable, Identifiable, Equatable {
    let id: UUID
    let created: Date
    let text: String
}
enum ShareInboxError: LocalizedError {
    case unavailable, tooLarge, full, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此安装包无法访问共享收件箱，请复制链接后到云析中粘贴。"
        case .tooLarge: return "分享文字超过 32KB，请只分享需要的链接。"
        case .full: return "分享收件箱已有 100 项，请在云析中删除已处理内容。"
        case .invalid: return "分享内容为空或损坏，原文件已保留。"
        }
    }
}
struct ShareInbox {
    static let group = "group.io.github.zwthys.yunx"
    static func configuredGroup(_ info: [String: Any]) -> String? {
        if let setting = info["YunXShareExtensionEnabled"] { guard let enabled = setting as? Bool, enabled else { return nil } }
        let value: String
        if let setting = info["YunXAppGroupIdentifier"] { guard let name = setting as? String else { return nil }; value = name }
        else { value = group }
        guard value.utf8.count <= 255, value.range(of: #"\Agroup(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    static var container: URL? {
        guard let value = configuredGroup(Bundle.main.infoDictionary ?? [:]) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: value)
    }
    let root: URL?
    init(root: URL? = ShareInbox.container) {
        self.root = root?.appendingPathComponent("ShareInbox", isDirectory: true)
    }
    @discardableResult func append(_ text: String) throws -> ShareInboxItem {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ShareInboxError.invalid }
        guard text.utf8.count <= 32768 else { throw ShareInboxError.tooLarge }
        return try locked { directory in
            let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            guard existing.count < 100 else { throw ShareInboxError.full }
            let item = ShareInboxItem(id: UUID(), created: Date(), text: text)
            try JSONEncoder().encode(item).write(to: directory.appendingPathComponent(item.id.uuidString + ".json"), options: [.atomic, .completeFileProtection])
            return item
        }
    }
    func items() throws -> [ShareInboxItem] {
        try locked { directory in
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).filter { $0.pathExtension == "json" }
        guard files.count <= 100 else { throw ShareInboxError.full }
        return try files.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 262144 else { throw ShareInboxError.invalid }
            let item = try JSONDecoder().decode(ShareInboxItem.self, from: Data(contentsOf: url))
            guard url.lastPathComponent == item.id.uuidString + ".json", !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.text.utf8.count <= 32768 else { throw ShareInboxError.invalid }
            return item
        }.sorted { $0.created < $1.created }
        }
    }
    func remove(_ id: UUID) throws { try locked { directory in try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) } }
    private func locked<T>(_ operation: (URL) throws -> T) throws -> T {
        let directory = try prepare()
        let descriptor = open(directory.appendingPathComponent(".inbox-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ShareInboxError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ShareInboxError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation(directory)
    }
    private func prepare() throws -> URL {
        guard let root else { throw ShareInboxError.unavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ShareInboxError.invalid }
        return root
    }
}
