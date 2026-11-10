// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct CloudRoute: Identifiable {
    let id = UUID()
    let provider: CloudProvider
    let account: SavedCredential?
    let share: CloudShare?
}

@MainActor
struct CloudHomeScreen: View {
    @EnvironmentObject var library: LinkLibrary
    @ObservedObject var vault: CredentialVault
    @ObservedObject var downloads: DownloadStore
    @State private var provider: CloudProvider = .quark
    @State private var accountID: UUID?
    @State private var input = ""
    @State private var passcode = ""
    @State private var error: String?
    @State private var route: CloudRoute?

    private var accounts: [SavedCredential] { vault.accounts.filter { $0.platform == provider.rawValue } }
    private var selected: SavedCredential? { accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("平台与账号") {
                    Picker("平台", selection: $provider) {
                        ForEach(CloudProvider.allCases) { Text($0.rawValue).tag($0) }
                    }.onChange(of: provider) { _, _ in accountID = nil }
                    Picker("账号", selection: $accountID) {
                        Text("游客").tag(Optional<UUID>.none)
                        ForEach(accounts) { account in
                            Text(account.remark.isEmpty ? "已保存账号" : account.remark)
                                .tag(Optional(account.id))
                        }
                    }
                    Text("可到「账号」网页登录或添加 Cookie；游客受平台文件大小和风控限制。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("解析分享") {
                    TextField("粘贴分享链接或整段文案", text: $input, axis: .vertical)
                        .lineLimit(3...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("提取码（可自动识别，手填优先）", text: $passcode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    LibraryPicker(platform: provider.rawValue) { input = $0; passcode = "" }
                    Button("解析并浏览") {
                        do {
                            let share = try CloudShare.parse(input, override: passcode)
                            guard share.provider == provider else {
                                error = "这是\(share.provider.rawValue)链接，请先切换平台再解析。"
                                return
                            }
                            error = nil
                            var canonical = URLComponents()
                            canonical.scheme = "https"; canonical.host = share.provider.webHost
                            canonical.path = "/s/" + share.shareID
                            if !share.passcode.isEmpty { canonical.queryItems = [URLQueryItem(name: "pwd", value: share.passcode)] }
                            if let url = canonical.url { library.record(platform: provider.rawValue, text: url.absoluteString) }
                            route = CloudRoute(provider: provider, account: selected, share: share)
                        } catch { self.error = error.localizedDescription }
                    }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("个人网盘") {
                    Button("浏览我的文件") {
                        route = CloudRoute(provider: provider, account: selected, share: nil)
                    }.disabled(selected == nil)
                }
                if let error { Section("提示") { Text(error).foregroundStyle(.red) } }
                Section {
                    Text("当前接入夸克和 UC 的目录与单文件免转存取链。支持当前文件夹递归批量下载（最多 500 文件/100 目录）；转存管理及其他平台仍在移植。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("网盘")
                .sheet(item: $route) { item in
                    CloudBrowserScreen(route: item, vault: vault, downloads: downloads)
                }
        }
    }
}

@MainActor
final class CloudBrowserModel: ObservableObject {
    struct Folder { let id: String; let name: String }
    @Published private(set) var files: [CloudFile] = []
    @Published private(set) var folders = [Folder(id: "0", name: "根目录")]
    @Published private(set) var busy = false
    @Published private(set) var canLoadMore = false
    @Published var message: String?
    @Published var failure: String?
    private var page = 1
    private let client: CloudClient
    private let share: CloudShare?
    private let downloads: DownloadStore

    init(route: CloudRoute, vault: CredentialVault, downloads: DownloadStore) {
        share = route.share
        self.downloads = downloads
        client = CloudClient(provider: route.provider, cookie: route.account?.secret ?? "",
                             cookieChanged: { [weak vault] new in
            if let id = route.account?.id { vault?.updateSecret(id, secret: new) }
        })
    }

    func reload() async { await load(path: folders, nextPage: 1) }
    func open(_ folder: CloudFile) async {
        guard folder.isDirectory else { return }
        await load(path: folders + [Folder(id: folder.id, name: folder.name)], nextPage: 1)
    }
    func back() async {
        guard folders.count > 1 else { return }
        await load(path: Array(folders.dropLast()), nextPage: 1)
    }
    func more() async { await load(path: folders, nextPage: page + 1) }

    private func load(path: [Folder], nextPage: Int) async {
        guard !busy, let folder = path.last else { return }
        guard nextPage <= 200 else { failure = "目录分页已达安全上限。"; canLoadMore = false; return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let batch = try await client.list(share: share, parentID: folder.id, page: nextPage)
            try Task.checkCancellation()
            var known = nextPage == 1 ? Set<String>() : Set(files.map(\.id))
            let fresh = batch.filter { known.insert($0.id).inserted }
            files = nextPage == 1 ? fresh : files + fresh
            folders = path
            page = nextPage
            canLoadMore = batch.count >= 50 && !fresh.isEmpty
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    func downloadCurrentFolder() async {
        guard !busy, let folder = folders.last else { return }
        busy = true; failure = nil; message = "正在枚举文件夹…"
        defer { busy = false }
        var added = 0
        var failed = 0
        do {
            let batch = try await CloudFolderCollector().collect(rootID: folder.id) { parent, page in
                try await self.client.list(share: self.share, parentID: parent, page: page)
            }
            for item in batch {
                try Task.checkCancellation()
                do {
                    let result = try await client.download(file: item.file, share: share)
                    try Task.checkCancellation()
                    // Keep the download store's flat layout while retaining the folder names in the filename.
                    let name = (item.relativeFolders + [result.filename]).joined(separator: "_")
                    if downloads.add(result.url, filename: name, headers: result.headers, expectedSize: result.size) {
                        added += 1
                    } else { failed += 1 }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
                message = "已加入 \(added) 个，失败 \(failed) 个（共 \(batch.count) 个）"
            }
            message = batch.isEmpty ? "文件夹没有可下载的文件。" : "批量处理结束：已加入 \(added) 个，失败 \(failed) 个。"
        } catch is CancellationError {
            message = "已取消后续添加；已加入 \(added) 个任务，可在下载页暂停。"
        } catch { message = nil; failure = error.localizedDescription }
    }

    func download(_ file: CloudFile) async {
        guard !busy else { return }
        busy = true
        failure = nil
        message = nil
        defer { busy = false }
        do {
            let result = try await client.download(file: file, share: share)
            try Task.checkCancellation()
            if downloads.add(result.url, filename: result.filename, headers: result.headers, expectedSize: result.size) {
                message = "已加入下载：\(file.name)，请到「下载」查看。"
            } else { failure = downloads.storageError ?? "创建下载任务失败。" }
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

@MainActor
struct CloudBrowserScreen: View {
    let route: CloudRoute
    @StateObject private var model: CloudBrowserModel
    @State private var action: Task<Void, Never>?
    @State private var confirmBatch = false
    @Environment(\.dismiss) private var dismiss

    init(route: CloudRoute, vault: CredentialVault, downloads: DownloadStore) {
        self.route = route
        _model = StateObject(wrappedValue: CloudBrowserModel(route: route, vault: vault, downloads: downloads))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.folders.map(\.name).joined(separator: " / "))
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.folders.count > 1 {
                        Button("返回上级") { action = Task { await model.back() } }.disabled(model.busy)
                    }
                    Button("下载此目录（含子目录）") { confirmBatch = true }.disabled(model.busy)
                    if model.busy {
                        ProgressView("正在请求平台…")
                        Button("取消后续操作") { action?.cancel() }
                    }
                    if let failure = model.failure { Text(failure).foregroundStyle(.red) }
                    if let message = model.message { Text(message).foregroundStyle(.green) }
                }
                Section("文件") {
                    if model.files.isEmpty && !model.busy && model.failure == nil {
                        ContentUnavailableView("文件夹为空", systemImage: "folder")
                    }
                    ForEach(model.files) { file in
                        HStack {
                            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(file.isDirectory ? Color.orange : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(file.name).lineLimit(2)
                                if !file.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if file.isDirectory {
                                Button("进入") { action = Task { await model.open(file) } }
                                    .buttonStyle(.bordered).disabled(model.busy)
                            } else {
                                Button("下载") { action = Task { await model.download(file) } }
                                    .buttonStyle(.bordered).disabled(model.busy)
                            }
                        }
                    }
                    if model.canLoadMore {
                        Button("加载更多") { action = Task { await model.more() } }.disabled(model.busy)
                    }
                    if model.failure != nil && model.files.isEmpty {
                        Button("重试") { action = Task { await model.reload() } }.disabled(model.busy)
                    }
                }
            }
            .navigationTitle(route.share == nil ? "\(route.provider.rawValue)网盘" : "\(route.provider.rawValue)分享")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await model.reload() }
            .refreshable { await model.reload() }
            .onDisappear { action?.cancel() }
            .confirmationDialog("将递归加入当前目录下的文件，最多 500 个文件、100 个目录。子目录名称合并到文件名，不创建目录树。", isPresented: $confirmBatch, titleVisibility: .visible) {
                Button("开始批量下载") { action = Task { await model.downloadCurrentFolder() } }
            }
        }
    }
}
