// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI

/// Only fixed event names and numeric values can enter the exported log.
/// Request URLs, filenames, headers, account identifiers and raw errors are excluded.
actor Diagnostics {
    enum Kind: String, Codable { case appOpened, engineStarted, engineStartFailed, engineOperationFailed, downloadAdded, downloadCompleted, downloadFailed, assemblyCompleted, assemblyFailed }
    struct Event: Codable {
        let time: Date
        let kind: Kind
        let code: Int?
        let bytes: Int64?
    }
    static let shared = Diagnostics()
    private let directory: URL
    private let limit: Int
    private let retained: Int
    init(directory: URL? = nil, limit: Int = 262_144, retained: Int = 3) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YunX/Diagnostics", isDirectory: true)
        self.limit = max(1024, limit)
        self.retained = max(1, min(5, retained))
    }
    func record(_ kind: Kind, code: Int? = nil, bytes: Int64? = nil) {
        do {
            try prepare()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(Event(time: Date(), kind: kind, code: code, bytes: bytes.map { max(0, $0) }))
            data.append(0x0a)
            let file = log(0)
            let current = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if current + data.count > limit {
                try? FileManager.default.removeItem(at: log(retained - 1))
                if retained > 1 {
                    for index in stride(from: retained - 2, through: 0, by: -1) where FileManager.default.fileExists(atPath: log(index).path) {
                        try FileManager.default.moveItem(at: log(index), to: log(index + 1))
                    }
                }
            }
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { /* Diagnostics must not interrupt downloads or expose a raw error. */ }
    }
    func export() throws -> URL {
        try prepare()
        var output = Data("{\"format\":\"yunx-diagnostics-v1\",\"containsRequestData\":false}\n".utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for index in stride(from: retained - 1, through: 0, by: -1) {
            guard FileManager.default.fileExists(atPath: log(index).path) else { continue }
            let data = try Data(contentsOf: log(index), options: .mappedIfSafe)
            guard data.count <= limit else { continue }
            // Re-encode the typed schema; unknown fields in a modified file never escape.
            for line in data.split(separator: 0x0a) {
                if let event = try? decoder.decode(Event.self, from: Data(line)) {
                    output.append(try encoder.encode(event)); output.append(0x0a)
                }
            }
        }
        let target = directory.appendingPathComponent("yunx-diagnostics.jsonl")
        try output.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return target
    }
    func clear() throws {
        for index in 0..<retained where FileManager.default.fileExists(atPath: log(index).path) { try FileManager.default.removeItem(at: log(index)) }
        let exported = directory.appendingPathComponent("yunx-diagnostics.jsonl")
        if FileManager.default.fileExists(atPath: exported.path) { try FileManager.default.removeItem(at: exported) }
    }
    private func log(_ index: Int) -> URL { directory.appendingPathComponent("events-\(index).jsonl") }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
}

@MainActor
struct DiagnosticsScreen: View {
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section("运行记录") {
                Text("记录启动、引擎和下载结果，仅含固定事件名、时间、数字错误码和字节数。不包含链接、文件名、账号、请求头或原始引擎日志。最多保留 3 份，每份 256 KB，另保留一份导出文件。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("生成诊断文件") {
                    busy = true; exportURL = nil; message = nil
                    Task {
                        defer { busy = false }
                        do { exportURL = try await Diagnostics.shared.export() }
                        catch { message = "无法生成诊断文件，请检查可用空间。" }
                    }
                }.disabled(busy)
                if let exportURL { ShareLink("分享诊断文件", item: exportURL) }
                Button("清除诊断记录", role: .destructive) { confirmClear = true }.disabled(busy)
                if let message { Text(message) }
            }
        }.navigationTitle("诊断")
            .confirmationDialog("清除应用诊断记录和已生成的诊断文件？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    busy = true; exportURL = nil
                    Task {
                        defer { busy = false }
                        do { try await Diagnostics.shared.clear(); message = "诊断记录已清除。" }
                        catch { message = "诊断记录未能全部清除。" }
                    }
                }
            }
    }
}

struct DownloadDiagnosticScreen: View {
    @ObservedObject var store: DownloadStore
    let id: UUID
    var body: some View {
        Form {
            if let item = store.items.first(where: { $0.id == id }) {
                LabeledContent("状态", value: item.state.title)
                LabeledContent("已接收", value: ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file))
                if item.expected > 0 { LabeledContent("响应预期", value: ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file)) }
                if let size = item.requiredSize, size > 0 { LabeledContent("平台记录大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                LabeledContent("凭证请求头", value: item.requiresHeaders == true ? "由钥匙串提供" : "无")
                LabeledContent("运行方式", value: "URLSession 前台会话")
                LabeledContent("队列并发", value: String(store.maximumConcurrent))
                if let digest = item.sha256 { Text("SHA-256: " + digest).font(.caption.monospaced()).textSelection(.enabled) }
                if let error = item.error { Text(error).foregroundStyle(.red) }
                Text("此页不显示原始链接或请求头。重启后需手动继续；直链过期时请重新解析。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else { Text("任务记录已删除。") }
        }.navigationTitle("任务诊断")
    }
}
