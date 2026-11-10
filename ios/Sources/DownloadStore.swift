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
    var url: URL
    var filename: String
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var requiresHeaders: Bool?
    var preserveFilename: Bool?
    var requiredSize: Int64?
    var sha256: String?
    var expectedMedia: String?
    var backgroundTransfer: Bool?
    var originFallback: URL?
    var retryCount: Int?
    var retryAt: Date?
}

/// URLSession 的委托队列显式使用主队列；所有 UI 操作也在主线程执行。
/// Public HTTPS downloads can use the system background session; credentialed requests stay in-process.
final class DownloadStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadStore()
    @Published private(set) var items: [DownloadItem] = []
    @Published var storageError: String?
    @Published private(set) var hashing = Set<UUID>()
    @Published var maximumConcurrent = max(1, min(6, UserDefaults.standard.integer(forKey: "downloadConcurrency") == 0 ? 3 : UserDefaults.standard.integer(forKey: "downloadConcurrency"))) {
        didSet {
            UserDefaults.standard.set(maximumConcurrent, forKey: "downloadConcurrency")
            drainQueue()
        }
    }
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var latestTaskIdentity: [UUID: ObjectIdentifier] = [:]
    private var removed = Set<UUID>()
    private let root: URL
    private let cache: URL
    private var session: URLSession!
    private var backgroundSession: URLSession?
    private var restoringBackground = false
    private var restorableBackground = Set<UUID>()
    private var notificationWork: [UUID: Task<Void, Never>] = [:]
    private let manager = FileManager.default
    private var unreadableIndex = false
    private var retryWake: DispatchWorkItem?

    override convenience init() {
        self.init(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true),
                  cache: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX", isDirectory: true), backgroundEnabled: true)
    }

    init(root: URL, cache: URL, configuration: URLSessionConfiguration = .default, backgroundEnabled: Bool = false) {
        self.root = root; self.cache = cache
        super.init()
        do {
            let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: protection)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: protection)
            let index = cache.appendingPathComponent("tasks.json")
            if manager.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: index))
                restorableBackground = Set(items.filter { [.downloading, .waiting].contains($0.state) && $0.backgroundTransfer == true }.map(\.id))
                for index in items.indices where [.downloading, .pausing, .waiting].contains(items[index].state) {
                    items[index].state = .paused
                }
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: index.path)
                for item in items where manager.fileExists(atPath: resumeURL(item.id).path) {
                    try manager.setAttributes(protection, ofItemAtPath: resumeURL(item.id).path)
                }
            }
        } catch {
            unreadableIndex = true
            storageError = "下载记录无法读取，原记录已保留；请恢复可用空间或从备份处理后重启。"
        }
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        session = NetworkProxy.session(configuration: config, delegate: self, delegateQueue: .main)
        if backgroundEnabled {
            restoringBackground = true
            let background = URLSessionConfiguration.background(withIdentifier: BackgroundDownloadPolicy.identifier)
            background.sessionSendsLaunchEvents = true
            background.isDiscretionary = false
            background.httpCookieStorage = nil; background.httpShouldSetCookies = false; background.urlCredentialStorage = nil
            backgroundSession = URLSession(configuration: background, delegate: self, delegateQueue: .main)
            backgroundSession?.getAllTasks { [weak self] tasks in
                DispatchQueue.main.async { self?.restoreBackground(tasks) }
            }
        }
    }

    @discardableResult
    func add(_ url: URL, filename: String? = nil, headers: [String: String] = [:],
             expectedSize: Int64? = nil, expectedMedia: String? = nil, originFallback: URL? = nil) -> Bool {
        guard !unreadableIndex else { return false }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else {
            storageError = "只接受不含账号密码的 HTTP 或 HTTPS 文件直链"
            return false
        }
        let name = safeName(filename ?? url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        if let originFallback, (!headers.isEmpty || !GitHubMirrorPolicy.publicOrigin(originFallback) || url.scheme != "https") {
            storageError = "仅无认证的公开 GitHub 下载允许镜像回退。"; return false
        }
        var item = DownloadItem(id: UUID(), url: url, filename: name, state: .waiting)
        item.originFallback = originFallback
        item.requiresHeaders = !headers.isEmpty
        item.preserveFilename = filename != nil
        item.requiredSize = expectedSize
        item.expectedMedia = expectedMedia
        item.backgroundTransfer = backgroundSession != nil && BackgroundDownloadPolicy.allows(url, headers: headers)
        if !headers.isEmpty {
            do { try DownloadHeaders.save(headers, id: item.id) }
            catch { storageError = error.localizedDescription; return false }
        }
        storageError = nil
        items.insert(item, at: 0)
        guard save() else {
            items.removeAll { $0.id == item.id }
            DownloadHeaders.delete(item.id)
            return false
        }
        Task { await Diagnostics.shared.record(.downloadAdded) }
        drainQueue()
        return true
    }

    func start(_ id: UUID) {
        guard !unreadableIndex, active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              [.waiting, .paused, .failed].contains(items[index].state) else { return }
        let previous = items[index]
        items[index].state = .waiting
        items[index].error = nil
        items[index].retryCount = 0; items[index].retryAt = nil
        guard save() else { items[index] = previous; return }
        drainQueue()
    }

    private func drainQueue() {
        guard !unreadableIndex, !restoringBackground else { return }
        retryWake?.cancel(); retryWake = nil
        let now = Date()
        for id in items.reversed().filter({ $0.state == .waiting && ($0.retryAt ?? .distantPast) <= now }).map(\.id) {
            guard active.count < max(1, min(6, maximumConcurrent)) else { break }
            launch(id)
        }
        if let date = items.filter({ $0.state == .waiting }).compactMap(\.retryAt).filter({ $0 > now }).min() {
            let work = DispatchWorkItem { [weak self] in self?.drainQueue() }
            retryWake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, date.timeIntervalSinceNow), execute: work)
        }
    }
    func refreshForegroundNetworking() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 60
        let old = session
        session = NetworkProxy.session(configuration: config, delegate: self, delegateQueue: .main)
        old?.finishTasksAndInvalidate()
    }

    func pauseAll() {
        for id in items.filter({ [.waiting, .downloading].contains($0.state) }).map(\.id) {
            pause(id)
        }
    }

    func resumeAll() {
        guard !unreadableIndex else { return }
        let previous = items
        for index in items.indices where [.paused, .failed].contains(items[index].state) {
            items[index].state = .waiting
            items[index].error = nil
            items[index].retryCount = 0; items[index].retryAt = nil
        }
        guard save() else { items = previous; return }
        drainQueue()
    }

    private func launch(_ id: UUID) {
        guard active[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              items[index].state != .completed, items[index].state != .pausing else { return }
        guard NetworkProxy.ready else { items[index].state = .failed; items[index].error = "代理设置不可用，请到设置中修复后重试。"; save(); return }
        var request = URLRequest(url: items[index].url)
        var headers: [String: String] = [:]
        if items[index].requiresHeaders == true {
            do {
                headers = try DownloadHeaders.load(id)
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            } catch {
                items[index].state = .failed
                items[index].error = "下载凭证不可用，请解锁设备或重新解析文件。"
                save()
                return
            }
        }
        let usesBackground = backgroundSession != nil && BackgroundDownloadPolicy.allows(items[index].url, headers: headers)
        let targetSession = usesBackground ? backgroundSession! : session!
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(id)) {
            task = targetSession.downloadTask(withResumeData: resume)
        } else {
            task = targetSession.downloadTask(with: request)
        }
        task.taskDescription = id.uuidString
        active[id] = task
        latestTaskIdentity[id] = ObjectIdentifier(task)
        items[index].state = .downloading
        items[index].retryAt = nil
        items[index].backgroundTransfer = usesBackground
        items[index].error = nil
        guard save() else {
            active.removeValue(forKey: id)
            task.taskDescription = nil
            task.cancel()
            items[index].state = .failed
            items[index].error = "无法保存任务状态，下载未启动。"
            return
        }
        task.resume()
    }

    private func restoreBackground(_ tasks: [URLSessionTask]) {
        defer { restoringBackground = false; restorableBackground.removeAll(); drainQueue() }
        guard !unreadableIndex else { tasks.forEach { $0.cancel() }; return }
        for candidate in tasks {
            guard let task = candidate as? URLSessionDownloadTask, let raw = task.taskDescription, let id = UUID(uuidString: raw),
                  let index = items.firstIndex(where: { $0.id == id }), items[index].backgroundTransfer == true,
                  items[index].state != .completed, !removed.contains(id) else { candidate.cancel(); continue }
            guard task.state == .running || task.state == .suspended else { continue }
            guard active[id] == nil else { task.cancel(); continue }
            active[id] = task
            latestTaskIdentity[id] = ObjectIdentifier(task)
            if restorableBackground.contains(id) {
                items[index].state = .downloading; items[index].error = nil
                items[index].received = max(items[index].received, task.countOfBytesReceived)
                if task.countOfBytesExpectedToReceive > 0 { items[index].expected = task.countOfBytesExpectedToReceive }
                if task.state == .suspended { task.resume() }
            } else { pause(id) }
        }
        if !save() { pauseAll() }
    }

    func pause(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }), items[index].state == .waiting {
            items[index].state = .paused
            save()
            return
        }
        guard let task = active[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .pausing
        save()
        task.cancel { [weak self] data in
            DispatchQueue.main.async {
                guard let self, !self.removed.contains(id), self.latestTaskIdentity[id] == ObjectIdentifier(task),
                      let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                guard self.items[index].state != .completed else { return }
                self.writeResume(data, id: id)
                self.active.removeValue(forKey: id)
                self.items[index].state = .paused
                self.save()
                self.drainQueue()
            }
        }
    }

    func delete(_ id: UUID) {
        guard !unreadableIndex else { return }
        let previous = items
        items.removeAll { $0.id == id }
        guard save() else { items = previous; return }
        removed.insert(id)
        active.removeValue(forKey: id)?.cancel()
        latestTaskIdentity.removeValue(forKey: id)
        try? manager.removeItem(at: resumeURL(id))
        DownloadHeaders.delete(id)
        // 下载完成的文件保留，删除记录不会隐式删除用户文件。
        drainQueue()
    }

    func fileURL(_ item: DownloadItem) -> URL? {
        guard item.state == .completed else { return nil }
        let url = root.appendingPathComponent(item.filename)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    func calculateChecksum(_ id: UUID) {
        guard !hashing.contains(id), let item = items.first(where: { $0.id == id }), let file = fileURL(item) else { return }
        hashing.insert(id)
        Task { @MainActor [weak self] in
            defer { self?.hashing.remove(id) }
            do {
                let digest = try await Task.detached(priority: .utility) { try FileDigest.sha256(file) }.value
                guard let self, let index = self.items.firstIndex(where: { $0.id == id && $0.state == .completed }) else { return }
                self.items[index].sha256 = digest
                self.save()
            } catch { self?.storageError = "无法计算文件 SHA-256，请确认文件存在且未被修改。" }
        }
    }

    private func resumeURL(_ id: UUID) -> URL {
        cache.appendingPathComponent("\(id.uuidString).resume")
    }

    private func writeResume(_ data: Data?, id: UUID) {
        guard let data else { return }
        do { try data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { storageError = "无法保存断点：\(error.localizedDescription)" }
    }

    @discardableResult private func save() -> Bool {
        guard !unreadableIndex else { return false }
        do {
            try JSONEncoder().encode(items).write(
                to: cache.appendingPathComponent("tasks.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            storageError = nil
            return true
        } catch { storageError = "无法保存下载记录，请检查可用空间。"; return false }
    }

    private func safeName(_ raw: String) -> String {
        FileNamePolicy.name(raw)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let latest = latestTaskIdentity[id], latest != ObjectIdentifier(downloadTask) { return }
        guard items[index].state != .completed else { return }
        items[index].received = totalBytesWritten
        items[index].expected = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }), items[index].state != .completed else { return }
        if let latest = latestTaskIdentity[id], latest != ObjectIdentifier(downloadTask) { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            if queueOriginFallback(index) { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            if queueRetry(index, status: status, retryAfter: (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) { return }
            Task { await Diagnostics.shared.record(.downloadFailed, code: status) }
            items[index].state = .failed
            items[index].error = "服务器未返回成功的 HTTP 状态"
            save()
            return
        }
        do {
            if let expected = items[index].requiredSize, expected > 0 {
                let actual = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard Int64(actual) == expected else {
                    if queueOriginFallback(index) { return }
                    throw CloudError.message("返回文件大小与平台记录不一致，已拒绝保存。")
                }
            }
            let initialName = items[index].preserveFilename == true ? items[index].filename :
                safeName(response.suggestedFilename ?? items[index].filename)
            let proposed = try MediaFileValidation.filename(initialName, file: location, kind: items[index].expectedMedia, mime: response.mimeType)
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
            DownloadHeaders.delete(id)
        } catch {
            items[index].state = .failed
            items[index].error = "无法保存文件：\(error.localizedDescription)"
            Task { await Diagnostics.shared.record(.downloadFailed) }
        }
        if save(), items[index].state == .completed {
            let size = items[index].received
            let notificationID = UUID()
            notificationWork[notificationID] = Task { @MainActor [weak self] in
                await Diagnostics.shared.record(.downloadCompleted, bytes: size)
                await DownloadNotifications.shared.completed()
                self?.notificationWork.removeValue(forKey: notificationID)
            }
        }
    }

    @discardableResult
    private func queueRetry(_ index: Int, status: Int? = nil, error: NSError? = nil, retryAfter: String? = nil) -> Bool {
        let count = items[index].retryCount ?? 0
        guard let delay = DownloadRetry.delay(attempt: count, status: status, error: error, retryAfter: retryAfter) else { return false }
        let previous = items[index]
        items[index].retryCount = count + 1; items[index].retryAt = Date().addingTimeInterval(delay)
        items[index].state = .waiting; items[index].error = "临时网络故障，将自动重试（\(count + 1)/3）。"
        guard save() else { items[index] = previous; return false }
        return true
    }

    @discardableResult
    private func queueOriginFallback(_ index: Int) -> Bool {
        guard let origin = items[index].originFallback, items[index].requiresHeaders != true,
              GitHubMirrorPolicy.publicOrigin(origin) else { return false }
        let previous = items[index]
        items[index].url = origin; items[index].originFallback = nil
        items[index].received = 0; items[index].expected = 0; items[index].state = .waiting
        items[index].retryCount = 0; items[index].retryAt = nil
        items[index].error = nil
        // A mirror resume archive can contain its request URL and incompatible bytes.
        try? manager.removeItem(at: resumeURL(previous.id))
        guard save() else { items[index] = previous; return false }
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if let raw = task.taskDescription, let id = UUID(uuidString: raw),
           let item = items.first(where: { $0.id == id }), item.requiresHeaders == true {
            let headers = (try? DownloadHeaders.load(id)) ?? [:]
            for key in ["Cookie", "Authorization", "Proxy-Authorization"] {
                redirected.setValue(nil, forHTTPHeaderField: key)
            }
            for (key, value) in DownloadHeaders.redirectHeaders(headers, original: item.url, target: target) {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let value = task.taskDescription, let id = UUID(uuidString: value) else { return }
        if let latest = latestTaskIdentity[id], latest != ObjectIdentifier(task) { return }
        active.removeValue(forKey: id)
        defer { drainQueue() }
        guard !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state == .completed { save(); return }
        if items[index].state == .pausing { return }
        if items[index].state == .waiting { return }
        if items[index].state == .paused, let cancellation = error as NSError?,
           cancellation.domain == NSURLErrorDomain, cancellation.code == NSURLErrorCancelled {
            writeResume(cancellation.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, id: id)
            save(); return
        }
        if let error = error as NSError? {
            if error.code != NSURLErrorCancelled, queueOriginFallback(index) { return }
            let code = error.code
            Task { await Diagnostics.shared.record(.downloadFailed, code: code) }
            writeResume(error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, id: id)
            if error.userInfo[NSURLSessionDownloadTaskResumeData] == nil { try? manager.removeItem(at: resumeURL(id)) }
            if queueRetry(index, error: error) { return }
            items[index].state = .failed
            // 不展示 NSError 描述，避免把带有凭证的完整请求 URL 显示或记录。
            items[index].error = "网络错误（\(error.domain)，\(error.code)），可重试"
            // 系统未提供可恢复数据时丢弃旧断点，下次重试从原始 URL 开始。
            if error.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
                try? manager.removeItem(at: resumeURL(id))
            }
        }
        save()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session.configuration.identifier == BackgroundDownloadPolicy.identifier else { return }
        let notifications = Array(notificationWork.values)
        Task { @MainActor in
            for notification in notifications { await notification.value }
            BackgroundDownloadEvents.finished()
        }
    }
}
