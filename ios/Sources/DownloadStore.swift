// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import UniformTypeIdentifiers

struct DownloadItem: Codable, Identifiable {
    enum State: String, Codable {
        case waiting, downloading, pausing, paused, completed, failed
        var title: String {
            switch self {
            case .waiting: return "等待中"
            case .downloading: return "下载中"
            case .pausing: return "正在暂停"
            case .paused: return "已暂停"
            case .completed: return "已完成"
            case .failed: return "失败"
            }
        }
    }
    let id: UUID
    let url: URL
    var filename: String
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
}

/// URLSession 的委托队列显式使用主队列；所有 UI 操作也在主线程执行。
/// 本阶段使用前台会话，不宣称支持长时间后台下载。
final class DownloadStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    @Published var storageError: String?
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var removed = Set<UUID>()
    private let root: URL
    private let cache: URL
    private var session: URLSession!
    private let manager = FileManager.default

    override init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YunX", isDirectory: true)
        super.init()
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            let index = cache.appendingPathComponent("tasks.json")
            if manager.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: index))
                for index in items.indices where [.downloading, .pausing, .waiting].contains(items[index].state) {
                    items[index].state = .paused
                }
            }
        } catch {
            storageError = "无法读取下载记录：\(error.localizedDescription)"
        }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func add(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            storageError = "只接受 HTTP 或 HTTPS 文件直链"
            return
        }
        let name = safeName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        let item = DownloadItem(id: UUID(), url: url, filename: name, state: .waiting)
        items.insert(item, at: 0)
        save()
        start(item.id)
    }

    func start(_ id: UUID) {
        guard active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              items[index].state != .completed, items[index].state != .pausing else { return }
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(id)) {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: items[index].url)
        }
        task.taskDescription = id.uuidString
        active[id] = task
        items[index].state = .downloading
        items[index].error = nil
        save()
        task.resume()
    }

    func pause(_ id: UUID) {
        guard let task = active[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .pausing
        save()
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self, !self.removed.contains(id),
                      let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.writeResume(data, id: id)
                self.active.removeValue(forKey: id)
                self.items[index].state = .paused
                self.save()
            }
        }
    }

    func delete(_ id: UUID) {
        removed.insert(id)
        active.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
        try? manager.removeItem(at: resumeURL(id))
        // 下载完成的文件保留，删除记录不会隐式删除用户文件。
        save()
    }

    func fileURL(_ item: DownloadItem) -> URL? {
        guard item.state == .completed else { return nil }
        let url = root.appendingPathComponent(item.filename)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    private func resumeURL(_ id: UUID) -> URL {
        cache.appendingPathComponent("\(id.uuidString).resume")
    }

    private func writeResume(_ data: Data?, id: UUID) {
        guard let data else { return }
        do { try data.write(to: resumeURL(id), options: [.atomic, .completeFileProtection]) }
        catch { storageError = "无法保存断点：\(error.localizedDescription)" }
    }

    private func save() {
        do {
            try JSONEncoder().encode(items).write(
                to: cache.appendingPathComponent("tasks.json"),
                options: [.atomic, .completeFileProtection]
            )
        } catch { storageError = "无法保存下载记录：\(error.localizedDescription)" }
    }

    private func safeName(_ raw: String) -> String {
        let filtered = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r"))
            .joined(separator: "_")
        if filtered.isEmpty || filtered == "." || filtered == ".." { return "download.bin" }
        return String(filtered.prefix(160))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].received = totalBytesWritten
        items[index].expected = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            items[index].state = .failed
            items[index].error = "服务器未返回成功的 HTTP 状态"
            save()
            return
        }
        do {
            let proposed = safeName(response.suggestedFilename ?? items[index].filename)
            let original = URL(fileURLWithPath: proposed)
            let ext = original.pathExtension
            let stem = original.deletingPathExtension().lastPathComponent
            var destination = root.appendingPathComponent(proposed)
            if manager.fileExists(atPath: destination.path) {
                let suffix = id.uuidString
                destination = root.appendingPathComponent(
                    ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                )
            }
            try manager.moveItem(at: location, to: destination)
            items[index].filename = destination.lastPathComponent
            items[index].state = .completed
            items[index].received = (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init) ?? items[index].received
            try? manager.removeItem(at: resumeURL(id))
        } catch {
            items[index].state = .failed
            items[index].error = "无法保存文件：\(error.localizedDescription)"
        }
        save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        active.removeValue(forKey: id)
        guard !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state == .pausing { return }
        if let error = error as NSError? {
            writeResume(error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, id: id)
            items[index].state = .failed
            // 不展示 NSError 描述，避免把带有凭证的完整请求 URL 显示或记录。
            items[index].error = "网络错误（\(error.domain)，\(error.code)），可重试"
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotResume {
                try? manager.removeItem(at: resumeURL(id))
            }
        }
        save()
    }
}
