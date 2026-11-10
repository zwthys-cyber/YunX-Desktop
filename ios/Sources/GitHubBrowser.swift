// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Foundation
import WebKit

struct GitHubRepository: Equatable {
    let owner: String
    let name: String
    static func parse(_ input: String) throws -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces: [String]
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil else { throw CloudError.message("请输入 GitHub HTTPS 仓库链接或 owner/repo。") }
            pieces = url.path.split(separator: "/").map(String.init)
        } else { pieces = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        guard pieces.count == 2 else { throw CloudError.message("请输入仓库首页链接或 owner/repo。") }
        let name = pieces[1].hasSuffix(".git") ? String(pieces[1].dropLast(4)) : pieces[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [pieces[0], name].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw CloudError.message("仓库名称无效。")
        }
        return Self(owner: pieces[0], name: name)
    }
    var apiPath: String { "/repos/\(owner)/\(name)" }
}
struct GitHubRepositorySummary: Decodable, Identifiable {
    let id: Int64
    let full_name: String
    let description: String?
    let stargazers_count: Int
}
struct GitHubEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let type: String
    let size: Int64
    let download_url: URL?
    var id: String { path }
}
struct GitHubRelease: Decodable, Identifiable {
    struct Asset: Decodable, Identifiable {
        let id: Int64
        let name: String
        let size: Int64
        let browser_download_url: URL
    }
    let id: Int64
    let tag_name: String
    let name: String?
    let body: String?
    let assets: [Asset]
}
final class GitHubClient {
    private let session: URLSession
    private let token: String
    init(token: String = "", session: URLSession? = nil) {
        self.token = token
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.github.com"; parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CloudError.message("GitHub 请求地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("GitHub 网络连接失败，请重试。") }
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("GitHub 响应无效。") }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401: throw CloudError.message("GitHub Token 无效，请重新保存。")
            case 403, 429: throw CloudError.message("GitHub 请求受限，请稍后重试或检查 Token 权限。")
            case 404: throw CloudError.message("内容不存在或当前账号无访问权限。")
            default: throw CloudError.message("GitHub 请求失败（HTTP \(http.statusCode)）。")
            }
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudError.message("GitHub 数据格式无法识别。") }
    }
    func validateAccount() async throws -> String {
        guard !token.isEmpty else { throw CloudError.message("请先保存 GitHub Token。") }
        struct Profile: Decodable { let login: String }
        let profile: Profile = try await get("/user")
        guard !profile.login.isEmpty else { throw CloudError.message("GitHub 账号信息为空。") }
        return profile.login
    }
    func repositories(owner: String, organization: Bool, page: Int) async throws -> [GitHubRepositorySummary] {
        // Reuse repository input validation so owner cannot inject API path segments.
        let parsed = try GitHubRepository.parse(owner + "/repository")
        return try await get("/" + (organization ? "orgs" : "users") + "/" + parsed.owner + "/repos", query: [
            URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "page", value: String(page))
        ])
    }
    func contents(_ repo: GitHubRepository, path: String = "") async throws -> [GitHubEntry] {
        let entries: [GitHubEntry] = try await get(repo.apiPath + "/contents/" + path)
        return entries.sorted { a, b in
            if (a.type == "dir") != (b.type == "dir") { return a.type == "dir" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    func readme(_ repo: GitHubRepository) async throws -> String {
        struct Document: Decodable { let content: String; let encoding: String }
        let document: Document = try await get(repo.apiPath + "/readme")
        guard document.encoding == "base64", let data = Data(base64Encoded: document.content, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else { throw CloudError.message("README 不是可显示的 UTF-8 文本。") }
        return text
    }
    func readmeHTML(_ repo: GitHubRepository) async throws -> String {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.github.com"; parts.path = repo.apiPath + "/readme"
        guard let url = parts.url else { throw CloudError.message("README 地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
        request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.message("README 无法加载，请检查访问权限或切换原始文本。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw CloudError.message("README 超过 2MB 显示上限。") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CloudError.message("README 文本编码不受支持。") }
        return text
    }
    func releases(_ repo: GitHubRepository, page: Int) async throws -> [GitHubRelease] {
        try await get(repo.apiPath + "/releases", query: [URLQueryItem(name: "per_page", value: "20"), URLQueryItem(name: "page", value: String(page))])
    }
}
struct GitHubScreen: View {
    @EnvironmentObject var library: LinkLibrary
    @ObservedObject var vault: CredentialVault
    @ObservedObject var downloads: DownloadStore
    @State private var input = "zwthys-cyber/YunX-Desktop"
    @State private var accountID: UUID?
    @State private var owner = ""
    @State private var organization = false
    @State private var repo: GitHubRepository?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub 仓库") {
                    TextField("owner/repo 或仓库链接", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("账号", selection: $accountID) {
                        Text("游客").tag(nil as UUID?)
                        ForEach(vault.accounts.filter { $0.platform == "GitHub" }) { account in
                            Text(account.remark.isEmpty ? "GitHub 账号" : account.remark).tag(Optional(account.id))
                        }
                    }
                    LibraryPicker(platform: "GitHub") { input = $0 }
                    Button("打开仓库") {
                        do {
                            let parsed = try GitHubRepository.parse(input)
                            repo = parsed; message = nil
                            library.record(platform: "GitHub", text: parsed.owner + "/" + parsed.name)
                        }
                        catch { message = error.localizedDescription }
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                }
                Section("用户与组织") {
                    TextField("GitHub 用户名或组织名", text: $owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("组织账号", isOn: $organization)
                    NavigationLink("浏览仓库列表") {
                        GitHubOwnerScreen(owner: owner.trimmingCharacters(in: .whitespacesAndNewlines), organization: organization,
                            client: GitHubClient(token: vault.accounts.first { $0.id == accountID && $0.platform == "GitHub" }?.secret ?? ""), downloads: downloads)
                    }.disabled(owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("在账号页保存 GitHub Token 可提高 API 限额或浏览授权仓库。当前下载仅支持公开文件，私有文件不会携带 Token 下载。目录最多显示 1000 项。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("GitHub")
                .onAppear { if accountID == nil { accountID = vault.accounts.first(where: { $0.platform == "GitHub" && $0.isPrimary == true })?.id } }
                .navigationDestination(isPresented: Binding(get: { repo != nil }, set: { if !$0 { repo = nil } })) {
                    if let repo {
                        GitHubRepositoryScreen(repo: repo, client: GitHubClient(token: vault.accounts.first { $0.id == accountID && $0.platform == "GitHub" }?.secret ?? ""), downloads: downloads)
                    }
                }
        }
    }
}
struct GitHubRepositoryScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    var body: some View {
        List {
            NavigationLink("文件目录") { GitHubDirectoryScreen(repo: repo, client: client, downloads: downloads) }
            NavigationLink("README") { GitHubReadmeScreen(repo: repo, client: client) }
            NavigationLink("Releases") { GitHubReleasesScreen(repo: repo, client: client, downloads: downloads) }
        }.navigationTitle(repo.name)
    }
}
struct GitHubDirectoryScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    var path = ""
    @State private var entries: [GitHubEntry] = []
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        List {
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
            if entries.count >= 1000 { Text("目录达到 API 1000 项上限，可能未显示全部文件。") }
            ForEach(entries) { entry in
                if entry.type == "dir" {
                    NavigationLink { GitHubDirectoryScreen(repo: repo, client: client, downloads: downloads, path: entry.path) } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                } else if entry.type == "file", let url = entry.download_url {
                    Button {
                        message = downloads.add(url, filename: entry.name, expectedSize: entry.size) ? "已加入下载：" + entry.name : downloads.storageError
                    } label: { Label(entry.name, systemImage: "arrow.down.doc") }
                } else { Label(entry.name + "（不支持下载）", systemImage: "doc") }
            }
        }.navigationTitle(path.isEmpty ? "文件" : (path as NSString).lastPathComponent)
            .task { await load() }.refreshable { await load() }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; message = nil
        defer { loading = false }
        do { entries = try await client.contents(repo, path: path) }
        catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}
struct GitHubReadmeScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @State private var text = ""
    @State private var message: String?
    @State private var loading = true
    @State private var formatted = true
    var body: some View {
        VStack {
            Toggle("排版显示", isOn: $formatted).padding(.horizontal)
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary).padding() }
            if formatted {
                GitHubMarkdownView(html: text, baseURL: URL(string: "https://github.com/" + repo.owner + "/" + repo.name + "/")!)
            } else {
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            }
        }.navigationTitle("README").task(id: formatted) {
            loading = true; message = nil; text = ""
            defer { loading = false }
            do {
                if formatted { text = try await client.readmeHTML(repo) }
                else { text = try await client.readme(repo) }
            }
            catch { if !Task.isCancelled { message = "README 加载失败，请检查网络、访问权限或切换显示模式。" } }
        }
    }
}

struct GitHubMarkdownView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let document = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:light dark}body{font:16px -apple-system;line-height:1.6;padding:12px;overflow-wrap:anywhere}img{max-width:100%;height:auto}pre{overflow:auto;padding:12px;background:rgba(128,128,128,.12)}code{font-family:ui-monospace,monospace}table{border-collapse:collapse;display:block;overflow:auto}td,th{border:1px solid #888;padding:6px}blockquote{border-left:3px solid #888;margin-left:0;padding-left:12px}a{color:#4285f4}</style></head><body>\(html)</body></html>
        """
        view.loadHTMLString(document, baseURL: baseURL)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

struct GitHubReleasesScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    @State private var releases: [GitHubRelease] = []
    @State private var page = 1
    @State private var more = true
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.secondary) }
            ForEach(releases) { release in
                Section(release.name ?? release.tag_name) {
                    Text(release.tag_name).font(.caption)
                    if let body = release.body { Text(body).textSelection(.enabled) }
                    ForEach(release.assets) { asset in
                        Button {
                            message = downloads.add(asset.browser_download_url, filename: asset.name, expectedSize: asset.size) ? "已加入下载：" + asset.name : downloads.storageError
                        } label: { Label(asset.name, systemImage: "arrow.down.circle") }
                    }
                }
            }
            if loading { ProgressView() }
            if more { Button("加载更多") { Task { await load() } }.disabled(loading) }
            if !loading && !more && releases.isEmpty { Text("暂无发布版本") }
        }.navigationTitle("Releases").task { if releases.isEmpty { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; message = nil
        defer { loading = false }
        do {
            let next = try await client.releases(repo, page: page)
            let known = Set(releases.map(\.id))
            releases.append(contentsOf: next.filter { !known.contains($0.id) })
            more = next.count == 20; page += 1
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}

private final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GitHubOwnerScreen: View {
    let owner: String
    let organization: Bool
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    @State private var repositories: [GitHubRepositorySummary] = []
    @State private var page = 1
    @State private var more = true
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.red) }
            ForEach(repositories) { item in
                if let repo = try? GitHubRepository.parse(item.full_name) {
                    NavigationLink {
                        GitHubRepositoryScreen(repo: repo, client: client, downloads: downloads)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.full_name)
                            if let description = item.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                            Label(String(item.stargazers_count), systemImage: "star").font(.caption)
                        }
                    }
                }
            }
            if loading { ProgressView() }
            if more { Button("加载更多") { Task { await load() } }.disabled(loading) }
            if !loading && !more && repositories.isEmpty { Text("暂无可访问的仓库") }
        }.navigationTitle(owner).task { if repositories.isEmpty { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; message = nil
        defer { loading = false }
        do {
            let next = try await client.repositories(owner: owner, organization: organization, page: page)
            let known = Set(repositories.map(\.id))
            repositories.append(contentsOf: next.filter { !known.contains($0.id) })
            page += 1; more = next.count == 30
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}
