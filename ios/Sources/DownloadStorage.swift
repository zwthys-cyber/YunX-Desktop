// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

enum DownloadStorageError: LocalizedError {
    case busy, unavailable, occupied, changed
    var errorDescription: String? {
        switch self {
        case .busy: return "下载目录正在迁移，请等待完成。"
        case .unavailable: return "下载目录无法访问。请连接原存储位置或重新授权；原文件保留。"
        case .occupied: return "目标已有 YunX 数据，或位于当前下载目录内。请选择其他空目录。"
        case .changed: return "文件在复制中变化或校验不一致，未切换目录，原文件保留。"
        }
    }
}

/// The three public paths stay stable so persisted engine/resume paths survive.
/// Cache, databases and Keychain credentials remain in their protected iOS homes.
enum DownloadStorage {
    static let names = ["Downloads", "P2P", "MediaMerged"]
    private static let lock = NSRecursiveLock()
    private static var prepared = false
    private static var migrating = false
    private static var scopes: [URL] = []
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let recordURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/download-storage.json")
    struct Target: Codable, Sendable {
        let bookmark: Data?
        let local: String?
        let folder: String
    }
    struct Record: Codable {
        var schema = 1
        var active: Target?
        var pending: Target?
        var transaction: UUID?
    }
    static var isMigrating: Bool { lock.lock(); defer { lock.unlock() }; return migrating }
    static func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !migrating else { throw DownloadStorageError.busy }
        migrating = true
    }
    static func end() { lock.lock(); migrating = !prepared; lock.unlock() }
    static func failClosed() { lock.lock(); prepared = false; migrating = true; lock.unlock() }
    private static func load() throws -> Record {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return Record() }
        let data = try Data(contentsOf: recordURL)
        guard data.count <= 131072 else { throw DownloadStorageError.unavailable }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schema == 1, (record.pending == nil) == (record.transaction == nil) else { throw DownloadStorageError.unavailable }
        return record
    }
    private static func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private static func resolve(_ target: Target) throws -> URL {
        guard target.folder.hasPrefix("YunX-"), target.folder.count == 41, UUID(uuidString: String(target.folder.dropFirst(5))) != nil,
              (target.bookmark == nil) != (target.local == nil) else { throw DownloadStorageError.unavailable }
        let parent: URL
        if let bookmark = target.bookmark {
            var stale = false
            parent = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard parent.startAccessingSecurityScopedResource() else { throw DownloadStorageError.unavailable }
            // Keep permission alive for Go and background URLSession file operations.
            scopes.append(parent)
        } else {
            guard let local = target.local else { throw DownloadStorageError.unavailable }
            parent = try localParent(local, documents: documents)
        }
        return parent.appendingPathComponent(target.folder, isDirectory: true)
    }
    static func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        guard !prepared else { return }
        var record = try load()
        if let pending = record.pending, let transaction = record.transaction {
            let root = try resolve(pending)
            try installAliases(documents: documents, target: root, transaction: transaction)
            record.active = pending; record.pending = nil; record.transaction = nil
            try save(record)
        } else if let active = record.active {
            let root = try resolve(active)
            try installAliases(documents: documents, target: root, transaction: UUID())
        }
        prepared = true
    }
    static func location() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let active = try load().active else { return "本机 YunX / 默认目录" }
        return (active.local != nil ? "本机 YunX / " : "自选目录 / ") + active.folder
    }
    static func localParent(_ value: String, documents: URL) throws -> URL {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "documents", parts.count <= 128,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), value.utf8.count <= 4096 else { throw DownloadStorageError.unavailable }
        let root = documents.resolvingSymlinksInPath().standardizedFileURL
        let parent = parts.dropFirst().reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }.resolvingSymlinksInPath().standardizedFileURL
        guard parent == root || parent.path.hasPrefix(root.path + "/") else { throw DownloadStorageError.unavailable }
        return parent
    }
    /// Called only after all transport engines and assembly writers have stopped.
    static func migrate(to parent: URL?) async throws {
        try prepare()
        let accessed = parent?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { parent?.stopAccessingSecurityScopedResource() } }
        let parent = parent ?? documents
        let canonical = parent.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDocuments = documents.resolvingSymlinksInPath().standardizedFileURL
        let isLocal = canonical == canonicalDocuments || canonical.path.hasPrefix(canonicalDocuments.path + "/")
        guard isLocal || accessed else { throw DownloadStorageError.unavailable }
        for name in names {
            let source = documents.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard canonical != source, !canonical.path.hasPrefix(source.path + "/") else { throw DownloadStorageError.occupied }
        }
        let transaction = UUID()
        let folder = "YunX-" + transaction.uuidString
        let local = isLocal ? "documents" + String(canonical.path.dropFirst(canonicalDocuments.path.count)) : nil
        let target = Target(bookmark: isLocal ? nil : try parent.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), local: local, folder: folder)
        let destination = parent.appendingPathComponent(folder, isDirectory: true)
        try await Task.detached(priority: .utility) {
            try copyVerified(documents: documents, destination: destination)
        }.value
        try commit(target, transaction: transaction)
    }
    private static func commit(_ target: Target, transaction: UUID) throws {
        // Persist intent before touching any alias. A crash resumes this short commit.
        lock.lock(); defer { lock.unlock() }
        var record = try load()
        record.pending = target; record.transaction = transaction
        try save(record)
        do {
            let scoped = try resolve(target)
            try installAliases(documents: documents, target: scoped, transaction: transaction)
            record.active = target; record.pending = nil; record.transaction = nil
            try save(record)
            prepared = true
        } catch {
            // The journal must be repaired before allowing any new writes.
            prepared = false
            throw DownloadStorageError.unavailable
        }
    }

    static func copyVerified(documents: URL, destination: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw DownloadStorageError.occupied }
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        // Incomplete copies are deliberately kept separately; never delete user data.
        for name in names {
            let original = documents.appendingPathComponent(name)
            let source = original.resolvingSymlinksInPath().standardizedFileURL
            let target = destination.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            if (try? manager.destinationOfSymbolicLink(atPath: original.path)) != nil, !manager.fileExists(atPath: source.path) { throw DownloadStorageError.unavailable }
            guard manager.fileExists(atPath: source.path) else { continue }
            var enumerationError: Error?
            var copied = Set<String>()
            guard let files = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw DownloadStorageError.unavailable }
            for case let file as URL in files {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw DownloadStorageError.changed }
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(source.path + "/") else { throw DownloadStorageError.changed }
                let relative = String(path.dropFirst(source.path.count + 1))
                copied.insert(relative)
                let output = target.appendingPathComponent(relative)
                if values.isDirectory == true { try manager.createDirectory(at: output, withIntermediateDirectories: false) }
                else if values.isRegularFile == true {
                    let before = try FileDigest.sha256(file)
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], writingItemAt: output, options: [], error: &coordinationError) { input, output in
                        do { try manager.copyItem(at: input, to: output) } catch { copyError = error }
                    }
                    if let error = coordinationError ?? (copyError as NSError?) { throw error }
                    guard try FileDigest.sha256(output) == before, try FileDigest.sha256(file) == before else { throw DownloadStorageError.changed }
                } else { throw DownloadStorageError.changed }
            }
            if let enumerationError { throw enumerationError }
            guard let recheck = manager.enumerator(at: source, includingPropertiesForKeys: nil, errorHandler: { _, error in enumerationError = error; return false }) else { throw DownloadStorageError.unavailable }
            var current = Set<String>()
            for case let file as URL in recheck { current.insert(String(file.standardizedFileURL.path.dropFirst(source.path.count + 1))) }
            if let enumerationError { throw enumerationError }
            guard current == copied else { throw DownloadStorageError.changed }
        }
        // Only a fully verified set receives this marker.
        try Data("yunx-download-storage-v1".utf8).write(to: destination.appendingPathComponent(".yunx-verified"), options: .atomic)
    }
    static func installAliases(documents: URL, target: URL, transaction: UUID) throws {
        let manager = FileManager.default
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
        for name in names {
            let source = documents.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard canonicalTarget != source, !canonicalTarget.path.hasPrefix(source.path + "/") else { throw DownloadStorageError.occupied }
        }
        let marker = try Data(contentsOf: target.appendingPathComponent(".yunx-verified"))
        guard marker == Data("yunx-download-storage-v1".utf8) else { throw DownloadStorageError.changed }
        for name in names {
            guard try manager.attributesOfItem(atPath: target.appendingPathComponent(name).path)[.type] as? FileAttributeType == .typeDirectory else { throw DownloadStorageError.changed }
        }
        for name in names {
            let source = documents.appendingPathComponent(name)
            let destination = target.appendingPathComponent(name)
            let type = try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw DownloadStorageError.changed }
            if (try? manager.destinationOfSymbolicLink(atPath: source.path)) == destination.path { continue }
            let temporary = documents.appendingPathComponent(".yunx-link-" + transaction.uuidString + "-" + name)
            if (try? manager.attributesOfItem(atPath: temporary.path)) != nil {
                guard (try? manager.destinationOfSymbolicLink(atPath: temporary.path)) == destination.path else { throw DownloadStorageError.occupied }
            } else { try manager.createSymbolicLink(at: temporary, withDestinationURL: destination) }
            let existing = try? manager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
            if existing == .typeDirectory || existing == .typeSymbolicLink {
                let backup = documents.appendingPathComponent("YunX-original-" + transaction.uuidString + "-" + name)
                guard (try? manager.attributesOfItem(atPath: backup.path)) == nil else { throw DownloadStorageError.occupied }
                try manager.moveItem(at: source, to: backup)
            } else if existing != nil, existing != .typeSymbolicLink { throw DownloadStorageError.changed }
            guard Darwin.rename(temporary.path, source.path) == 0 else { throw DownloadStorageError.unavailable }
        }
    }
}
