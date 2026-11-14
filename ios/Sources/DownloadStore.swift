// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Combine
import UniformTypeIdentifiers
import Yunxengine

struct DownloadItem: Codable, Identifiable {
    enum State: String, Codable {
        case waiting, downloading, saving, pausing, paused, completed, failed
        var title: String {
            switch self {
            case .waiting: return "等待中"
            case .downloading: return "下载中"
            case .saving: return "正在校验保存"
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
    var pendingSave: Bool?
    var nativeTransfer: Bool?
    var nativeTaskID: String?
    var foregroundOnly: Bool?
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
            YunxengineSetGlobalDownloadLimit(maximumConcurrent)
            drainQueue()
        }
    }
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var latestTaskIdentity: [UUID: ObjectIdentifier] = [:]
    private var transferSlots: [UUID: String] = [:]
    private var removed = Set<UUID>()
    private let root: URL
    private let cache: URL
    private var session: URLSession!
    private var backgroundSession: URLSession?
    private var restoringBackground = false
    private var restorableBackground = Set<UUID>()
    private var notificationWork: [UUID: Task<Void, Never>] = [:]
    private var saveWorkers: [UUID: Task<DownloadFileSave.Result, Error>] = [:]
    private var saveWork: [UUID: Task<Void, Never>] = [:]
    private let manager = FileManager.default
    private var unreadableIndex = false
    private var retryWake: DispatchWorkItem?
    private let nativeEnabled: Bool
    private var nativeWork: [UUID: Task<Void, Never>] = [:]
    private var nativeDeletes = Set<UUID>()
    private var nativeDeleteRecords = Set<UUID>()
    private var nativeCleanup: [UUID: Task<Void, Never>] = [:]
    private var networkPolicyTransition = false

    override convenience init() {
        self.init(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true),
                  cache: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX", isDirectory: true), backgroundEnabled: true, nativeEnabled: true)
    }

    init(root: URL, cache: URL, configuration: URLSessionConfiguration = .default, backgroundEnabled: Bool = false, nativeEnabled: Bool = false) {
        self.root = root; self.cache = cache; self.nativeEnabled = nativeEnabled
        super.init()
        YunxengineSetGlobalDownloadLimit(maximumConcurrent)
        do {
            if backgroundEnabled { try DownloadStorage.prepare() }
            let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: protection)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: protection)
            let deletions = cache.appendingPathComponent("native-deletes.json")
            if manager.fileExists(atPath: deletions.path) {
                let journal = try JSONDecoder().decode(NativeCleanupJournal.self, from: Data(contentsOf: deletions))
                guard journal.removed.isSubset(of: journal.owners) else { throw DownloadStorageError.unavailable }
                nativeDeletes = journal.owners; nativeDeleteRecords = journal.removed
            }
            let index = cache.appendingPathComponent("tasks.json")
            if manager.fileExists(atPath: index.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: index))
                restorableBackground = Set(items.filter { [.downloading, .waiting].contains($0.state) && $0.backgroundTransfer == true }.map(\.id))
                for index in items.indices where [.downloading, .saving, .pausing, .waiting].contains(items[index].state) {
                    items[index].state = .paused
                }
                for index in items.indices {
                    if items[index].state == .completed {
                        DownloadFileSave.discard(cache: cache, id: items[index].id)
                        if items[index].nativeTaskID != nil { nativeDeletes.insert(items[index].id) }
                    }
                    else if items[index].pendingSave == true || DownloadFileSave.pending(cache: cache, id: items[index].id) {
                        if DownloadFileSave.bodyMissing(cache: cache, id: items[index].id) {
                            items[index].pendingSave = nil
                            items[index].state = .failed
                            items[index].error = "完整文件未能保留，请重试或重新解析下载。"
                            DownloadFileSave.discard(cache: cache, id: items[index].id)
                        } else {
                            items[index].pendingSave = true
                            items[index].state = .paused
                            restorableBackground.remove(items[index].id)
                        }
                    }
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
            YunxengineSetHTTPRestoring(true)
            let background = URLSessionConfiguration.background(withIdentifier: BackgroundDownloadPolicy.identifier)
            background.sessionSendsLaunchEvents = true
            background.isDiscretionary = false
            background.httpCookieStorage = nil; background.httpShouldSetCookies = false; background.urlCredentialStorage = nil
            backgroundSession = URLSession(configuration: background, delegate: self, delegateQueue: .main)
            backgroundSession?.getAllTasks { [weak self] tasks in
                DispatchQueue.main.async { self?.restoreBackground(tasks) }
            }
        }
        if !nativeDeletes.isEmpty, saveNativeDeletes() { for owner in nativeDeletes { scheduleNativeCleanup(owner) } }
    }

    @discardableResult
    func add(_ url: URL, filename: String? = nil, headers: [String: String] = [:],
             expectedSize: Int64? = nil, expectedMedia: String? = nil, originFallback: URL? = nil, allowsBackground: Bool = true) -> Bool {
        guard !unreadableIndex else { return false }
        guard !DownloadStorage.isMigrating else { storageError = DownloadStorageError.busy.localizedDescription; return false }
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
        item.foregroundOnly = !allowsBackground
        item.backgroundTransfer = allowsBackground && backgroundSession != nil && BackgroundDownloadPolicy.allows(url, headers: headers)
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
        guard !DownloadStorage.isMigrating else { return }
        guard !unreadableIndex, active[id] == nil, nativeWork[id] == nil, saveWorkers[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              [.waiting, .paused, .failed].contains(items[index].state) else { return }
        let previous = items[index]
        items[index].state = .waiting
        items[index].error = nil
        items[index].retryCount = 0; items[index].retryAt = nil
        guard save() else { items[index] = previous; return }
        drainQueue()
    }

    private func drainQueue() {
        guard !unreadableIndex, !restoringBackground, !networkPolicyTransition, !DownloadStorage.isMigrating else { return }
        retryWake?.cancel(); retryWake = nil
        let now = Date()
        for id in items.reversed().filter({ $0.state == .waiting && ($0.retryAt ?? .distantPast) <= now }).map(\.id) {
            guard Set(active.keys).union(saveWorkers.keys).union(nativeWork.keys).count < max(1, min(6, maximumConcurrent)), YunxengineAvailableDownloadSlots() > 0 else { break }
            launch(id)
        }
        if let date = items.filter({ $0.state == .waiting }).compactMap(\.retryAt).filter({ $0 > now }).min() {
            let work = DispatchWorkItem { [weak self] in self?.drainQueue() }
            retryWake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, date.timeIntervalSinceNow), execute: work)
        }
        if Set(active.keys).union(saveWorkers.keys).union(nativeWork.keys).count < max(1, min(6, maximumConcurrent)), items.contains(where: { $0.state == .waiting && ($0.retryAt ?? .distantPast) <= now }) {
            retryWake?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.drainQueue() }
            retryWake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
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
        for id in items.filter({ [.waiting, .downloading, .saving].contains($0.state) }).map(\.id) {
            pause(id)
        }
    }

    func resumeAll() {
        guard !DownloadStorage.isMigrating else { return }
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
        guard !DownloadStorage.isMigrating else { return }
        guard active[id] == nil, nativeWork[id] == nil, saveWorkers[id] == nil, let index = items.firstIndex(where: { $0.id == id }),
              items[index].state != .completed, items[index].state != .pausing else { return }
        if items[index].pendingSave == true {
            let slot = id.uuidString + ".save." + UUID().uuidString
            guard YunxengineAcquireHTTPTask(slot, false) else { return }
            transferSlots[id] = slot
            beginSave(id)
            return
        }
        guard !nativeDeletes.contains(id) else { return }
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
        if items[index].nativeTransfer == true || (nativeEnabled && ManagedHTTPPolicy.preferred) {
            // A newly selected native transfer uses the official GitHub source,
            // matching the dedicated native GitHub mode. Keep the old system
            // resume archive until publication; it is never consumed by Go.
            if items[index].nativeTransfer != true, items[index].requiresHeaders != true,
               let origin = items[index].originFallback, GitHubMirrorPolicy.publicOrigin(origin) {
                items[index].url = origin
                items[index].originFallback = nil
            }
            items[index].nativeTransfer = true
            items[index].backgroundTransfer = false
            items[index].state = .downloading
            items[index].error = nil
            guard save() else { items[index].state = .failed; return }
            let item = items[index]
            nativeWork[id] = Task { @MainActor [self] in await runNative(item, headers: headers) }
            return
        }
        let usesBackground = items[index].foregroundOnly != true && backgroundSession != nil && BackgroundDownloadPolicy.allows(items[index].url, headers: headers)
        let targetSession = usesBackground ? backgroundSession! : session!
        let resume: Data?
        do { resume = try DownloadResumeVault.shared.read(from: resumeURL(id), id: id) }
        catch {
            items[index].state = .failed
            items[index].error = error.localizedDescription
            save()
            return
        }
        let slot = id.uuidString + "." + UUID().uuidString
        guard YunxengineAcquireHTTPTask(slot, false) else { return }
        transferSlots[id] = slot
        let task: URLSessionDownloadTask
        if let resume {
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
            releaseSlot(id)
            task.taskDescription = nil
            task.cancel()
            items[index].state = .failed
            items[index].error = "无法保存任务状态，下载未启动。"
            return
        }
        task.resume()
    }

    private func restoreBackground(_ tasks: [URLSessionTask]) {
        defer { restoringBackground = false; YunxengineSetHTTPRestoring(false); restorableBackground.removeAll(); drainQueue() }
        guard !unreadableIndex else { tasks.forEach { $0.cancel() }; return }
        for candidate in tasks {
            guard let task = candidate as? URLSessionDownloadTask, let raw = task.taskDescription, let id = UUID(uuidString: raw),
                  let index = items.firstIndex(where: { $0.id == id }), items[index].backgroundTransfer == true,
                  items[index].state != .completed, items[index].pendingSave != true, !removed.contains(id) else { candidate.cancel(); continue }
            guard task.state == .running || task.state == .suspended else { continue }
            if let current = active[id], current !== task { task.cancel(); continue }
            active[id] = task
            latestTaskIdentity[id] = ObjectIdentifier(task)
            if transferSlots[id] == nil {
                let slot = id.uuidString + "." + UUID().uuidString
                _ = YunxengineAcquireHTTPTask(slot, true)
                transferSlots[id] = slot
            }
            if restorableBackground.contains(id) && !networkPolicyTransition && !(nativeEnabled && ManagedHTTPPolicy.rateEnabled) {
                items[index].state = .downloading; items[index].error = nil
                items[index].received = max(items[index].received, task.countOfBytesReceived)
                if task.countOfBytesExpectedToReceive > 0 { items[index].expected = task.countOfBytesExpectedToReceive }
                if task.state == .suspended { task.resume() }
            } else { pause(id) }
        }
        if !save() { pauseAll() }
    }

    func pause(_ id: UUID) {
        if let work = nativeWork[id], let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .pausing
            save()
            work.cancel()
            return
        }
        if let worker = saveWorkers[id], let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .pausing
            save()
            worker.cancel()
            return
        }
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
                guard self.items[index].pendingSave != true else { return }
                self.writeResume(data, id: id)
                self.active.removeValue(forKey: id)
                self.releaseSlot(id)
                self.items[index].state = .paused
                self.save()
                self.drainQueue()
            }
        }
    }

    func quiesceForStorage() async throws {
        let deadline = Date().addingTimeInterval(60)
        while restoringBackground {
            guard Date() < deadline else { throw DownloadStorageError.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
        pauseAll()
        // Deleting a record removes it from active immediately, but its physical
        // transfer still owns a slot until the completion callback closes it.
        while !active.isEmpty || !transferSlots.isEmpty || !saveWork.isEmpty || !nativeWork.isEmpty || !nativeCleanup.isEmpty || networkPolicyTransition {
            guard Date() < deadline else { throw DownloadStorageError.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !unreadableIndex, nativeDeletes.isEmpty, save() else { throw DownloadStorageError.unavailable }
    }

    func delete(_ id: UUID) {
        guard !unreadableIndex else { return }
        let isNative = items.first(where: { $0.id == id })?.nativeTransfer == true
        if isNative {
            nativeDeletes.insert(id)
            nativeDeleteRecords.insert(id)
            guard saveNativeDeletes() else { nativeDeletes.remove(id); nativeDeleteRecords.remove(id); return }
        }
        let previous = items
        items.removeAll { $0.id == id }
        guard save() else { items = previous; if isNative { nativeDeletes.remove(id); nativeDeleteRecords.remove(id); _ = saveNativeDeletes() }; return }
        removed.insert(id)
        if let work = nativeWork[id] { work.cancel() }
        else if isNative { scheduleNativeCleanup(id) }
        if let worker = saveWorkers[id] { worker.cancel() }
        else { DownloadFileSave.discard(cache: cache, id: id) }
        if let task = active.removeValue(forKey: id) { task.cancel() }
        else { latestTaskIdentity.removeValue(forKey: id) }
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

    private struct NativeCleanupJournal: Codable { let owners: Set<UUID>; let removed: Set<UUID> }

    @discardableResult private func saveNativeDeletes() -> Bool {
        do {
            try JSONEncoder().encode(NativeCleanupJournal(owners: nativeDeletes, removed: nativeDeleteRecords)).write(
                to: cache.appendingPathComponent("native-deletes.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { storageError = "无法保存原生清理记录，文件已保留。"; return false }
    }

    private func requestNativeCleanup(_ owner: UUID) {
        nativeDeletes.insert(owner)
        if saveNativeDeletes() { scheduleNativeCleanup(owner) }
    }

    private func scheduleNativeCleanup(_ owner: UUID) {
        guard !unreadableIndex, nativeCleanup[owner] == nil, nativeWork[owner] == nil else { return }
        nativeCleanup[owner] = Task { @MainActor [self] in
            defer { nativeCleanup.removeValue(forKey: owner); drainQueue() }
            for attempt in 0..<3 {
                do {
                    try await NativeEngine.shared.removeManaged(owner)
                    nativeDeletes.remove(owner)
                    if nativeDeleteRecords.remove(owner) != nil {
                        items.removeAll { $0.id == owner }
                        if saveWorkers[owner] == nil { DownloadFileSave.discard(cache: cache, id: owner) }
                        DownloadHeaders.delete(owner)
                        try? manager.removeItem(at: resumeURL(owner))
                    } else if let index = items.firstIndex(where: { $0.id == owner }) { items[index].nativeTaskID = nil }
                    _ = saveNativeDeletes(); save()
                    return
                } catch {
                    if attempt < 2 { try? await Task.sleep(for: .milliseconds(500 * (attempt + 1))) }
                }
            }
            storageError = "原生任务仍待清理，清理记录已保留；请恢复引擎后重新打开应用。"
        }
    }

    @MainActor private func runNative(_ original: DownloadItem, headers: [String: String]) async {
        let id = original.id
        defer {
            nativeWork.removeValue(forKey: id)
            if nativeDeletes.contains(id) { scheduleNativeCleanup(id) }
            drainQueue()
        }
        do {
            let taskID: String
            if let existing = try await NativeEngine.shared.managedTask(id) { taskID = existing.id }
            else {
                guard original.nativeTaskID == nil else { throw CloudError.message("原生断点记录不可用，请保留文件并重新解析。") }
                taskID = try await NativeEngine.shared.createManaged(id, url: original.url, filename: original.filename,
                    headers: headers, size: original.requiredSize, kind: original.expectedMedia, connections: 1)
            }
            try Task.checkCancellation()
            guard let index = items.firstIndex(where: { $0.id == id }), !removed.contains(id) else { throw CancellationError() }
            items[index].nativeTaskID = taskID
            guard save() else { throw CloudError.message("原生状态未保存，已暂停下载。") }
            if let current = try await NativeEngine.shared.managedTask(id), ["pause", "error"].contains(current.status) {
                _ = try await NativeEngine.shared.invoke("PUT", path: "/api/v1/tasks/" + taskID + "/continue")
            }
            while true {
                try Task.checkCancellation()
                guard let task = try await NativeEngine.shared.managedTask(id) else { throw CloudError.message("原生任务已被移除，请重新解析下载。") }
                try Task.checkCancellation()
                guard let index = items.firstIndex(where: { $0.id == id }), !removed.contains(id) else { throw CancellationError() }
                items[index].received = task.progress?.downloaded ?? items[index].received
                items[index].expected = task.meta?.res?.size ?? items[index].expected
                if task.status == "done" {
                    let file = try NativeEngine.shared.managedOutput(task, owner: id)
                    try DownloadFileSave.retain(file, cache: cache, id: id, proposed: items[index].filename,
                        kind: items[index].expectedMedia, mime: nil, requiredSize: items[index].requiredSize)
                    items[index].pendingSave = true
                    items[index].state = .waiting
                    guard save() else { items[index].state = .paused; return }
                    requestNativeCleanup(id)
                    return
                }
                if task.status == "error" { throw CloudError.message("原生下载未完成，片段已保留；重试时会重新校验。") }
                if task.status == "pause" {
                    items[index].state = .paused; save(); return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            // A cancelled UI operation still must await physical engine pause.
            let paused = await Task.detached { () -> Bool in
                do { try await NativeEngine.shared.pauseManaged(id); return true } catch { return false }
            }.value
            guard let index = items.firstIndex(where: { $0.id == id }), !removed.contains(id) else { return }
            if items[index].pendingSave == true { items[index].state = .paused }
            else { items[index].state = error is CancellationError && paused ? .paused : .failed }
            items[index].error = error is CancellationError && paused ? nil : "原生下载未完成，请检查网络、存储和来源后重试；原片段已保留。"
            save()
        }
    }

    @MainActor func pauseSystemForRateLimit() async throws {
        networkPolicyTransition = true
        do {
            let deadline = Date().addingTimeInterval(60)
            while restoringBackground {
                guard Date() < deadline else { throw DownloadStorageError.busy }
                try await Task.sleep(for: .milliseconds(100))
            }
            for id in Array(active.keys) { pause(id) }
            while !active.isEmpty {
                guard Date() < deadline else { throw DownloadStorageError.busy }
                try await Task.sleep(for: .milliseconds(100))
            }
            for index in items.indices where items[index].nativeTransfer != true && items[index].pendingSave != true && [.waiting, .paused, .failed].contains(items[index].state) {
                items[index].state = .paused
                items[index].error = "已启用共享限速。继续将从头使用原生前台下载，旧系统断点保留至保存成功。"
            }
            guard !unreadableIndex, save() else { throw DownloadStorageError.unavailable }
        } catch {
            finishHTTPPolicyTransition()
            throw error
        }
    }

    @MainActor func finishHTTPPolicyTransition() { networkPolicyTransition = false; drainQueue() }

    private func resumeURL(_ id: UUID) -> URL {
        cache.appendingPathComponent("\(id.uuidString).resume")
    }
    private func releaseSlot(_ id: UUID) {
        if let slot = transferSlots.removeValue(forKey: id) { YunxengineReleaseHTTPTask(slot) }
    }
    private func matchesTask(_ session: URLSession, task: URLSessionTask, id: UUID) -> Bool {
        guard items.first(where: { $0.id == id })?.nativeTransfer != true else { return false }
        if let identity = latestTaskIdentity[id] { return identity == ObjectIdentifier(task) }
        // A completed background event can arrive before or after getAllTasks.
        // Only this store's real background session can adopt an unknown task.
        guard session === backgroundSession, session.configuration.identifier == BackgroundDownloadPolicy.identifier,
              !removed.contains(id), let item = items.first(where: { $0.id == id }), item.backgroundTransfer == true, item.state != .completed, item.pendingSave != true,
              let downloadTask = task as? URLSessionDownloadTask else { return false }
        latestTaskIdentity[id] = ObjectIdentifier(task)
        active[id] = downloadTask
        if transferSlots[id] == nil {
            let slot = id.uuidString + "." + UUID().uuidString
            _ = YunxengineAcquireHTTPTask(slot, true)
            transferSlots[id] = slot
        }
        return true
    }

    private func writeResume(_ data: Data?, id: UUID) {
        guard let data else { return }
        do { try DownloadResumeVault.shared.write(data, to: resumeURL(id), id: id) }
        catch {
            storageError = "无法安全保存下载断点，原断点已保留。"
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].error = "断点未能安全保存；继续时可能从旧断点或文件开头重新下载。"
            }
        }
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
        guard matchesTask(session, task: downloadTask, id: id) else { return }
        guard items[index].state != .completed, items[index].pendingSave != true else { return }
        items[index].received = totalBytesWritten
        items[index].expected = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let value = downloadTask.taskDescription, let id = UUID(uuidString: value),
              !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }), items[index].state != .completed, items[index].pendingSave != true else { return }
        guard matchesTask(session, task: downloadTask, id: id) else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            if queueOriginFallback(index) { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            if queueRetry(index, status: status, retryAfter: (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) { return }
            Task { await Diagnostics.shared.record(.downloadFailed, code: status) }
            items[index].state = .failed
            items[index].error = status.map { "服务器拒绝下载（HTTP \($0)）。请重新解析下载地址后重试。" } ?? "服务器未返回有效的 HTTP 响应。"
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
            try DownloadFileSave.retain(location, cache: cache, id: id, proposed: initialName,
                kind: items[index].expectedMedia, mime: response.mimeType, requiredSize: items[index].requiredSize)
            items[index].pendingSave = true
            items[index].state = .saving
            guard save() else {
                items[index].state = .paused
                items[index].error = "完整下载已保留；下载记录恢复可写后可继续保存。"
                return
            }
            beginSave(id)
            return
        } catch {
            items[index].state = .failed
            items[index].error = "无法保存文件：\(error.localizedDescription)"
            Task { await Diagnostics.shared.record(.downloadFailed) }
        }
        save()
    }

    private func beginSave(_ id: UUID) {
        guard saveWorkers[id] == nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .saving
        items[index].error = nil
        guard save() else { items[index].state = .paused; if active[id] == nil { releaseSlot(id) }; return }
        let cache = self.cache, root = self.root
        let worker = Task.detached(priority: .utility) { try DownloadFileSave.finish(cache: cache, id: id, root: root) }
        saveWorkers[id] = worker
        saveWork[id] = Task { @MainActor [self] in
            let result = await worker.result
            defer {
                saveWorkers.removeValue(forKey: id)
                saveWork.removeValue(forKey: id)
                if active[id] == nil { releaseSlot(id) }
                drainQueue()
            }
            guard !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else {
                DownloadFileSave.discard(cache: cache, id: id)
                return
            }
            switch result {
            case .success(let output):
                let previous = items[index]
                items[index].filename = output.filename
                items[index].received = output.size
                items[index].state = .completed
                items[index].pendingSave = nil
                items[index].error = nil
                guard save() else {
                    items[index] = previous
                    items[index].state = .paused
                    items[index].error = "文件已写入目标目录，记录恢复可写后请继续确认保存。"
                    return
                }
                DownloadFileSave.discard(cache: cache, id: id)
                try? manager.removeItem(at: resumeURL(id))
                DownloadHeaders.delete(id)
                if items[index].nativeTransfer == true { requestNativeCleanup(id) }
                notifyCompleted(size: output.size)
            case .failure(let error):
                items[index].state = error is CancellationError ? .paused : .failed
                items[index].error = error is CancellationError ? nil : "保存未完成，下载缓存已保留。请检查目录权限和可用空间后继续。"
                if DownloadFileSave.bodyMissing(cache: cache, id: id) {
                    items[index].pendingSave = nil
                    items[index].state = .failed
                    items[index].error = "完整文件未能保留，请重试或重新解析下载。"
                    DownloadFileSave.discard(cache: cache, id: id)
                }
                save()
            }
        }
    }

    private func notifyCompleted(size: Int64) {
        let notificationID = UUID()
        notificationWork[notificationID] = Task { @MainActor [weak self] in
            await Diagnostics.shared.record(.downloadCompleted, bytes: size)
            await DownloadNotifications.shared.completed()
            self?.notificationWork.removeValue(forKey: notificationID)
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
        guard matchesTask(session, task: task, id: id) else { return }
        active.removeValue(forKey: id)
        if saveWorkers[id] == nil { releaseSlot(id) }
        if removed.contains(id) { latestTaskIdentity.removeValue(forKey: id) }
        defer { drainQueue() }
        guard !removed.contains(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state == .completed { save(); return }
        if items[index].pendingSave == true { return }
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
        let saves = Array(saveWork.values)
        Task { @MainActor [self] in
            for save in saves { await save.value }
            let notifications = Array(notificationWork.values)
            for notification in notifications { await notification.value }
            BackgroundDownloadEvents.finished()
        }
    }
}
