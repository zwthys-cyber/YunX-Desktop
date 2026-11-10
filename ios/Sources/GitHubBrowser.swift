// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Foundation
import WebKit

struct GitHubRepository: Equatable {
    let owner: String
    let name: String
    var ref: String? = nil
    var initialPath = ""
    var initialFile = false
    var refQuery: [URLQueryItem] { ref.map { [URLQueryItem(name: "ref", value: $0)] } ?? [] }
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
    var historyText: String {
        guard let ref else { return owner + "/" + name }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "github.com"
        parts.path = "/" + owner + "/" + name + (initialFile ? "/blob/" : "/tree/") + ref + (initialPath.isEmpty ? "" : "/" + initialPath)
        return parts.url?.absoluteString ?? (owner + "/" + name)
    }
}

struct GitHubInput {
    let repository: GitHubRepository
    let components: [String]
    let file: Bool
    static func parse(_ text: String) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root = try? GitHubRepository.parse(text) { return Self(repository: root, components: [], file: false) }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else { throw CloudError.message("请输入 GitHub 仓库、tree 目录或 blob 文件链接。") }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, ["tree", "blob"].contains(parts[2]), parts.count <= 20,
              parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw CloudError.message("GitHub 子路径链接无效或过长。") }
        return Self(repository: try GitHubRepository.parse(parts[0] + "/" + parts[1]), components: Array(parts.dropFirst(3)), file: parts[2] == "blob")
    }
}

struct GitHubAPIError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: return "GitHub Token 无效，请重新保存。"
        case 403, 429: return "GitHub 请求受限，请稍后重试或检查 Token 权限。"
        case 404: return "内容不存在或当前账号无访问权限。"
        default: return "GitHub 请求失败（HTTP \(status)）。"
        }
    }
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
struct GitHubRepositoryDetail: Decodable {
    struct Parent: Decodable { let full_name: String }
    let full_name: String
    let default_branch: String
    let fork: Bool
    let parent: Parent?
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
    private let credentialLookup: (@MainActor () -> String?)?
    private let unauthorized: (@MainActor (String) -> Void)?
    init(token: String = "", session: URLSession? = nil, credentialLookup: (@MainActor () -> String?)? = nil,
         unauthorized: (@MainActor (String) -> Void)? = nil) {
        self.token = token
        self.credentialLookup = credentialLookup; self.unauthorized = unauthorized
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 30
            self.session = NetworkProxy.session(configuration: config, delegate: GitHubRedirectPolicy(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }
    @MainActor static func saved(id: UUID, vault: CredentialVault, session: URLSession? = nil) -> GitHubClient {
        let token = vault.accounts.first { $0.id == id && $0.platform == "GitHub" }?.secret ?? ""
        return GitHubClient(token: token, session: session, credentialLookup: { [weak vault] in
            vault?.accounts.first { $0.id == id && $0.platform == "GitHub" }?.secret
        }, unauthorized: { [weak vault] rejected in
            guard let current = vault?.accounts.first(where: { $0.id == id && $0.platform == "GitHub" }), current.secret == rejected else { return }
            vault?.delete(id)
        })
    }
    private func authorizationToken() async throws -> String {
        try Task.checkCancellation()
        let value: String
        if let credentialLookup {
            guard let current = await credentialLookup(), !current.isEmpty else { throw CloudError.message("所选 GitHub 账号已移除，请返回账号管理重新选择。") }
            value = current
        } else { value = token }
        guard value.utf8.count <= 2048, !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
            throw CloudError.message("GitHub Token 格式无效，请重新输入。")
        }
        return value
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") async throws -> T {
        let token = try await authorizationToken()
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.github.com"; parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CloudError.message("GitHub 请求地址无效。") }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("GitHub 网络连接失败，请重试。") }
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("GitHub 响应无效。") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401, !token.isEmpty { await unauthorized?(token) }
            throw GitHubAPIError(status: http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudError.message("GitHub 数据格式无法识别。") }
    }
    func validateAccount() async throws -> String {
        guard !(try await authorizationToken()).isEmpty else { throw CloudError.message("请先保存 GitHub Token。") }
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
        let entries: [GitHubEntry] = try await get(repo.apiPath + "/contents/" + path, query: repo.refQuery)
        return entries.sorted { a, b in
            if (a.type == "dir") != (b.type == "dir") { return a.type == "dir" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    func repositoryDetail(_ repo: GitHubRepository) async throws -> GitHubRepositoryDetail {
        try await get(repo.apiPath)
    }
    func latestCommitDate(_ repo: GitHubRepository, path: String) async throws -> Date? {
        struct Commit: Decodable {
            struct Details: Decodable {
                struct Person: Decodable { let date: String? }
                let committer: Person?
            }
            let commit: Details
        }
        var query = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "per_page", value: "1")]
        if let ref = repo.ref { query.append(URLQueryItem(name: "sha", value: ref)) }
        let commits: [Commit] = try await get(repo.apiPath + "/commits", query: query)
        guard let date = commits.first?.commit.committer?.date else { return nil }
        return ISO8601DateFormatter().date(from: date)
    }
    func archiveDownload(_ repo: GitHubRepository) async throws -> CloudDownload {
        // Resolve a branch to an immutable commit before queuing. A later default
        // branch change must not silently change the archive selected by the user.
        let detail = try await repositoryDetail(repo)
        let reference = repo.ref ?? detail.default_branch
        guard !reference.isEmpty, reference.utf8.count <= 1024,
              !reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CloudError.message("GitHub 分支无效。")
        }
        struct Commit: Decodable { let sha: String }
        let commits: [Commit] = try await get(repo.apiPath + "/commits", query: [
            URLQueryItem(name: "sha", value: reference), URLQueryItem(name: "per_page", value: "1")
        ])
        guard let sha = commits.first?.sha, sha.count == 40,
              sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CloudError.message("该分支没有可下载的提交。")
        }
        let token = try await authorizationToken()
        let url = try apiURL(repo.apiPath + "/zipball/" + sha)
        return CloudDownload(url: url, filename: repo.name + "-" + String(sha.prefix(12)) + ".zip", size: 0,
                             headers: token.isEmpty ? [:] : downloadHeaders(token: token, accept: "application/vnd.github+json"))
    }
    func resolve(_ input: GitHubInput) async throws -> GitHubRepository {
        guard !input.components.isEmpty else { return input.repository }
        struct Commit: Decodable { let sha: String }
        // Branches may contain '/'. Confirm the longest valid ref, never silently use default.
        for boundary in stride(from: input.components.count, through: 1, by: -1) {
            try Task.checkCancellation()
            let candidate = input.components.prefix(boundary).joined(separator: "/")
            do {
                let commits: [Commit] = try await get(input.repository.apiPath + "/commits", query: [URLQueryItem(name: "sha", value: candidate), URLQueryItem(name: "per_page", value: "1")])
                guard !commits.isEmpty else { continue }
                var repo = input.repository
                repo.ref = candidate; repo.initialPath = input.components.dropFirst(boundary).joined(separator: "/"); repo.initialFile = input.file
                guard !input.file || !repo.initialPath.isEmpty else { throw CloudError.message("文件链接缺少文件路径。") }
                return repo
            } catch let error as GitHubAPIError where [404, 422].contains(error.status) { continue }
        }
        throw CloudError.message("无法确认链接中的分支、标签或提交，请检查访问权限，或从仓库首页手动指定分支。")
    }
    func entry(_ repo: GitHubRepository, path: String) async throws -> GitHubEntry {
        try await get(repo.apiPath + "/contents/" + path, query: repo.refQuery, accept: "application/vnd.github.object+json")
    }
    func fileDownload(_ repo: GitHubRepository, path: String) async throws -> CloudDownload {
        let file = try await entry(repo, path: path)
        guard file.type == "file", file.path == path, file.size >= 0, file.size <= 100 * 1024 * 1024 else { throw CloudError.message("仓库文件超出 Contents API 范围或不是普通文件，请使用 Releases。") }
        let token = try await authorizationToken()
        if token.isEmpty {
            guard let url = file.download_url, Self.safe(url) else { throw CloudError.message("GitHub 未返回可公开下载的文件地址，请选择有权限的 Token。") }
            return CloudDownload(url: url, filename: file.name, size: file.size, headers: [:])
        }
        let url = try apiURL(repo.apiPath + "/contents/" + file.path, query: repo.refQuery)
        return CloudDownload(url: url, filename: file.name, size: file.size, headers: downloadHeaders(token: token, accept: "application/vnd.github.raw+json"))
    }
    func releaseDownload(_ repo: GitHubRepository, asset: GitHubRelease.Asset) async throws -> CloudDownload {
        let token = try await authorizationToken()
        guard asset.id > 0, asset.size >= 0 else { throw CloudError.message("GitHub 发布附件信息无效。") }
        if token.isEmpty {
            guard Self.safe(asset.browser_download_url) else { throw CloudError.message("GitHub 发布附件地址不安全。") }
            return CloudDownload(url: asset.browser_download_url, filename: asset.name, size: asset.size, headers: [:])
        }
        let url = try apiURL(repo.apiPath + "/releases/assets/" + String(asset.id))
        return CloudDownload(url: url, filename: asset.name, size: asset.size, headers: downloadHeaders(token: token, accept: "application/octet-stream"))
    }
    private func downloadHeaders(token: String, accept: String) -> [String: String] {
        ["Authorization": "Bearer " + token, "Accept": accept, "User-Agent": "YunX-iOS"]
    }
    private func apiURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "api.github.com"; parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw CloudError.message("GitHub 下载地址无效。") }
        return url
    }
    private static func safe(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
    func readme(_ repo: GitHubRepository) async throws -> String {
        struct Document: Decodable { let content: String; let encoding: String }
        let document: Document = try await get(repo.apiPath + "/readme", query: repo.refQuery)
        guard document.encoding == "base64", let data = Data(base64Encoded: document.content, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else { throw CloudError.message("README 不是可显示的 UTF-8 文本。") }
        return text
    }
    func readmeHTML(_ repo: GitHubRepository) async throws -> String {
        let token = try await authorizationToken()
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.github.com"; parts.path = repo.apiPath + "/readme"
        parts.queryItems = repo.refQuery.isEmpty ? nil : repo.refQuery
        guard let url = parts.url else { throw CloudError.message("README 地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
        request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("README 无法加载，请检查访问权限或切换原始文本。") }
        if http.statusCode == 401, !token.isEmpty { await unauthorized?(token) }
        guard http.statusCode == 200 else { throw GitHubAPIError(status: http.statusCode) }
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
@MainActor
struct GitHubScreen: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @EnvironmentObject var library: LinkLibrary
    @ObservedObject var vault: CredentialVault
    @ObservedObject var downloads: DownloadStore
    @State private var input = "zwthys-cyber/YunX-Desktop"
    @State private var accountID: UUID?
    @State private var choseAccount = false
    @State private var owner = ""
    @State private var organization = false
    @State private var repo: GitHubRepository?
    @State private var message: String?
    @State private var opening = false
    @State private var action: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub 仓库") {
                    TextField("owner/repo 或仓库链接", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("账号", selection: Binding(get: { accountID }, set: { accountID = $0; choseAccount = true })) {
                        Text("游客").tag(nil as UUID?)
                        ForEach(vault.accounts.filter { $0.platform == "GitHub" }) { account in
                            Text(account.remark.isEmpty ? "GitHub 账号" : account.remark).tag(Optional(account.id))
                        }
                    }
                    LibraryPicker(platform: "GitHub") { input = $0 }
                    Button("打开仓库") {
                        action = Task { @MainActor in
                            opening = true; message = nil
                            defer { opening = false }
                            do {
                                let requestedInput = input, requestedAccount = accountID
                                let parsed = try GitHubInput.parse(requestedInput)
                                let client = makeClient()
                                let resolved = try await client.resolve(parsed)
                                try Task.checkCancellation()
                                guard input == requestedInput, accountID == requestedAccount else { return }
                                repo = resolved
                                library.record(platform: "GitHub", text: resolved.historyText)
                            } catch { if !Task.isCancelled { message = error.localizedDescription } }
                        }
                    }.disabled(opening)
                    if opening { ProgressView("确认链接中的分支…") }
                    if let message { Text(message).foregroundStyle(.red) }
                }
                Section("用户与组织") {
                    TextField("GitHub 用户名或组织名", text: $owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("组织账号", isOn: $organization)
                    NavigationLink("浏览仓库列表") {
                        GitHubOwnerScreen(owner: owner.trimmingCharacters(in: .whitespacesAndNewlines), organization: organization,
                            client: makeClient(), downloads: downloads)
                    }.disabled(owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("支持仓库、tree 目录和 blob 文件链接，可指定分支/标签/提交。Token 仅发送到 GitHub 官方 API；私有下载先由官方 API 鉴权，跨源跳转时移除 Token。仓库文件受 100MB Contents API 限制，目录最多显示 1000 项。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("GitHub")
                .onReceive(navigation.$githubInput.compactMap { $0 }) { value in input = value; message = nil; navigation.githubInput = nil }
                .onReceive(navigation.$githubOwner.compactMap { $0 }) { value in owner = value; organization = false; message = nil; navigation.githubOwner = nil }
                .onReceive(vault.$accounts) { accounts in
                    if let id = accountID, !accounts.contains(where: { $0.id == id && $0.platform == "GitHub" }) {
                        accountID = nil; choseAccount = true; message = "所选 GitHub 账号已移除，已切换为游客。"
                    }
                }
                .onAppear { if !choseAccount { accountID = vault.accounts.first(where: { $0.platform == "GitHub" && $0.isPrimary == true })?.id } }
                .onDisappear { action?.cancel() }
                .navigationDestination(isPresented: Binding(get: { repo != nil }, set: { if !$0 { repo = nil } })) {
                    if let repo {
                        GitHubRepositoryScreen(repo: repo, client: makeClient(), downloads: downloads)
                    }
                }
        }
    }
    @MainActor private func makeClient() -> GitHubClient {
        guard let id = accountID else { return GitHubClient() }
        return GitHubClient.saved(id: id, vault: vault)
    }
}
struct GitHubRepositoryScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    @State private var reference: String
    @State private var detail: GitHubRepositoryDetail?
    @State private var message: String?
    @State private var downloadingArchive = false
    init(repo: GitHubRepository, client: GitHubClient, downloads: DownloadStore) {
        self.repo = repo; self.client = client; self.downloads = downloads
        _reference = State(initialValue: repo.ref ?? "")
    }
    private var selected: GitHubRepository {
        var value = repo
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        value.ref = ref.isEmpty ? nil : ref
        return value
    }
    var body: some View {
        List {
            if let parent = detail?.parent { Text("Fork 自 " + parent.full_name).foregroundStyle(.secondary) }
            if let message { Text(message).foregroundStyle(.secondary) }
            TextField("分支/标签/提交（留空使用默认分支）", text: $reference).textInputAutocapitalization(.never).autocorrectionDisabled()
            if repo.initialFile {
                NavigationLink("链接中的文件") { GitHubFileScreen(repo: selected, client: client, downloads: downloads, path: repo.initialPath) }
            } else { NavigationLink("文件目录") { GitHubDirectoryScreen(repo: selected, client: client, downloads: downloads) } }
            if !repo.initialPath.isEmpty { NavigationLink("仓库根目录") { GitHubDirectoryScreen(repo: selected, client: client, downloads: downloads, path: "") } }
            NavigationLink("README") { GitHubReadmeScreen(repo: selected, client: client) }
            NavigationLink("Releases") { GitHubReleasesScreen(repo: selected, client: client, downloads: downloads) }
            Button(downloadingArchive ? "正在准备 ZIP…" : "下载所选分支 ZIP") {
                let snapshot = selected
                downloadingArchive = true
                Task { @MainActor in
                    defer { downloadingArchive = false }
                    do {
                        let plan = try await client.archiveDownload(snapshot)
                        message = downloads.add(plan.url, filename: plan.filename, headers: plan.headers, expectedMedia: "zip") ? "ZIP 已加入下载" : downloads.storageError
                    } catch { if !Task.isCancelled { message = error.localizedDescription } }
                }
            }.disabled(downloadingArchive)
            Text("ZIP 固定为准备时的提交，走 GitHub 官方接口；私有仓库使用所选账号权限。").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(repo.name)
            .task {
                do { detail = try await client.repositoryDetail(repo) }
                catch { if !Task.isCancelled { message = error.localizedDescription } }
            }
    }
}
struct GitHubDirectoryScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    var path: String? = nil
    private var effectivePath: String { path ?? repo.initialPath }
    @State private var entries: [GitHubEntry] = []
    @State private var loading = false
    @State private var message: String?
    @State private var pending = Set<String>()
    @State private var commitDates: [String: Date] = [:]
    @State private var datedCount = 0
    @State private var loadingDates = false
    @State private var datesTask: Task<Void, Never>?
    var body: some View {
        List {
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
            if !effectivePath.isEmpty {
                NavigationLink("上一级目录") { GitHubDirectoryScreen(repo: repo, client: client, downloads: downloads, path: (effectivePath as NSString).deletingLastPathComponent) }
            }
            if entries.count >= 1000 { Text("目录达到 API 1000 项上限，可能未显示全部文件。") }
            if datedCount < entries.count {
                Button(loadingDates ? "正在读取提交时间…" : "读取下一批提交时间（最多 20 项）") {
                    datesTask = Task { await loadDates() }
                }.disabled(loadingDates || loading)
                Text("每项需一次 GitHub API 请求，按需读取以节省账号限额。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                if entry.type == "dir" {
                    NavigationLink { GitHubDirectoryScreen(repo: repo, client: client, downloads: downloads, path: entry.path) } label: {
                        entryLabel(entry, symbol: "folder")
                    }
                } else if entry.type == "file" {
                    Button { Task { await download(entry) } } label: { entryLabel(entry, symbol: "arrow.down.doc") }
                        .disabled(pending.contains(entry.path))
                } else { Label(entry.name + "（不支持下载）", systemImage: "doc") }
            }
        }.navigationTitle(effectivePath.isEmpty ? "文件" : (effectivePath as NSString).lastPathComponent)
            .task(id: effectivePath + "|" + (repo.ref ?? "")) { await load() }.refreshable { await load() }
            .onDisappear { datesTask?.cancel() }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; message = nil
        defer { loading = false }
        datesTask?.cancel()
        if let datesTask { await datesTask.value }
        datesTask = nil
        do {
            entries = try await client.contents(repo, path: effectivePath)
            commitDates = [:]; datedCount = 0
        }
        catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    private func entryLabel(_ entry: GitHubEntry, symbol: String) -> some View {
        VStack(alignment: .leading) {
            Label(entry.name, systemImage: symbol)
            if let date = commitDates[entry.path] {
                Text("最后提交：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @MainActor private func loadDates() async {
        guard !loadingDates, !loading else { return }
        loadingDates = true
        defer { loadingDates = false }
        let end = min(entries.count, datedCount + 20)
        do {
            while datedCount < end {
                try Task.checkCancellation()
                let entry = entries[datedCount]
                let date = try await client.latestCommitDate(repo, path: entry.path)
                try Task.checkCancellation()
                commitDates[entry.path] = date
                datedCount += 1
            }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
    @MainActor private func download(_ entry: GitHubEntry) async {
        guard pending.insert(entry.path).inserted else { return }
        defer { pending.remove(entry.path) }
        do {
            let plan = try await client.fileDownload(repo, path: entry.path)
            let routed = try await GitHubMirrorSelector.shared.plan(plan)
            message = downloads.add(routed.url, filename: plan.filename, headers: plan.headers, expectedSize: plan.size, originFallback: routed.origin) ? "已加入下载：" + plan.filename : downloads.storageError
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}

struct GitHubFileScreen: View {
    let repo: GitHubRepository
    let client: GitHubClient
    @ObservedObject var downloads: DownloadStore
    let path: String
    @State private var entry: GitHubEntry?
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        List {
            Text(path).font(.footnote)
            if let entry { Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) }
            if let message { Text(message) }
            Button("下载文件") { Task { await download() } }.disabled(busy || entry == nil)
            if busy { ProgressView() }
        }.navigationTitle((path as NSString).lastPathComponent).task {
            do { entry = try await client.entry(repo, path: path) }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    @MainActor private func download() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let plan = try await client.fileDownload(repo, path: path)
            let routed = try await GitHubMirrorSelector.shared.plan(plan)
            message = downloads.add(routed.url, filename: plan.filename, headers: plan.headers, expectedSize: plan.size, originFallback: routed.origin) ? "已加入下载。" : downloads.storageError
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
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
        _ = NetworkProxy.configure(configuration.websiteDataStore)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard NetworkProxy.ready, context.coordinator.loaded != html else { return }
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
                            Task {
                                do {
                                    let plan = try await client.releaseDownload(repo, asset: asset)
                                    let routed = try await GitHubMirrorSelector.shared.plan(plan)
                                    message = downloads.add(routed.url, filename: plan.filename, headers: plan.headers, expectedSize: plan.size, originFallback: routed.origin) ? "已加入下载：" + asset.name : downloads.storageError
                                } catch { message = error.localizedDescription }
                            }
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
