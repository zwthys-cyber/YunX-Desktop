// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct CloudRoute: Identifiable {
    let id = UUID()
    let provider: CloudProvider
    let account: SavedCredential?
    let share: CloudShare?
    var initialFolders: [CloudBrowserModel.Folder]? = nil
}

enum CloudAccountSelection {
    static func automatic(_ accounts: [SavedCredential], provider: CloudProvider) -> SavedCredential? {
        let available = accounts.filter { $0.platform == provider.rawValue && !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let primary = available.filter { $0.isPrimary == true }
        if primary.count == 1 { return primary.first }
        return primary.isEmpty && available.count == 1 ? available.first : nil
    }
}

@MainActor
struct CloudHomeScreen: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @EnvironmentObject var library: LinkLibrary
    @ObservedObject var vault: CredentialVault
    @ObservedObject var downloads: DownloadStore
    @State private var provider: CloudProvider = .quark
    @State private var accountID: UUID?
    @State private var choseAccount = false
    @State private var input = ""
    @State private var passcode = ""
    @State private var error: String?
    @State private var route: CloudRoute?
    @State private var confirmingCommand = false
    @State private var resolvingCommand = false
    @State private var pendingCommand = ""
    @State private var pendingPasscode = ""
    @State private var commandTask: Task<Void, Never>?

    private var accounts: [SavedCredential] { vault.accounts.filter { $0.platform == provider.rawValue } }
    private var selected: SavedCredential? { accounts.first { $0.id == accountID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("平台与账号") {
                    Picker("平台", selection: $provider) {
                        ForEach(CloudProvider.allCases) { Text($0.rawValue).tag($0) }
                    }.onChange(of: provider) { _, _ in choseAccount = false; accountID = CloudAccountSelection.automatic(vault.accounts, provider: provider)?.id }
                    Picker("账号", selection: Binding(get: { accountID }, set: { accountID = $0; choseAccount = true })) {
                        Text("游客").tag(Optional<UUID>.none)
                        ForEach(accounts) { account in
                            Text(account.remark.isEmpty ? "已保存账号" : account.remark)
                                .tag(Optional(account.id))
                        }
                    }
                    Text("可到「我的 → 账号管理」登录或添加凭证；123 使用 JWT，游客仅浏览分享，取链需要登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("解析分享") {
                    TextField("粘贴分享链接或整段文案", text: $input, axis: .vertical)
                        .lineLimit(3...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("提取码（可自动识别，手填优先）", text: $passcode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    LibraryPicker(platform: provider.rawValue) { input = $0; passcode = "" }
                    Button("解析并浏览") {
                        if let share = try? CloudShare.parse(input, override: passcode) { open(share) }
                        else if CloudCommandClient.candidate(input) {
                            pendingCommand = input; pendingPasscode = passcode; confirmingCommand = true
                        } else { error = "未识别到分享链接或中文口令。" }
                    }.disabled(resolvingCommand || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if resolvingCommand {
                        ProgressView("正在解析口令")
                        Button("取消口令解析") { commandTask?.cancel() }
                    }
                }
                Section("个人网盘") {
                    Button("浏览我的文件") {
                        route = CloudRoute(provider: provider, account: selected, share: nil)
                    }.disabled(selected == nil)
                }
                if let error { Section("提示") { Text(error).foregroundStyle(.red) } }
                Section {
                    Text("接入十种网盘。支持目录及长按文件管理、个人盘递归批量下载（最多 500 文件/100 目录）；百度和迅雷分享先显式转存，再从个人盘下载。蓝奏个人盘取链需确认生成分享。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("网盘")
                .confirmationDialog("将口令发送到解析服务？", isPresented: $confirmingCommand, titleVisibility: .visible) {
                    Button("发送并解析") { commandTask?.cancel(); commandTask = Task { await resolveCommand() } }
                    Button("取消", role: .cancel) { pendingCommand = ""; pendingPasscode = "" }
                } message: {
                    Text("先尝试迅雷；无结果时将口令及手填提取码发送至第三方星海服务。仅发送本次文本，不发送网盘账号凭据。服务可能记录文本。")
                }
                .onReceive(navigation.$cloudInput.compactMap { $0 }) { value in
                    commandTask?.cancel()
                    input = value; passcode = ""; error = nil
                    if let share = try? CloudShare.parse(value) { provider = share.provider }
                    navigation.cloudInput = nil
                }
                .onReceive(vault.$accounts) { values in
                    if let id = accountID, !values.contains(where: { $0.id == id && $0.platform == provider.rawValue }) { accountID = nil; choseAccount = true }
                    else if accountID == nil && !choseAccount { accountID = CloudAccountSelection.automatic(values, provider: provider)?.id }
                }
                .onAppear { if !choseAccount { accountID = CloudAccountSelection.automatic(vault.accounts, provider: provider)?.id } }
                .onDisappear { commandTask?.cancel() }
                .sheet(item: $route) { item in
                    CloudBrowserScreen(route: item, vault: vault, downloads: downloads) { selected in
                        if provider == item.provider { accountID = selected?.id; choseAccount = true }
                    }
                }
        }
    }
    private func resolveCommand() async {
        guard !resolvingCommand else { return }
        let command = pendingCommand, code = pendingPasscode
        let requestedProvider = provider, requestedAccount = accountID
        pendingCommand = ""; pendingPasscode = ""; resolvingCommand = true
        defer { resolvingCommand = false }
        do {
            let share = try await CloudCommandClient().resolve(command, passcode: code)
            try Task.checkCancellation()
            guard input == command, passcode == code, provider == requestedProvider, accountID == requestedAccount else { return }
            if provider != share.provider {
                provider = share.provider
                choseAccount = false
                accountID = CloudAccountSelection.automatic(vault.accounts, provider: share.provider)?.id
            }
            open(share)
        } catch { if !Task.isCancelled { self.error = "口令解析失败。请检查网络、稍后重试或粘贴原始分享链接。" } }
    }
    private func open(_ share: CloudShare) {
        guard share.provider == provider else { error = "这是\(share.provider.rawValue)链接，请先切换平台再解析。"; return }
        error = nil
        var canonical = URLComponents()
        canonical.scheme = "https"; canonical.host = share.sourceURL?.host ?? share.provider.webHost
        canonical.path = share.provider == .c139 ? "/shareweb/" : (share.provider == .lanzou ? "/" + share.shareID : "/s/" + share.shareID)
        if share.provider == .c139 { canonical.fragment = "/w/i/" + share.shareID }
        if !share.passcode.isEmpty { canonical.queryItems = [URLQueryItem(name: "pwd", value: share.passcode)] }
        if let url = canonical.url { library.record(platform: provider.rawValue, text: url.absoluteString) }
        route = CloudRoute(provider: provider, account: selected, share: share)
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
    private let accountAvailable: () -> Bool
    private let selectedAccountID: UUID?

    init(route: CloudRoute, vault: CredentialVault, downloads: DownloadStore) {
        share = route.share
        selectedAccountID = route.account?.id
        self.downloads = downloads
        let current = route.account.flatMap { saved in vault.accounts.first { $0.id == saved.id && $0.platform == route.provider.rawValue } }
        accountAvailable = { [weak vault] in
            guard let id = route.account?.id else { return true }
            return vault?.accounts.contains { $0.id == id && $0.platform == route.provider.rawValue } == true
        }
        client = CloudClient(provider: route.provider, cookie: current?.secret ?? "", fields: current?.backupFields ?? [:],
                             credentialChanged: { [weak vault] token, fields in
            guard let id = route.account?.id else { return false }
            return vault?.updateCredential(id, secret: token, fields: fields) == true
        },
                             cookieChanged: { [weak vault] new in
            if let id = route.account?.id { vault?.updateSecret(id, secret: new) }
        })
        if route.share != nil, let path = route.initialFolders, path.first?.id == "0", path.count <= 101 { folders = path }
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

    func manage(_ operation: CloudMutation) async {
        guard !busy else { return }
        busy = true; failure = nil; message = nil
        do {
            try checkDownloadAccount()
            try await client.mutate(operation)
            message = "操作完成。"
        } catch {
            if Task.isCancelled || error is CancellationError { message = "已停止等待；服务端操作可能已提交，请刷新目录确认。" }
            else { failure = error is CloudError ? error.localizedDescription : "平台操作失败，请检查网络并刷新目录确认。" }
        }
        busy = false
        if failure == nil && !Task.isCancelled { await reload() }
    }

    private func load(path: [Folder], nextPage: Int) async {
        guard !busy, let folder = path.last else { return }
        guard nextPage <= 200 else { failure = "目录分页已达安全上限。"; canLoadMore = false; return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try checkDownloadAccount()
            let result = try await client.listPage(share: share, parentID: folder.id, page: nextPage)
            let batch = result.files
            try Task.checkCancellation()
            var known = nextPage == 1 ? Set<String>() : Set(files.map(\.id))
            let fresh = batch.filter { known.insert($0.id).inserted }
            guard batch.isEmpty || !fresh.isEmpty else { throw CloudError.message("目录分页重复，已停止继续加载，请刷新后重试。") }
            files = nextPage == 1 ? fresh : files + fresh
            folders = path
            page = nextPage
            canLoadMore = result.hasMore
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    private func checkDownloadAccount() throws {
        guard accountAvailable() else { throw CloudError.message("所选账号已移除，请关闭目录并重新选择账号。") }
    }
    private func enqueue(_ result: CloudDownload, file: CloudFile, filename: String? = nil, nativeConnections: Int?) async throws -> Bool {
        try checkDownloadAccount()
        if let nativeConnections {
            let plan = CloudDownload(url: result.url, filename: filename ?? result.filename, size: result.size, headers: result.headers)
            let context = CloudTransferContext(provider: client.provider, accountID: selectedAccountID, share: share,
                file: file, filename: FileNamePolicy.name(plan.filename), connections: nativeConnections)
            _ = try await NativeEngine.shared.createCloudHTTPS(plan, context: context)
            return true
        }
        return downloads.add(result.url, filename: filename ?? result.filename, headers: result.headers, expectedSize: result.size, allowsBackground: result.allowsBackground)
    }
    func downloadCurrentFolder(nativeConnections: Int? = nil) async {
        guard !busy, let folder = folders.last else { return }
        busy = true; failure = nil; message = "正在枚举文件夹…"
        defer { busy = false }
        var added = 0
        var failed = 0
        do {
            try checkDownloadAccount()
            let batch = try await CloudFolderCollector().collectPages(rootID: folder.id) { parent, page in
                try self.checkDownloadAccount()
                return try await self.client.listPage(share: self.share, parentID: parent, page: page)
            }
            for item in batch {
                try Task.checkCancellation()
                do {
                    try checkDownloadAccount()
                    let result = try await client.download(file: item.file, share: share)
                    try Task.checkCancellation()
                    // Keep the download store's flat layout while retaining the folder names in the filename.
                    let name = (item.relativeFolders + [result.filename]).joined(separator: "_")
                    if try await enqueue(result, file: item.file, filename: name, nativeConnections: nativeConnections) {
                        added += 1
                    } else { failed += 1 }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
                message = "已加入 \(added) 个，失败 \(failed) 个（共 \(batch.count) 个）"
            }
            message = batch.isEmpty ? "文件夹没有可下载的文件。" : "批量处理结束：已加入 \(added) 个，失败 \(failed) 个。" + (nativeConnections == nil ? "" : "请到下载页的原生引擎任务查看。")
        } catch is CancellationError {
            message = "已取消后续添加；已加入 \(added) 个任务，可在下载页暂停。"
        } catch { message = nil; failure = error.localizedDescription }
    }

    func download(_ file: CloudFile, nativeConnections: Int? = nil) async {
        guard !busy else { return }
        busy = true
        failure = nil
        message = nil
        defer { busy = false }
        do {
            try checkDownloadAccount()
            let result = try await client.download(file: file, share: share)
            try Task.checkCancellation()
            if try await enqueue(result, file: file, nativeConnections: nativeConnections) {
                message = nativeConnections == nil ? "已加入下载：\(file.name)，请到「下载」查看。" : "已加入原生下载：\(file.name)，请到「下载 → 原生引擎任务」查看。"
            } else { failure = downloads.storageError ?? "创建下载任务失败。" }
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

@MainActor
struct CloudBrowserScreen: View {
    @State private var selectedRoute: CloudRoute
    @ObservedObject private var vault: CredentialVault
    private let downloads: DownloadStore
    private let accountChanged: (SavedCredential?) -> Void
    init(route: CloudRoute, vault: CredentialVault, downloads: DownloadStore, accountChanged: @escaping (SavedCredential?) -> Void = { _ in }) {
        _selectedRoute = State(initialValue: route)
        self.vault = vault; self.downloads = downloads; self.accountChanged = accountChanged
    }
    var body: some View {
        CloudBrowserContents(route: selectedRoute, vault: vault, downloads: downloads) { account, path in
            selectedRoute = CloudRoute(provider: selectedRoute.provider, account: account, share: selectedRoute.share,
                initialFolders: selectedRoute.share == nil ? nil : path)
            accountChanged(account)
        }.id(selectedRoute.id)
    }
}

@MainActor
private struct CloudBrowserContents: View {
    let route: CloudRoute
    @StateObject private var model: CloudBrowserModel
    @State private var action: Task<Void, Never>?
    @State private var shareDownloadFile: CloudFile?
    @State private var confirmBatch = false
    @State private var renameFile: CloudFile?
    @State private var name = ""
    @State private var showName = false
    @State private var deleteFile: CloudFile?
    @State private var destinationFile: CloudFile?
    @State private var nativeFile: CloudFile?
    @AppStorage("cloudNativeHTTP") private var nativeHTTP = false
    @AppStorage private var nativeConnections: Int
    @ObservedObject private var vault: CredentialVault
    private let selectAccount: (SavedCredential?, [CloudBrowserModel.Folder]) -> Void
    @State private var showAccounts = false
    @State private var showLogin = false
    @State private var chooseAccount = false
    @State private var accountsBeforeLogin = Set<UUID>()
    @Environment(\.dismiss) private var dismiss

    init(route: CloudRoute, vault: CredentialVault, downloads: DownloadStore, selectAccount: @escaping (SavedCredential?, [CloudBrowserModel.Folder]) -> Void) {
        self.route = route
        self.vault = vault
        self.selectAccount = selectAccount
        _nativeConnections = AppStorage(wrappedValue: 4, "cloudHTTPConnections." + route.provider.rawValue)
        _model = StateObject(wrappedValue: CloudBrowserModel(route: route, vault: vault, downloads: downloads))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(route.share == nil ? "网盘账号" : "分享操作账号") {
                    Picker("账号", selection: Binding(get: { route.account?.id }, set: { id in
                        selectAccount(availableAccounts.first { $0.id == id }, model.folders)
                    })) {
                        Text("游客（仅浏览分享）").tag(Optional<UUID>.none)
                        ForEach(availableAccounts) { account in
                            Text(account.remark.isEmpty ? "已保存账号" : account.remark).tag(Optional(account.id))
                        }
                        if let id = route.account?.id, currentAccount == nil { Text("账号已移除或凭证为空").tag(Optional(id)) }
                    }.disabled(model.busy)
                    if currentAccount == nil {
                        Text("尚未选择可用账号。游客可查看分享文件；转存和个人网盘下载需要登录并选择账号。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("选择账号或登录") { requestAccount() }.disabled(model.busy)
                    }
                    if route.provider.supportsWebCookieLogin {
                        Button(currentAccount == nil ? "登录\(route.provider.rawValue)" : "重新登录\(route.provider.rawValue)") { beginLogin() }.disabled(model.busy)
                    }
                    Button("管理账号") { accountsBeforeLogin = Set(availableAccounts.map(\.id)); showAccounts = true }.disabled(model.busy)
                }
                Section("文件传输") {
                    Toggle("原生多连接（前台）", isOn: $nativeHTTP)
                    if nativeHTTP {
                        Stepper("\(route.provider.rawValue)连接数：\(nativeConnections)", value: $nativeConnections, in: 1...512)
                        Text("凭证保存在钥匙串；多个原生文件共享原生 HTTP 限速。系统会话的后台策略不适用于此模式。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(model.folders.map(\.name).joined(separator: " / "))
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.folders.count > 1 {
                        Button("返回上级") { action = Task { await model.back() } }.disabled(model.busy)
                    }
                    if route.provider == .lanzou, route.share == nil {
                        Text("蓝奏个人文件取链会生成公开分享链接，请逐个确认下载。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if [CloudProvider.xunlei, .baidu].contains(route.provider), route.share != nil {
                        Text("\(route.provider.rawValue)分享需选择已登录账号转存，再从个人网盘下载。转存前可选择目标目录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else { Button("下载此目录（含子目录）") { confirmBatch = true }.disabled(model.busy) }
                    if route.provider.supportsManagement, route.share == nil, route.account != nil {
                        Button("新建文件夹") { renameFile = nil; name = ""; showName = true }.disabled(model.busy)
                    }
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
                                if [CloudProvider.xunlei, .baidu].contains(route.provider), route.share != nil {
                                    Button(currentAccount == nil ? "选择账号" : "转存") {
                                        if currentAccount == nil { requestAccount() } else { destinationFile = file }
                                    }.buttonStyle(.bordered).disabled(model.busy)
                                } else if route.provider == .lanzou, route.share == nil {
                                    Button("生成分享并下载") { shareDownloadFile = file }.buttonStyle(.bordered).disabled(model.busy)
                                } else {
                                    Button("下载") { startDownload(file) }
                                        .buttonStyle(.bordered).disabled(model.busy)
                                }
                            }
                        }
                        .contextMenu {
                            if route.provider.supportsManagement, route.account != nil {
                                if route.share == nil {
                                    Button("重命名") { renameFile = file; name = file.name; showName = true }
                                    if route.provider != .lanzou || !file.isDirectory { Button("移动到…") { destinationFile = file } }
                                    Button("从网盘删除", role: .destructive) { deleteFile = file }
                                } else if route.provider.supportsTransfer { Button("转存到个人网盘…") { destinationFile = file } }
                            }
                        }.disabled(model.busy)
                    }
                    if model.canLoadMore {
                        Button("加载更多") { action = Task { await model.more() } }.disabled(model.busy)
                    }
                    if model.failure != nil && model.files.isEmpty {
                        Button("重试") { action = Task { await model.reload() } }.disabled(model.busy)
                    }
                }
            }
            .confirmationDialog("生成公开分享链接？", isPresented: Binding(get: { shareDownloadFile != nil }, set: { if !$0 { shareDownloadFile = nil } }), titleVisibility: .visible, presenting: shareDownloadFile) { file in
                Button("生成分享并下载") { startDownload(file, approvedConnections: true); shareDownloadFile = nil }
                Button("取消", role: .cancel) { shareDownloadFile = nil }
            } message: { _ in Text("此操作将通过蓝奏官网为该文件生成公开分享链接，随后下载；链接可在官网管理或撤销。" + connectionNotice) }
            .confirmationDialog("使用 \(nativeConnections) 个原生连接下载？", isPresented: Binding(get: { nativeFile != nil }, set: { if !$0 { nativeFile = nil } }), titleVisibility: .visible, presenting: nativeFile) { file in
                Button("确认下载") { startDownload(file, approvedConnections: true); nativeFile = nil }
                Button("取消", role: .cancel) { nativeFile = nil }
            } message: { _ in Text(connectionNotice) }
            .navigationTitle(route.share == nil ? "\(route.provider.rawValue)网盘" : "\(route.provider.rawValue)分享")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await model.reload() }
            .refreshable { await model.reload() }
            .onDisappear { action?.cancel() }
            .alert(renameFile == nil ? "新建文件夹" : "重命名", isPresented: $showName) {
                TextField("名称", text: $name)
                Button("取消", role: .cancel) { }
                Button("保存") {
                    let operation: CloudMutation = renameFile.map { .rename(file: $0, name: name) } ?? .createFolder(name: name, parent: model.folders.last?.id ?? "0")
                    action = Task { await model.manage(operation) }
                }
            }
            .confirmationDialog("从\(route.provider.rawValue)个人网盘删除所选文件或文件夹？", isPresented: Binding(get: { deleteFile != nil }, set: { if !$0 { deleteFile = nil } }), titleVisibility: .visible, presenting: deleteFile) { file in
                Button("删除 \(file.name)", role: .destructive) { action = Task { await model.manage(.trash(file: file)) }; deleteFile = nil }
            }
            .sheet(item: $destinationFile) { file in
                CloudDestinationScreen(route: route, vault: vault, excludedID: route.share == nil && file.isDirectory ? file.id : nil) { parent in
                    destinationFile = nil
                    let operation: CloudMutation = route.share.map { .save(file: file, share: $0, parent: parent) } ?? .move(file: file, parent: parent)
                    action = Task { await model.manage(operation) }
                }
            }
            .sheet(isPresented: $showAccounts, onDismiss: accountLoginFinished) { AccountScreen(vault: vault, modal: true) }
            .sheet(isPresented: $showLogin, onDismiss: accountLoginFinished) { CloudWebLogin(provider: route.provider, vault: vault) }
            .confirmationDialog("选择\(route.provider.rawValue)账号", isPresented: $chooseAccount, titleVisibility: .visible) {
                ForEach(availableAccounts) { account in
                    Button(account.remark.isEmpty ? "已保存账号" : account.remark) { selectAccount(account, model.folders) }
                }
                if route.provider.supportsWebCookieLogin { Button("登录新账号") { beginLogin() } }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("将递归加入当前目录下的文件，最多 500 个文件、100 个目录。子目录名称合并到文件名，不创建目录树。", isPresented: $confirmBatch, titleVisibility: .visible) {
                Button("开始批量下载") { action = Task { await model.downloadCurrentFolder(nativeConnections: nativeHTTP ? nativeConnections : nil) } }
            } message: { Text(connectionNotice) }
        }
    }
    private var availableAccounts: [SavedCredential] {
        vault.accounts.filter { $0.platform == route.provider.rawValue && !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var currentAccount: SavedCredential? { availableAccounts.first { $0.id == route.account?.id } }
    private func requestAccount() {
        if availableAccounts.isEmpty { beginLogin() } else { chooseAccount = true }
    }
    private func beginLogin() {
        accountsBeforeLogin = Set(availableAccounts.map(\.id))
        if route.provider.supportsWebCookieLogin { showLogin = true } else { showAccounts = true }
    }
    private func accountLoginFinished() {
        let added = availableAccounts.filter { !accountsBeforeLogin.contains($0.id) }
        if added.count == 1 { selectAccount(added.first, model.folders) }
        else if let currentAccount, currentAccount.secret != route.account?.secret || currentAccount.backupFields != route.account?.backupFields {
            selectAccount(currentAccount, model.folders)
        } else if route.account == nil, let automatic = CloudAccountSelection.automatic(availableAccounts, provider: route.provider) {
            selectAccount(automatic, model.folders)
        }
    }
    private var connectionNotice: String {
        guard nativeHTTP else { return "使用系统下载会话，按文件鉴权情况选择前台或后台。" }
        return "每个原生文件使用 \(nativeConnections) 个连接。" + (nativeConnections > 32 ? "超过 32 个连接可能导致平台限流、耗电和内存压力，请确认后继续。" : "任务在前台运行。")
    }
    private func startDownload(_ file: CloudFile, approvedConnections: Bool = false) {
        if nativeHTTP && nativeConnections > 32 && !approvedConnections { nativeFile = file; return }
        action = Task { await model.download(file, nativeConnections: nativeHTTP ? nativeConnections : nil) }
    }
}

@MainActor
struct CloudDestinationScreen: View {
    private let client: CloudClient
    let excludedID: String?
    let selected: (String) -> Void
    @State private var path = [CloudBrowserModel.Folder(id: "0", name: "根目录")]
    @State private var directories: [CloudFile] = []
    @State private var busy = true
    @State private var failure: String?
    @State private var generation = UUID()
    @Environment(\.dismiss) private var dismiss
    init(route: CloudRoute, vault: CredentialVault, excludedID: String?, selected: @escaping (String) -> Void) {
        self.excludedID = excludedID; self.selected = selected
        let current = route.account.flatMap { saved in vault.accounts.first { $0.id == saved.id } }
        client = CloudClient(provider: route.provider, cookie: current?.secret ?? "", fields: current?.backupFields ?? [:], credentialChanged: { [weak vault] token, fields in
            guard let id = route.account?.id else { return false }
            return vault?.updateCredential(id, secret: token, fields: fields) == true
        })
    }
    var body: some View {
        NavigationStack {
            List {
                Text(path.map(\.name).joined(separator: " / ")).font(.footnote)
                if path.count > 1 { Button("返回上级") { path.removeLast() }.disabled(busy) }
                if busy { ProgressView("读取个人目录…") }
                if let failure { Text(failure).foregroundStyle(.red) }
                ForEach(directories) { folder in
                    Button { path.append(.init(id: folder.id, name: folder.name)) } label: { Label(folder.name, systemImage: "folder") }
                        .disabled(busy || folder.id == excludedID)
                }
                Button("选择此目录并提交") { selected(path.last?.id ?? "0") }.disabled(busy || failure != nil)
            }.navigationTitle("目标目录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task(id: path.last?.id) { await load() }
        }
    }
    private func load() async {
        let generation = UUID()
        self.generation = generation
        busy = true; failure = nil; directories = []
        defer { if self.generation == generation { busy = false } }
        let parent = path.last?.id ?? "0"
        do {
            var seen = Set<String>()
            var result: [CloudFile] = []
            for page in 1...200 {
                let resultPage = try await client.listPage(share: nil, parentID: parent, page: page)
                let files = resultPage.files
                try Task.checkCancellation()
                let fresh = files.filter { seen.insert($0.id).inserted }
                if !files.isEmpty && fresh.isEmpty { throw CloudError.message("目录分页重复，请刷新后重试。") }
                result.append(contentsOf: fresh.filter(\.isDirectory))
                guard result.count <= 2000 else { throw CloudError.message("目标目录过多，请在官网整理后重试。") }
                if !resultPage.hasMore { directories = result; return }
            }
            throw CloudError.message("目录分页达到上限，请稍后重试。")
        } catch is CancellationError { }
        catch { if self.generation == generation { failure = error.localizedDescription } }
    }
}
