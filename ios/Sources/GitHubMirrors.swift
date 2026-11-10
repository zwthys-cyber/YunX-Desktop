// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct GitHubMirrorPlan {
    let url: URL
    let origin: URL?
}
enum GitHubMirrorPolicy {
    static let presets = ["https://v4.gh-proxy.org/", "https://v6.gh-proxy.org/", "https://gh-proxy.org/", "https://cdn.gh-proxy.org/", "https://axisnow.gh-proxy.org/"]
    static func publicOrigin(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        let host = url.host?.lowercased()
        return host == "raw.githubusercontent.com" || (host == "github.com" && url.path.contains("/releases/download/"))
    }
    static func prefix(_ raw: String) throws -> String {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil else { throw CloudError.message("镜像前缀必须是无认证、查询和自定义端口的 HTTPS 地址。") }
        return url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
    }
    static func plan(_ download: CloudDownload, prefix: String?) throws -> GitHubMirrorPlan {
        guard download.headers.isEmpty, publicOrigin(download.url), let prefix else { return GitHubMirrorPlan(url: download.url, origin: nil) }
        let value = try Self.prefix(prefix)
        guard let url = URL(string: value + download.url.absoluteString) else { throw CloudError.message("镜像地址无效。") }
        return GitHubMirrorPlan(url: url, origin: download.url)
    }
}

actor GitHubMirrorSelector {
    static let shared = GitHubMirrorSelector()
    private var cached: (Date, String?)?
    private var running: Task<String?, Never>?
    func plan(_ download: CloudDownload) async throws -> GitHubMirrorPlan {
        let mode = UserDefaults.standard.string(forKey: "githubMirrorMode") ?? "direct"
        guard download.headers.isEmpty, GitHubMirrorPolicy.publicOrigin(download.url), mode != "direct" else { return try GitHubMirrorPolicy.plan(download, prefix: nil) }
        let prefix: String?
        if mode == "auto" { prefix = await fastest() }
        else if mode == "custom" { prefix = UserDefaults.standard.string(forKey: "githubMirrorCustom") }
        else { prefix = GitHubMirrorPolicy.presets.contains(mode) ? mode : nil }
        guard (UserDefaults.standard.string(forKey: "githubMirrorMode") ?? "direct") == mode else { return try GitHubMirrorPolicy.plan(download, prefix: nil) }
        return try GitHubMirrorPolicy.plan(download, prefix: prefix)
    }
    func fastest(force: Bool = false) async -> String? {
        if !force, let cached, Date().timeIntervalSince(cached.0) < 21600 { return cached.1 }
        if let running { return await running.value }
        let task = Task {
            await withTaskGroup(of: (String, Double)?.self) { group -> String? in
                for prefix in GitHubMirrorPolicy.presets {
                    group.addTask { await Self.probe(prefix) }
                }
                var best: (String, Double)?
                for await result in group { if let result, best == nil || result.1 > best!.1 { best = result } }
                return best?.0
            }
        }
        running = task
        let prefix = await task.value
        cached = (Date(), prefix); running = nil
        return prefix
    }
    private static func probe(_ prefix: String) async -> (String, Double)? {
        let sample = "https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip"
        guard let url = URL(string: prefix + sample) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
        let session = NetworkProxy.session(configuration: config, delegate: nil, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                  http.url?.scheme == "https", http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-65535/") == true else { return nil }
            var count = 0
            for try await _ in bytes { count += 1; if count >= 65536 { break } }
            guard count == 65536 else { return nil }
            return (prefix, Double(count) / max(0.001, Date().timeIntervalSince(start)))
        } catch { return nil }
    }
}

struct GitHubMirrorScreen: View {
    @AppStorage("githubMirrorMode") private var mode = "direct"
    @AppStorage("githubMirrorCustom") private var custom = ""
    @State private var draft = ""
    @State private var testing = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Picker("下载路由", selection: $mode) {
                    Text("官方直连").tag("direct")
                    Text("自动测速").tag("auto")
                    ForEach(GitHubMirrorPolicy.presets, id: \.self) { Text($0).tag($0) }
                    Text("自定义 HTTPS 镜像").tag("custom")
                }
                if mode == "custom" {
                    TextField("https://mirror.example/", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存自定义前缀") {
                        do { custom = try GitHubMirrorPolicy.prefix(draft); message = "已保存。" } catch { message = error.localizedDescription }
                    }
                }
                Button("测试内置镜像（5 个 64 KB 样本）") {
                    testing = true
                    Task {
                        let best = await GitHubMirrorSelector.shared.fastest(force: true)
                        message = best.map { "本轮最快：" + $0 } ?? "没有可用镜像，将使用官方直连。"
                        testing = false
                    }
                }.disabled(testing || mode == "direct")
                if testing { ProgressView() }
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("启用镜像即允许相应第三方接收公开 GitHub 下载地址。测速使用固定公开样本，有效期 6 小时。带 Token、私有下载和应用更新始终使用官方接口。镜像失败回退官方一次，不复用镜像的断点数据；镜像返回内容仍需您信任其运营者。")
            }
        }.navigationTitle("GitHub 下载镜像").onAppear { draft = custom }
    }
}
