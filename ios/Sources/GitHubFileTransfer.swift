// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct GitHubTransferChoice {
    let native: Bool
    let connections: Int
    static func current() -> Self {
        let defaults = UserDefaults.standard, value = UserDefaults.standard.integer(forKey: "githubHTTPConnections")
        return Self(native: defaults.bool(forKey: "githubNativeHTTP"), connections: (1...512).contains(value) ? value : 4)
    }
}

struct GitHubTransferSettings: View {
    @AppStorage("githubNativeHTTP") private var native = false
    @AppStorage("githubHTTPConnections") private var connections = 4
    var body: some View {
        Section("GitHub 文件传输") {
            Toggle("原生多连接（前台、官方源）", isOn: $native)
            if native { Stepper("GitHub 每文件：\(connections) 个连接", value: $connections, in: 1...512) }
            Text(native ? "使用原生 HTTP 限速与代理，账号请求头经钥匙串提供。任务在「下载 → 原生引擎任务」查看；此模式不走下载镜像。m3u8 原文请使用系统模式保存。" : "使用系统会话，保留现有镜像与后台策略；带账号请求头的文件使用前台会话。")
                .font(.footnote).foregroundStyle(.secondary)
        }.onAppear { if !(1...512).contains(connections) { connections = 4 } }
    }
}

@MainActor
struct GitHubTransferButton<Label: View>: View {
    let operation: (GitHubTransferChoice) -> Void
    let label: () -> Label
    @State private var pending: GitHubTransferChoice?
    init(_ title: String, operation: @escaping (GitHubTransferChoice) -> Void) where Label == Text {
        self.operation = operation; label = { Text(title) }
    }
    init(operation: @escaping (GitHubTransferChoice) -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.operation = operation; self.label = label
    }
    var body: some View {
        Button {
            let choice = GitHubTransferChoice.current()
            if choice.native && choice.connections > 32 { pending = choice }
            else { operation(choice) }
        } label: { label() }
        .confirmationDialog("使用 \(pending?.connections ?? 4) 个原生连接？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("确认下载") { if let pending { operation(pending) }; pending = nil }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text("超过 32 个连接可能触发 GitHub/CDN 限流、增加耗电和内存占用。将从官方 HTTPS 地址下载，任务在原生引擎队列查看。") }
    }
}

@MainActor
enum GitHubFileTransfer {
    static func enqueue(_ plan: CloudDownload, choice: GitHubTransferChoice, store: DownloadStore, zip: Bool = false, mirrors: Bool = true) async throws -> String {
        if choice.native {
            if plan.url.pathExtension.lowercased() == "m3u8" || (plan.filename as NSString).pathExtension.lowercased() == "m3u8" {
                throw CloudError.message("请切换系统模式，保存此播放列表原文。")
            }
            let request = try NativeHTTPSRequest(text: plan.url.absoluteString, filename: plan.filename,
                connections: choice.connections, headers: plan.headers, accountHeaders: true,
                expectedSize: plan.size, expectedMedia: zip ? "zip" : nil)
            try await NativeEngine.shared.createHTTPS(request)
            return "已加入原生 GitHub 任务，请到「下载 → 原生引擎任务」查看。"
        }
        var url = plan.url
        var origin: URL?
        if mirrors {
            let routed = try await GitHubMirrorSelector.shared.plan(plan)
            url = routed.url; origin = routed.origin
        }
        guard store.add(url, filename: plan.filename, headers: plan.headers, expectedSize: plan.size,
            expectedMedia: zip ? "zip" : nil, originFallback: origin) else {
            throw CloudError.message(store.storageError ?? "创建 GitHub 下载失败。")
        }
        return "已加入下载：" + plan.filename
    }
}
