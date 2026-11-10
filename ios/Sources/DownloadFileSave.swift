// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// The URLSession temporary body must be retained before its delegate returns.
/// Only that same-volume rename runs on the delegate queue; validation, hashing
/// and the potentially cross-volume copy run in a cancellable worker.
enum DownloadFileSave {
    struct Receipt: Codable {
        var proposed: String
        var kind: String?
        var mime: String?
        var requiredSize: Int64?
        var destination: String?
        var digest: String?
        var size: Int64?
    }
    struct Result {
        let filename: String
        let size: Int64
    }
    private static func folder(_ cache: URL, _ id: UUID) -> URL {
        cache.appendingPathComponent("CompletedBodies", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static func pending(cache: URL, id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: folder(cache, id).appendingPathComponent("receipt.json").path)
    }
    static func discard(cache: URL, id: UUID) {
        try? FileManager.default.removeItem(at: folder(cache, id))
    }
    static func retain(_ temporary: URL, cache: URL, id: UUID, proposed: String,
                       kind: String?, mime: String?, requiredSize: Int64?) throws {
        let directory = folder(cache, id)
        // Never replace a previously retained complete body.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CloudError.message("此任务已有待保存文件，请先继续保存。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            let receipt = Receipt(proposed: FileNamePolicy.name(proposed), kind: kind, mime: mime, requiredSize: requiredSize)
            try write(receipt, directory: directory)
            let body = directory.appendingPathComponent("body")
            // rename(2) fails across volumes instead of copying a large file on main.
            let result = temporary.path.withCString { source in body.path.withCString { target in Darwin.rename(source, target) } }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    private static func write(_ receipt: Receipt, directory: URL) throws {
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private static func regularSize(_ file: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw CloudError.message("待保存路径不是普通文件。")
        }
        return size.int64Value
    }
    static func finish(cache: URL, id: UUID, root: URL) throws -> Result {
        let manager = FileManager.default, directory = folder(cache, id)
        let body = directory.appendingPathComponent("body")
        var receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
        try Task.checkCancellation()
        let size = try regularSize(body)
        if let expected = receipt.requiredSize, expected > 0, expected != size {
            throw CloudError.message("返回文件大小与平台记录不一致，已拒绝保存。")
        }
        let digest = try FileDigest.sha256(body)
        if let previous = receipt.digest, previous != digest {
            throw CloudError.message("待保存文件发生变化，已保留文件供处理。")
        }
        if receipt.destination == nil {
            let name = try MediaFileValidation.filename(receipt.proposed, file: body, kind: receipt.kind, mime: receipt.mime)
            var target = root.appendingPathComponent(FileNamePolicy.name(name))
            if manager.fileExists(atPath: target.path) {
                let original = URL(fileURLWithPath: name), ext = original.pathExtension
                let stem = original.deletingPathExtension().lastPathComponent
                target = root.appendingPathComponent(ext.isEmpty ? "\(stem)-\(id.uuidString)" : "\(stem)-\(id.uuidString).\(ext)")
            }
            guard !manager.fileExists(atPath: target.path) else { throw CloudError.message("目标文件已存在，请移开同名文件后继续保存。") }
            receipt.destination = target.lastPathComponent
            receipt.digest = digest; receipt.size = size
            // Commit the intended output and digest before publishing any final file.
            try write(receipt, directory: directory)
        }
        guard let name = receipt.destination, name == FileNamePolicy.name(name, maxBytes: 255), receipt.digest == digest, receipt.size == size else {
            throw CloudError.message("保存恢复记录不完整，已保留原文件。")
        }
        let destination = root.appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            // Recovery after rename but before tasks.json was committed.
            guard try regularSize(destination) == size, try FileDigest.sha256(destination) == digest else {
                throw CloudError.message("目标位置已有不同文件，已停止保存且不会覆盖。")
            }
            return Result(filename: name, size: size)
        }
        let partial = root.appendingPathComponent(".yunx-save-\(id.uuidString).part")
        if manager.fileExists(atPath: partial.path) {
            _ = try regularSize(partial)
            try manager.removeItem(at: partial)
        }
        guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw CloudError.message("无法在目标目录创建文件，完整下载仍保留在应用中。")
        }
        defer { try? manager.removeItem(at: partial) }
        let input = try FileHandle(forReadingFrom: body)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try output.close()
        guard try regularSize(partial) == size, try FileDigest.sha256(partial) == digest else {
            throw CloudError.message("保存后的文件校验失败，完整下载仍保留在应用中。")
        }
        try Task.checkCancellation()
        // Both paths are in the destination directory; this does not copy across volumes.
        try manager.moveItem(at: partial, to: destination)
        return Result(filename: name, size: size)
    }
}
