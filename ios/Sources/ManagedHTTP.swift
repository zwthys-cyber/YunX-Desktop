// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum ManagedHTTPPolicy {
    static let label = "yunxManagedDownload"
    static let preference = "unifiedNativeHTTP"
    static var rateEnabled: Bool { UserDefaults.standard.integer(forKey: "engineHTTPRateKiB") > 0 }
    static var preferred: Bool { rateEnabled || UserDefaults.standard.bool(forKey: preference) }
}

extension NativeEngine {
    func managedTask(_ owner: UUID) async throws -> EngineTask? {
        let matches = try await tasks().filter { $0.meta?.req?.labels?[ManagedHTTPPolicy.label] == owner.uuidString }
        guard matches.count <= 1 else { throw CloudError.message("普通下载的原生记录重复，请先暂停后处理。") }
        guard let task = matches.first else { return nil }
        let expected = managedDownloads.appendingPathComponent(owner.uuidString, isDirectory: true).standardizedFileURL
        guard task.id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              task.protocol == "http", let path = task.meta?.opts?.path,
              URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL == expected else {
            throw CloudError.message("普通下载目录不匹配，已停止操作。")
        }
        return task
    }

    func createManaged(_ owner: UUID, url: URL, filename: String, headers: [String: String], size: Int64?, kind: String?, connections: Int) async throws -> String {
        if let task = try await managedTask(owner) { return task.id }
        let folder = managedDownloads.appendingPathComponent(owner.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw CloudError.message("原生缓存缺少任务记录，请保留原文件并重新解析下载。") }
        let request = try NativeHTTPSRequest(text: url.absoluteString, filename: filename, connections: connections,
            headers: headers, labels: [ManagedHTTPPolicy.label: owner.uuidString], accountHeaders: true,
            expectedSize: size, expectedMedia: kind, allowLoopbackHTTP: true)
        return try await createHTTPS(request, managedOwner: owner)
    }

    func pauseManaged(_ owner: UUID) async throws {
        guard let task = try await managedTask(owner), task.status != "done" else { return }
        _ = try await invoke("PUT", path: "/api/v1/tasks/" + task.id + "/pause")
    }

    func removeManaged(_ owner: UUID) async throws {
        if let task = try await managedTask(owner) {
            _ = try await invoke("DELETE", path: "/api/v1/tasks/" + task.id, query: "force=true")
        }
        let folder = managedDownloads.appendingPathComponent(owner.uuidString, isDirectory: true)
        // The parent is private and fixed. Do not follow a substituted child.
        if FileManager.default.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CloudError.message("原生缓存路径已改变，未删除。") }
            try FileManager.default.removeItem(at: folder)
        }
    }

    nonisolated func managedOutput(_ task: EngineTask, owner: UUID) throws -> URL {
        let folder = managedDownloads.appendingPathComponent(owner.uuidString, isDirectory: true)
        guard task.status == "done", task.meta?.req?.labels?[ManagedHTTPPolicy.label] == owner.uuidString,
              let path = task.meta?.opts?.path, URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL == folder.standardizedFileURL,
              let name = task.meta?.opts?.name, name == FileNamePolicy.name(name, maxBytes: 255), !name.isEmpty else {
            throw CloudError.message("原生下载尚未完成或保存来源无效。")
        }
        let file = folder.appendingPathComponent(name)
        guard folder.resolvingSymlinksInPath() == managedDownloads.resolvingSymlinksInPath().appendingPathComponent(owner.uuidString, isDirectory: true),
              try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CloudError.message("原生文件路径已改变，未保存。")
        }
        return file
    }
}
