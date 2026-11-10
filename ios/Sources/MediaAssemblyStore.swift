// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVKit

struct AssemblyJob: Codable, Identifiable {
    enum State: String, Codable { case preparing, downloading, merging, pausing, paused, completed, failed }
    let id: UUID
    let video: URL
    let audio: URL
    let headers: [String: String]
    var filename: String
    var trackIDs: [String] = []
    var state: State = .preparing
    var received: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var segments: [URL]? = nil
    var title: String {
        switch state {
        case .preparing: return "正在准备"
        case .downloading: return segments == nil ? "下载音视频" : "下载视频片段"
        case .merging: return segments == nil ? "正在合轨" : "正在拼接"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

@MainActor
final class MediaAssemblyStore: ObservableObject {
    @Published private(set) var jobs: [AssemblyJob] = []
    @Published private(set) var storageError: String?
    private let index: URL
    private let root: URL
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var unreadable = false
    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        index = support.appendingPathComponent("YunX/assemblies.json")
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaMerged", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: index.path) {
                jobs = try JSONDecoder().decode([AssemblyJob].self, from: Data(contentsOf: index))
                for i in jobs.indices where [.preparing, .downloading, .merging, .pausing].contains(jobs[i].state) { jobs[i].state = .paused }
            }
        } catch { unreadable = true; storageError = "合轨记录无法读取，原文件未覆盖。" }
    }
    @discardableResult
    func add(_ asset: MediaAsset) -> Bool {
        guard !unreadable, let audio = asset.audioURL else { return false }
        do {
            _ = try NativeHTTPSRequest(text: asset.url.absoluteString, headers: asset.headers)
            _ = try NativeHTTPSRequest(text: audio.absoluteString, headers: asset.headers)
        } catch { storageError = "分轨地址或请求头不受支持。"; return false }
        let job = AssemblyJob(id: UUID(), video: asset.url, audio: audio, headers: asset.headers, filename: FileNamePolicy.name(asset.filename))
        jobs.insert(job, at: 0)
        guard save() else { jobs.removeAll { $0.id == job.id }; return false }
        resume(job.id)
        return true
    }
    func resume(_ id: UUID) {
        guard actions[id] == nil, let position = jobs.firstIndex(where: { $0.id == id }), jobs[position].state != .completed else { return }
        jobs[position].state = .preparing; jobs[position].error = nil
        guard save() else { jobs[position].state = .failed; jobs[position].error = storageError; return }
        actions[id] = Task { await process(id); actions.removeValue(forKey: id) }
    }
    @discardableResult
    func addSequence(_ assets: [MediaAsset], filename: String) -> Bool {
        guard !unreadable, (2...200).contains(assets.count), let first = assets.first,
              assets.allSatisfy({ $0.kind == .video && !$0.isHLS && $0.audioURL == nil && $0.headers == first.headers }) else { storageError = "只支持 2–200 个相同请求上下文的单文件视频片段。"; return false }
        do { for asset in assets { _ = try NativeHTTPSRequest(text: asset.url.absoluteString, headers: asset.headers) } }
        catch { storageError = "片段地址或请求头不受支持。"; return false }
        var job = AssemblyJob(id: UUID(), video: first.url, audio: first.url, headers: first.headers, filename: FileNamePolicy.name((filename as NSString).deletingPathExtension + ".mp4"))
        job.segments = assets.map(\.url)
        jobs.insert(job, at: 0)
        guard save() else { jobs.removeAll { $0.id == job.id }; return false }
        resume(job.id); return true
    }
    func pause(_ id: UUID) {
        actions[id]?.cancel()
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .completed else { return }
        jobs[i].state = actions[id] == nil ? .paused : .pausing; save()
    }
    func delete(_ id: UUID) {
        let previous = jobs
        let tracks = jobs.first(where: { $0.id == id })?.trackIDs ?? []
        jobs.removeAll { $0.id == id }
        guard save() else { jobs = previous; return }
        actions[id]?.cancel()
        Task { for track in tracks { _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + track, query: "force=false") } }
    }
    func output(_ job: AssemblyJob) -> URL? {
        guard job.state == .completed else { return nil }
        let file = root.appendingPathComponent(job.id.uuidString, isDirectory: true).appendingPathComponent(job.filename)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    private func process(_ id: UUID) async {
        var staging: URL?
        do {
            guard let initial = jobs.first(where: { $0.id == id }) else { return }
            let sources = initial.segments ?? [initial.video, initial.audio]
            guard (2...200).contains(sources.count) else { throw CloudError.message("媒体任务片段数量无效。") }
            for (position, url) in sources.enumerated() {
                try Task.checkCancellation()
                guard let current = jobs.first(where: { $0.id == id }) else { throw CancellationError() }
                if current.trackIDs.count <= position {
                    let trackName = initial.segments == nil ? (position == 0 ? "video.mp4" : "audio.m4a") : "segment-\(position).mp4"
                    let request = try NativeHTTPSRequest(text: url.absoluteString, filename: trackName, headers: initial.headers,
                                                        labels: ["yunxAssembly": id.uuidString])
                    let track = try await NativeEngine.shared.createHTTPS(request)
                    guard let i = jobs.firstIndex(where: { $0.id == id }) else {
                        _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + track, query: "force=false")
                        throw CancellationError()
                    }
                    jobs[i].trackIDs.append(track)
                    guard save() else {
                        jobs[i].trackIDs.removeLast()
                        _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + track, query: "force=false")
                        throw CloudError.message("合轨任务记录保存失败，已停止新建下载。")
                    }
                }
            }
            try Task.checkCancellation()
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            jobs[i].state = .downloading; save()
            let trackIDs = jobs[i].trackIDs
            let existing = try await NativeEngine.shared.tasks()
            for track in trackIDs {
                if let task = existing.first(where: { $0.id == track }), ["pause", "error"].contains(task.status) {
                    _ = try await NativeEngine.shared.invoke("PUT", path: "/api/v1/tasks/" + track + "/continue")
                }
            }
            var files: [URL] = []
            while true {
                try Task.checkCancellation()
                let tasks = try await NativeEngine.shared.tasks()
                guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                let tracks = jobs[i].trackIDs.compactMap { key in tasks.first(where: { $0.id == key }) }
                guard tracks.count == sources.count, !tracks.contains(where: { $0.status == "error" }) else { throw CloudError.message("媒体源下载失败，请重新解析或重试。") }
                jobs[i].received = Self.total(tracks.map { $0.progress?.downloaded ?? 0 })
                jobs[i].total = Self.total(tracks.map { $0.meta?.res?.size ?? 0 })
                if tracks.allSatisfy({ $0.status == "done" }) {
                    files = tracks.compactMap { NativeEngine.shared.completedFiles($0).first }
                    guard files.count == sources.count else { throw CloudError.message("媒体源文件丢失。") }
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            jobs[i].state = .merging; save()
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let scratch = folder.appendingPathComponent(".assembly-" + UUID().uuidString + ".mp4")
            staging = scratch
            if initial.segments != nil { try await AVMediaAssembly.concatenate(files, output: scratch) }
            else { try await AVMediaAssembly.merge(video: files[0], audio: files[1], output: scratch) }
            try Task.checkCancellation()
            guard let final = jobs.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: scratch); return }
            var destination = folder.appendingPathComponent(jobs[final].filename)
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent(FileNamePolicy.name(UUID().uuidString + "_" + jobs[final].filename))
            }
            try FileManager.default.moveItem(at: scratch, to: destination)
            staging = nil
            jobs[final].filename = destination.lastPathComponent
            jobs[final].state = .completed; jobs[final].error = nil
            let persisted = save()
            await Diagnostics.shared.record(.assemblyCompleted)
            if persisted { await DownloadNotifications.shared.completed() }
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
            let tracks = jobs[i].trackIDs
            for track in tracks { _ = try? await NativeEngine.shared.invoke("PUT", path: "/api/v1/tasks/" + track + "/pause") }
            guard let current = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[current].state = Task.isCancelled ? .paused : .failed
            jobs[current].error = Task.isCancelled ? nil : "下载或合轨失败，直链可能已过期，分轨文件保留以便重试。"
            save()
            if !Task.isCancelled { await Diagnostics.shared.record(.assemblyFailed) }
        }
    }
    private static func total(_ values: [Int64]) -> Int64 {
        values.reduce(0) { current, value in
            let (next, overflow) = current.addingReportingOverflow(max(0, value))
            return overflow ? Int64.max : next
        }
    }
    @discardableResult private func save() -> Bool {
        guard !unreadable else { return false }
        do {
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: index, options: [.atomic, .completeFileProtection])
            storageError = nil; return true
        } catch { storageError = "合轨记录保存失败，请检查存储空间。"; return false }
    }
}

@MainActor
struct AssemblyQueueScreen: View {
    @ObservedObject var store: MediaAssemblyStore
    @State private var selected: LocalMovieRoute?
    var body: some View {
        List {
            if let error = store.storageError { Text(error).foregroundStyle(.red) }
            ForEach(store.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.filename).lineLimit(2)
                    Text(job.title).font(.caption).foregroundStyle(.secondary)
                    if job.total > 0 { ProgressView(value: min(1, max(0, Double(job.received) / Double(job.total)))) }
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        if let file = store.output(job) {
                            Button("播放") { selected = LocalMovieRoute(url: file) }.buttonStyle(.bordered)
                            ShareLink(item: file) { Text("导出") }.buttonStyle(.bordered)
                        } else if [.preparing, .downloading, .merging].contains(job.state) {
                            Button("暂停") { store.pause(job.id) }.buttonStyle(.bordered)
                        } else if job.state == .pausing { ProgressView() }
                        else { Button("继续") { store.resume(job.id) }.buttonStyle(.bordered) }
                        Spacer()
                        Button("删除记录", role: .destructive) { store.delete(job.id) }.buttonStyle(.bordered)
                    }
                }
            }
            Text("合轨/片段拼接使用 iOS 原生无损导出；编码、尺寸或方向不兼容会保留原文件并提示失败。应用重启后手动继续；删除记录保留已下载和已合并文件。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("音视频合轨").sheet(item: $selected) { LocalMovieScreen(url: $0.url) }
    }
}
struct LocalMovieRoute: Identifiable { let id = UUID(); let url: URL }
@MainActor
struct LocalMovieScreen: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View { VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() } }
}
