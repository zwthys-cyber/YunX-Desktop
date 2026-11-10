// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct P2PInput {
    static func link(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 32_768 else { throw CloudError.message("P2P 链接过长。") }
        if text.lowercased().hasPrefix("magnet:?") {
            guard let parts = URLComponents(string: text), parts.queryItems?.contains(where: {
                $0.name.lowercased() == "xt" && ($0.value?.range(of: "^(urn:btih:([0-9a-f]{40}|[a-z2-7]{32})|urn:btmh:1220[0-9a-f]{64})$", options: [.regularExpression, .caseInsensitive]) != nil)
            }) == true else { throw CloudError.message("磁力链接缺少有效的 BT 标识。") }
            return text
        }
        if text.lowercased().hasPrefix("ed2k://|file|") {
            let parts = text.components(separatedBy: "|")
            guard parts.count >= 6, parts.last == "/", !parts[2].isEmpty, let size = Int64(parts[3]), size > 0,
                  parts[4].range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
                throw CloudError.message("ed2k 文件名、大小或哈希无效。")
            }
            return text
        }
        throw CloudError.message("请输入 magnet 磁力链接、ed2k 链接，或导入 .torrent 文件。")
    }
    static func trackers(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count <= 1000 else { throw CloudError.message("Tracker 最多 1000 条。") }
        var seen = Set<String>()
        return try lines.filter { seen.insert($0).inserted }.map { line in
            guard line.utf8.count <= 2048, let url = URL(string: line),
                  ["https", "http", "udp", "wss", "ws"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { throw CloudError.message("Tracker 地址无效。") }
            return line
        }
    }
}

@MainActor
final class P2PStore: ObservableObject {
    @Published var tasks: [EngineTask] = []
    @Published var busy = false
    @Published var message: String?
    func refresh() async {
        do { tasks = try await NativeEngine.shared.tasks().filter { $0.meta?.req?.labels?["yunxAssembly"] == nil } }
        catch { if !Task.isCancelled { message = "引擎任务读取失败，请重试。" } }
    }
    func add(_ raw: String, trackers: String) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let link = try P2PInput.link(raw)
            try await NativeEngine.shared.create(link, trackers: P2PInput.trackers(trackers))
            message = "已加入 P2P 队列。"
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func addHTTPS(_ text: String, filename: String, connections: Int, checksum: String) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let request = try NativeHTTPSRequest(text: text, filename: filename, connections: connections, checksum: checksum)
            try await NativeEngine.shared.createHTTPS(request)
            message = "已加入原生下载队列；若设置预期摘要，校验不匹配会标记失败。"
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func action(_ task: EngineTask, operation: String) async {
        guard !busy, let escaped = task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !escaped.contains("/") else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            if operation == "delete" { _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + escaped, query: "force=false") }
            else { _ = try await NativeEngine.shared.invoke("PUT", path: "/api/v1/tasks/" + escaped + "/" + operation) }
            await refresh()
        } catch { message = "引擎操作失败，请刷新任务后重试。" }
    }
    func importTorrent(_ url: URL, trackers: String) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard url.pathExtension.lowercased() == "torrent", size > 0, size <= 16 * 1024 * 1024 else { throw CloudError.message("请选择不超过 16MB 的有效 .torrent 文件。") }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/Torrents", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString + ".torrent")
            try FileManager.default.copyItem(at: url, to: destination)
            do { try await NativeEngine.shared.create(destination.absoluteString, trackers: P2PInput.trackers(trackers)) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            message = "种子已加入 P2P 队列。"
            await refresh()
        } catch { message = "种子导入失败，请检查文件类型、大小和 Tracker。" }
    }
}

struct P2PScreen: View {
    @StateObject private var store = P2PStore()
    @State private var input = ""
    init(initialInput: String = "") { _input = State(initialValue: initialInput) }
    @State private var https = ""
    @State private var filename = ""
    @State private var checksum = ""
    @State private var confirmConnections = false
    @AppStorage("engineHTTPConnections") private var httpConnections = 4
    @State private var importing = false
    @State private var deleting: EngineTask?
    @AppStorage("engineTrackers") private var trackers = ""
    @AppStorage("engineDHT") private var dht = false
    @AppStorage("engineParallel") private var parallel = 3
    var body: some View {
        List {
            Section("多连接 HTTPS 下载") {
                TextField("https://… 文件直链", text: $https, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("文件名（可选）", text: $filename)
                TextField("预期 SHA-256（可选）", text: $checksum, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("连接数：\(httpConnections)", value: $httpConnections, in: 1...512)
                Button("加入原生下载") {
                    if httpConnections > 32 { confirmConnections = true }
                    else { Task { await store.addHTTPS(https, filename: filename, connections: httpConnections, checksum: checksum) } }
                }.disabled(store.busy || https.isEmpty)
                Text("支持 Range 的服务器可分片并发；不支持时由引擎回退顺序下载。此入口不接收账号请求头。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("P2P 下载") {
                TextField("magnet:?xt=… / ed2k://…", text: $input, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("加入下载") { Task { await store.add(input, trackers: trackers) } }.disabled(store.busy || input.isEmpty)
                Button("导入 .torrent 种子") { importing = true }.disabled(store.busy)
                Text("内置原生 Gopeed 引擎，当前按前台任务运行。进入后台可能被系统暂停；不保证后台常驻。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("引擎设置") {
                Toggle("DHT（重启应用后生效）", isOn: $dht)
                Stepper("同时任务：\(parallel)", value: $parallel, in: 1...6)
                TextField("Tracker 地址，每行一条", text: $trackers, axis: .vertical).lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存到引擎") {
                    Task {
                        do {
                            try await NativeEngine.shared.configure(trackers: P2PInput.trackers(trackers), dht: dht, parallel: parallel)
                            store.message = "配置已保存；DHT 需重启应用以重建连接。"
                        } catch { store.message = "配置未保存，请检查 Tracker 地址。" }
                    }
                }.disabled(store.busy)
            }
            if let message = store.message { Section { Text(message).foregroundStyle(.secondary) } }
            Section("任务") {
                ForEach(store.tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.name).lineLimit(2)
                        Text(task.statusTitle + " · " + task.protocol).font(.caption).foregroundStyle(.secondary)
                        let received = task.progress?.downloaded ?? 0
                        let total = task.meta?.res?.size ?? 0
                        Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file) + " · " + ByteCountFormatter.string(fromByteCount: task.progress?.speed ?? 0, countStyle: .file) + "/s").font(.caption)
                        if total > 0 { ProgressView(value: min(1, max(0, Double(received) / Double(total)))) }
                        NavigationLink("连接与任务诊断") { P2PPeersScreen(task: task) }.font(.caption)
                        HStack {
                            if ["running", "wait", "ready"].contains(task.status) {
                                Button("暂停") { Task { await store.action(task, operation: "pause") } }.buttonStyle(.bordered)
                            } else if task.status != "done" {
                                Button("继续") { Task { await store.action(task, operation: "continue") } }.buttonStyle(.bordered)
                            }
                            if task.status == "done" { NavigationLink("文件") { P2PFilesScreen(task: task) }.buttonStyle(.bordered) }
                            Spacer()
                            Button("删除记录", role: .destructive) { deleting = task }.buttonStyle(.bordered)
                        }.disabled(store.busy)
                    }
                }
            }
            Section("开源") {
                Link("Gopeed 源码与 GPL-3.0", destination: URL(string: "https://github.com/GopeedLab/gopeed")!)
                Text("固定上游版本及对应源码随 GitHub 构建产物保存。")
            }
        }.navigationTitle("原生引擎任务")
            .task {
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
            .confirmationDialog("连接数超过 32，可能增加设备资源占用或触发服务器限制。", isPresented: $confirmConnections, titleVisibility: .visible) {
                Button("按所选连接数创建") { Task { await store.addHTTPS(https, filename: filename, connections: httpConnections, checksum: checksum) } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { Task { await store.importTorrent(url, trackers: trackers) } }
            }
            .confirmationDialog("删除记录并停止任务？已下载文件保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除记录", role: .destructive) {
                    if let task = deleting { Task { await store.action(task, operation: "delete") } }
                    deleting = nil
                }
            }
    }
}
struct P2PFilesScreen: View {
    let task: EngineTask
    @State private var files: [URL] = []
    var body: some View {
        List {
            if files.isEmpty { Text("没有找到可导出的完成文件。") }
            ForEach(files, id: \.self) { file in ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") } }
        }.navigationTitle("已下载文件").task { files = NativeEngine.shared.completedFiles(task) }
    }
}

struct EnginePeerStats: Decodable {
    struct Peer: Decodable {
        let address: String?
        let client: String?
        let downloadSpeed: Int64?
        let uploadSpeed: Int64?
        let completion: Double?
        let transport: String?
    }
    struct Runtime: Decodable {
        let totalPeers: Int?
        let activePeers: Int?
        let connectedSeeders: Int?
        let connectedLeechers: Int?
        let peers: [Peer]?
    }
    struct Snapshot: Decodable {
        struct Connection: Decodable {
            let downloaded: Int64
            let total: Int64
            let completed: Bool
            let failed: Bool
            let retryTimes: Int
        }
        let connections: [Connection]?
        let seedBytes: Int64?
        let seedRatio: Double?
        let seedTime: Int64?
    }
    let runtime: Runtime?
    let snapshot: Snapshot?
}
struct P2PPeersScreen: View {
    let task: EngineTask
    @State private var stats: EnginePeerStats?
    @State private var message: String?
    var body: some View {
        List {
            Section("连接概览") {
                if let runtime = stats?.runtime {
                    if let total = runtime.totalPeers { LabeledContent("已知 Peer", value: String(total)) }
                    if let active = runtime.activePeers { LabeledContent("活动 Peer", value: String(active)) }
                    if let seeds = runtime.connectedSeeders { LabeledContent("已连接做种者", value: String(seeds)) }
                    if let leechers = runtime.connectedLeechers { LabeledContent("已连接下载者", value: String(leechers)) }
                } else { Text("当前没有活动连接数据。") }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            if let snapshot = stats?.snapshot {
                if let connections = snapshot.connections {
                    Section("HTTP 连接") {
                        ForEach(Array(connections.enumerated()), id: \.offset) { offset, connection in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("连接 \(offset + 1) · " + (connection.failed ? "失败" : (connection.completed ? "完成" : "传输中")))
                                Text(ByteCountFormatter.string(fromByteCount: connection.downloaded, countStyle: .file) + " · 重试 \(connection.retryTimes) 次").font(.caption)
                                if connection.total > 0 { ProgressView(value: min(1, max(0, Double(connection.downloaded) / Double(connection.total)))) }
                            }
                        }
                        Text("进度按引擎返回的平均份额显示；连接可动态分配或接管工作，不代表固定字节区间。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if snapshot.seedBytes != nil || snapshot.seedRatio != nil || snapshot.seedTime != nil { Section("累计做种") {
                    if let bytes = snapshot.seedBytes { LabeledContent("上传", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if let ratio = snapshot.seedRatio { LabeledContent("分享率", value: String(format: "%.2f", ratio)) }
                    if let time = snapshot.seedTime { LabeledContent("做种时长", value: "\(time) 秒") }
                } }
            }
            Section("Peer") {
                ForEach(Array((stats?.runtime?.peers ?? []).enumerated()), id: \.offset) { _, peer in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peer.address ?? "未知地址").font(.caption.monospaced()).textSelection(.enabled)
                        Text([peer.client, peer.transport].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text("↓ " + ByteCountFormatter.string(fromByteCount: peer.downloadSpeed ?? 0, countStyle: .file) + "/s  ↑ " + ByteCountFormatter.string(fromByteCount: peer.uploadSpeed ?? 0, countStyle: .file) + "/s").font(.caption)
                        if let completion = peer.completion { ProgressView(value: min(1, max(0, completion))) }
                    }
                }
            }
        }.navigationTitle("连接与任务诊断").task {
            while !Task.isCancelled {
                do {
                    guard let id = task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !id.contains("/") else { return }
                    let data = try await NativeEngine.shared.invoke("GET", path: "/api/v1/tasks/" + id + "/stats")
                    stats = try JSONDecoder().decode(EngineEnvelope<EnginePeerStats>.self, from: data).data
                    message = nil
                } catch { if !Task.isCancelled { message = "连接统计暂不可用，任务可能仍在解析或已停止。" } }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
}
