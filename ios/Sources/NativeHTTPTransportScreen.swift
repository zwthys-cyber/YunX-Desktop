// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct NativeHTTPTransportPreference {
    let http2: Bool
    let bufferKiB: Int
    init(http2: Bool, bufferKiB: Int) throws {
        guard (16...4096).contains(bufferKiB) else { throw CloudError.message("读缓冲需为 16–4096 KiB 的整数。") }
        self.http2 = http2; self.bufferKiB = bufferKiB
    }
    static func load() throws -> Self {
        let defaults = UserDefaults.standard
        let buffer = defaults.object(forKey: "engineHTTPBufferKiB") == nil ? 64 : defaults.integer(forKey: "engineHTTPBufferKiB")
        return try Self(http2: defaults.bool(forKey: "engineHTTP2"), bufferKiB: buffer)
    }
}

struct NativeHTTPSlowPreference {
    let enabled: Bool
    let minimumKiB: Int
    let seconds: Int
    init(enabled: Bool, minimumKiB: Int, seconds: Int) throws {
        guard (4...10240).contains(minimumKiB), (5...600).contains(seconds) else {
            throw CloudError.message("慢连接阈值需为 4–10240 KiB/s，判定时长为 5–600 秒。")
        }
        self.enabled = enabled; self.minimumKiB = minimumKiB; self.seconds = seconds
    }
    static func load() throws -> Self {
        let defaults = UserDefaults.standard
        return try Self(enabled: defaults.bool(forKey: "engineHTTPSlowEnabled"),
            minimumKiB: defaults.object(forKey: "engineHTTPSlowMinimumKiB") == nil ? 12 : defaults.integer(forKey: "engineHTTPSlowMinimumKiB"),
            seconds: defaults.object(forKey: "engineHTTPSlowSeconds") == nil ? 15 : defaults.integer(forKey: "engineHTTPSlowSeconds"))
    }
}

@MainActor
struct NativeHTTPTransportScreen: View {
    @State private var http2 = false
    @State private var buffer = "64"
    @State private var slowEnabled = false
    @State private var slowMinimum = "12"
    @State private var slowSeconds = "15"
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("原生 HTTP 文件传输") {
                Toggle("允许 HTTP/2", isOn: $http2)
                TextField("每个连接读缓冲（KiB）", text: $buffer).keyboardType(.numberPad)
                Text("默认 HTTP/1.1、64 KiB；缓冲可设为 16–4096 KiB。HTTP/2 开启后由服务器协商，关闭时原生和浏览器回退连接均使用 HTTP/1.1。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("只影响原生 HTTP 文件下载。HTTP/2 设置影响之后建立的连接；修改读缓冲后，请暂停并继续已有下载。单任务连接读缓冲合计上限为 64 MiB，连接数较多时自动缩小每连接缓冲。限速启用时每次读取还受速率预算约束。")
                Text("普通系统下载会话、HLS 和 P2P 使用各自的传输方式，不应用这些设置。")
            }.font(.footnote).foregroundStyle(.secondary)
            Section("慢连接重连") {
                Toggle("启用低速重连", isOn: $slowEnabled)
                TextField("最低速率（KiB/s）", text: $slowMinimum).keyboardType(.numberPad)
                TextField("判定时长（秒）", text: $slowSeconds).keyboardType(.numberPad)
                Text("默认关闭，启用后默认 12 KiB/s、15 秒。只对支持 Range 且具备可靠 If-Range 校验标识的文件生效；保留已写入片段再重连。原生 HTTP 限速启用时不判定低速，新连接应用设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存传输设置") { Task { await apply() } }.disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote) }
            }
        }.navigationTitle("原生 HTTP 传输")
            .onAppear {
                do {
                    let value = try NativeHTTPTransportPreference.load(); http2 = value.http2; buffer = String(value.bufferKiB)
                    let slow = try NativeHTTPSlowPreference.load(); slowEnabled = slow.enabled; slowMinimum = String(slow.minimumKiB); slowSeconds = String(slow.seconds)
                }
                catch { message = error.localizedDescription }
            }
    }
    private func apply() async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            guard let amount = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CloudError.message("请输入整数 KiB。") }
            let value = try NativeHTTPTransportPreference(http2: http2, bufferKiB: amount)
            guard let minimum = Int(slowMinimum.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let seconds = Int(slowSeconds.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CloudError.message("慢连接速率和时长请输入整数。") }
            let slow = try NativeHTTPSlowPreference(enabled: slowEnabled, minimumKiB: minimum, seconds: seconds)
            try await NativeEngine.shared.setHTTPTransport(value)
            try await NativeEngine.shared.setHTTPSlowPreference(slow)
            message = "设置已保存；已有下载请暂停后继续，以应用新读缓冲。"
        } catch { message = error.localizedDescription }
    }
}
