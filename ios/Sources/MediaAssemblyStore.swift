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
    var pairedPhoto: Bool? = nil
    var outputID: UUID? = nil
    var title: String {
        switch state {
        case .preparing: return "正在准备"
        case .downloading: return pairedPhoto == true ? "下载动态照片素材" : (segments == nil ? "下载音视频" : "下载视频片段")
        case .merging: return pairedPhoto == true ? "正在生成动态照片" : (segments == nil ? "正在合轨" : "正在拼接")
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
            try DownloadStorage.prepare()
            if FileManager.default.fileExists(atPath: index.path) {
                jobs = try JSONDecoder().decode([AssemblyJob].self, from: Data(contentsOf: index))
                for i in jobs.indices where [.preparing, .downloading, .merging, .pausing].contains(jobs[i].state) { jobs[i].state = .paused }
            }
        } catch { unreadable = true; storageError = "合轨记录无法读取，原文件未覆盖。" }
    }
    @discardableResult
    func add(_ asset: MediaAsset) -> Bool {
        guard !DownloadStorage.isMigrating else { storageError = DownloadStorageError.busy.localizedDescription; return false }
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
        guard !DownloadStorage.isMigrating else { return }
        guard actions[id] == nil, let position = jobs.firstIndex(where: { $0.id == id }), jobs[position].state != .completed || output(jobs[position]) == nil else { return }
        jobs[position].state = .preparing; jobs[position].error = nil
        guard save() else { jobs[position].state = .failed; jobs[position].error = storageError; return }
        actions[id] = Task { await process(id); actions.removeValue(forKey: id) }
    }
    @discardableResult
    func addSequence(_ assets: [MediaAsset], filename: String) -> Bool {
        guard !DownloadStorage.isMigrating else { storageError = DownloadStorageError.busy.localizedDescription; return false }
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
    @discardableResult
    func addLivePhoto(_ asset: MediaAsset) -> Bool {
        guard !DownloadStorage.isMigrating else { storageError = DownloadStorageError.busy.localizedDescription; return false }
        guard !unreadable, asset.kind == .image, let movie = asset.livePhotoVideoURL else { return false }
        do {
            _ = try NativeHTTPSRequest(text: asset.url.absoluteString, headers: asset.headers)
            _ = try NativeHTTPSRequest(text: movie.absoluteString, headers: asset.headers)
        } catch { storageError = "动态照片素材地址或请求头不受支持。"; return false }
        var job = AssemblyJob(id: UUID(), video: asset.url, audio: movie, headers: asset.headers, filename: FileNamePolicy.name((asset.filename as NSString).deletingPathExtension + ".jpg"))
        job.pairedPhoto = true
        jobs.insert(job, at: 0)
        guard save() else { jobs.removeAll { $0.id == job.id }; return false }
        resume(job.id); return true
    }
    func delete(_ id: UUID) {
        let previous = jobs
        let tracks = jobs.first(where: { $0.id == id })?.trackIDs ?? []
        jobs.removeAll { $0.id == id }
        guard save() else { jobs = previous; return }
        actions[id]?.cancel()
        Task { for track in tracks { _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + track, query: "force=false") } }
    }
    func quiesceForStorage() async throws {
        for job in jobs where job.state != .completed { pause(job.id) }
        let deadline = Date().addingTimeInterval(60)
        while !actions.isEmpty {
            guard Date() < deadline else { throw DownloadStorageError.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func output(_ job: AssemblyJob) -> URL? {
        guard job.state == .completed else { return nil }
        let file = outputFolder(job).appendingPathComponent(job.filename)
        if job.pairedPhoto == true, let movie = pairedMovie(job), !FileManager.default.fileExists(atPath: movie.path) { return nil }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func pairedMovie(_ job: AssemblyJob) -> URL? {
        guard job.pairedPhoto == true else { return nil }
        return outputFolder(job).appendingPathComponent((job.filename as NSString).deletingPathExtension + ".mov")
    }
    private func outputFolder(_ job: AssemblyJob) -> URL {
        let folder = root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        return job.outputID.map { folder.appendingPathComponent($0.uuidString, isDirectory: true) } ?? folder
    }
    private func process(_ id: UUID) async {
        var staging: URL?
        do {
            guard let initial = jobs.first(where: { $0.id == id }) else { return }
            let sources = initial.segments ?? [initial.video, initial.audio]
            guard (2...200).contains(sources.count), initial.pairedPhoto != true || initial.segments == nil else { throw CloudError.message("媒体任务片段数量或合成模式无效。") }
            for (position, url) in sources.enumerated() {
                try Task.checkCancellation()
                guard let current = jobs.first(where: { $0.id == id }) else { throw CancellationError() }
                if current.trackIDs.count <= position {
                    let trackName = initial.pairedPhoto == true ? (position == 0 ? "photo.jpg" : "motion.mov") : (initial.segments == nil ? (position == 0 ? "video.mp4" : "audio.m4a") : "segment-\(position).mp4")
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
            if initial.pairedPhoto == true {
                let outputID = UUID()
                let scratch = folder.appendingPathComponent(".livephoto-" + UUID().uuidString, isDirectory: true)
                staging = scratch
                let photoName = FileNamePolicy.name((initial.filename as NSString).deletingPathExtension + ".jpg"), movieName = (photoName as NSString).deletingPathExtension + ".mov"
                try await LivePhotoAssembly.create(image: files[0], video: files[1], photoOutput: scratch.appendingPathComponent(photoName), movieOutput: scratch.appendingPathComponent(movieName), identifier: initial.id.uuidString)
                try Task.checkCancellation()
                guard let final = jobs.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                try FileManager.default.moveItem(at: scratch, to: folder.appendingPathComponent(outputID.uuidString, isDirectory: true))
                staging = nil
                jobs[final].filename = photoName; jobs[final].outputID = outputID; jobs[final].state = .completed; jobs[final].error = nil
                let persisted = save()
                await Diagnostics.shared.record(.assemblyCompleted)
                if persisted { await DownloadNotifications.shared.completed() }
                return
            }
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
            jobs[current].error = Task.isCancelled ? nil : "下载或媒体合成失败，直链、格式或系统支持可能受限；原素材保留以便重试。"
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
    private var displayedJobs: [AssemblyJob] {
        store.jobs.enumerated().sorted {
            if ($0.element.state == .failed) != ($1.element.state == .failed) { return $0.element.state == .failed }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    @State private var selected: LocalMovieRoute?
    @State private var selectedLivePhoto: LivePhotoRoute?
    @State private var exporting: ExportFilesRoute?
    var body: some View {
        List {
            if let error = store.storageError { Text(error).foregroundStyle(.red) }
            ForEach(displayedJobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.filename).lineLimit(2)
                    Text(job.title).font(.caption).foregroundStyle(.secondary)
                    if job.total > 0 { ProgressView(value: min(1, max(0, Double(job.received) / Double(job.total)))) }
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        if let file = store.output(job) {
                            if job.pairedPhoto == true, let movie = store.pairedMovie(job) {
                                Button("动态照片") { selectedLivePhoto = LivePhotoRoute(photo: file, movie: movie) }.buttonStyle(.bordered)
                                Button("导出配对文件") { exporting = ExportFilesRoute(files: [file, movie]) }.buttonStyle(.bordered)
                            } else {
                                Button("播放") { selected = LocalMovieRoute(url: file) }.buttonStyle(.bordered)
                                ShareLink(item: file) { Text("导出") }.buttonStyle(.bordered)
                            }
                        } else if [.preparing, .downloading, .merging].contains(job.state) {
                            Button("暂停") { store.pause(job.id) }.buttonStyle(.bordered)
                        } else if job.state == .pausing { ProgressView() }
                        else { Button(job.state == .completed ? "重新生成" : "继续") { store.resume(job.id) }.buttonStyle(.bordered) }
                        Spacer()
                        Button("删除记录", role: .destructive) { store.delete(job.id) }.buttonStyle(.bordered)
                    }
                }
            }
            Text("合轨/片段拼接使用 iOS 原生无损导出；编码、尺寸或方向不兼容会保留原文件并提示失败。动态照片生成 JPEG/MOV 配对，经系统识别后才能完成；保存图库时单独请求添加权限。应用重启后手动继续；删除记录保留原文件和结果。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("媒体合轨与拼接").sheet(item: $selected) { LocalMovieScreen(url: $0.url) }
            .sheet(item: $selectedLivePhoto) { LivePhotoScreen(photoURL: $0.photo, movieURL: $0.movie) }
            .sheet(item: $exporting) { ExportFilesView(files: $0.files) }
    }
}
struct LocalMovieRoute: Identifiable { let id = UUID(); let url: URL }
@MainActor
struct LocalMovieScreen: View {
    @State private var player: AVPlayer
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View { VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() } }
}
