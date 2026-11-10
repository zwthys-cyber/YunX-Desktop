// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@main
@MainActor
struct YunXApp: App {
    @UIApplicationDelegateAdaptor(YunXAppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var vault = CredentialVault()
    @StateObject private var library = LinkLibrary()
    @StateObject private var assemblies = MediaAssemblyStore()
    @StateObject private var navigation = AppNavigation.shared
    @StateObject private var inbox = ShareInboxModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentRGB") private var accent = ThemeColor.initial

    var body: some Scene {
        WindowGroup {
            TabView(selection: $navigation.selectedTab) {
                CloudHomeScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("网盘", systemImage: "externaldrive") }.tag(0)
                MediaScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("视频与图集", systemImage: "play.rectangle") }.tag(1)
                DownloadScreen(store: downloads)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }.tag(2)
                NavigationStack {
                    List {
                        NavigationLink("P2P 下载引擎") { P2PScreen() }
                        NavigationLink("网页资源浏览器") { ResourceBrowserScreen(downloads: downloads) }
                        NavigationLink("分享收件箱（\(inbox.pending.count)）") { ShareInboxScreen(model: inbox) }
                        NavigationLink("账号管理") { AccountScreen(vault: vault) }
                        NavigationLink("认证备份") { AccountBackupScreen(vault: vault) }
                        NavigationLink("设置与收藏") { SettingsScreen(downloads: downloads) }
                        NavigationLink("诊断") { DiagnosticsScreen() }
                    }.navigationTitle("我的")
                }.tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
                GitHubScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("GitHub", systemImage: "shippingbox") }.tag(4)
            }
            .environmentObject(library)
            .environmentObject(assemblies)
            .task { await Diagnostics.shared.record(.appOpened); inbox.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { inbox.refresh() } }
            .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
            .tint(ThemeColor.color(accent))
        }
    }
}

@MainActor
struct DownloadScreen: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @EnvironmentObject var assemblies: MediaAssemblyStore
    @ObservedObject var store: DownloadStore
    @State private var input = ""
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("新建文件直链下载") {
                    TextField("https://…", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("下载") {
                        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: value),
                              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                              url.host != nil else {
                            inputError = "请输入有效的 HTTP 或 HTTPS 文件直链"
                            return
                        }
                        inputError = nil
                        if store.add(url) { input = "" }
                        else { inputError = store.storageError }
                    }
                    if let inputError { Text(inputError).foregroundStyle(.red) }
                    Text("分享链接请到「网盘」解析。公开 HTTPS 文件使用系统后台传输；带账号或自定义鉴权头的请求使用前台会话。系统可能延迟后台任务，强制退出后需重新打开应用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = store.storageError {
                    Section("存储提示") { Text(error).foregroundStyle(.red) }
                }
                Section("音视频") {
                    NavigationLink("合轨任务（\(assemblies.jobs.count)）") { AssemblyQueueScreen(store: assemblies) }
                }
                Section("原生引擎") {
                    NavigationLink("引擎任务（P2P / HLS）") { P2PScreen() }
                }
                Section("队列") {
                    HStack {
                        Button("全部暂停") { store.pauseAll() }.buttonStyle(.bordered)
                        Button("全部继续") { store.resumeAll() }.buttonStyle(.bordered)
                    }
                    Stepper("同时下载：\(store.maximumConcurrent)", value: $store.maximumConcurrent, in: 1...6)
                }
                Section("任务") {
                    if store.items.isEmpty {
                        ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle")
                    }
                    ForEach(store.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.filename).lineLimit(2)
                            HStack {
                                Text(item.state.title)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file))
                            }.font(.caption).foregroundStyle(.secondary)
                            if item.expected > 0 {
                                ProgressView(value: min(Double(item.received) / Double(item.expected), 1))
                            }
                            if let digest = item.sha256 {
                                Text("SHA-256: " + digest).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                            NavigationLink("任务诊断") { DownloadDiagnosticScreen(store: store, id: item.id) }.font(.caption)
                            HStack {
                                if item.state == .downloading || item.state == .waiting {
                                    Button("暂停") { store.pause(item.id) }.buttonStyle(.bordered)
                                } else if [.paused, .failed, .waiting].contains(item.state) {
                                    Button("继续") { store.start(item.id) }.buttonStyle(.bordered)
                                }
                                if let file = store.fileURL(item) {
                                    Button(store.hashing.contains(item.id) ? "计算中…" : "SHA-256") { store.calculateChecksum(item.id) }
                                        .buttonStyle(.bordered).disabled(store.hashing.contains(item.id))
                                    ShareLink(item: file) { Label("导出", systemImage: "square.and.arrow.up") }
                                        .buttonStyle(.bordered)
                                }
                                Spacer()
                                Button("删除记录", role: .destructive) { store.delete(item.id) }
                                    .buttonStyle(.bordered)
                                    .disabled(item.state == .pausing)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.navigationTitle("云析")
        }
        .onReceive(navigation.$downloadInput.compactMap { $0 }) { value in input = value; inputError = nil; navigation.downloadInput = nil }
    }
}

@MainActor
struct AccountScreen: View {
    @ObservedObject var vault: CredentialVault
    @State private var platform = "夸克"
    @State private var remark = ""
    @State private var secret = ""
    @State private var loginProvider: CloudProvider?
    @State private var mediaLoginProvider: MediaProvider?
    @State private var pan123Login = false
    @State private var guangyaLogin = false
    @State private var ilanzouLogin = false
    @State private var xunleiLogin = false
    @State private var editingCredential: SavedCredential?
    @State private var verifyingID: UUID?
    @State private var verification: String?
    private let platforms = [
        "夸克", "UC", "迅雷", "百度", "139", "123", "115", "光鸭",
        "蓝奏云", "蓝奏优享", "哔哩哔哩", "Pixiv", "微博", "快手", "AcFun", "抖音", "小红书", "GitHub"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("登录") {
                    Button("123 账号密码登录") { pan123Login = true }
                    Button("光鸭账号密码登录") { guangyaLogin = true }
                    Button("蓝奏优享账号密码登录") { ilanzouLogin = true }
                    Button("迅雷官网登录") { xunleiLogin = true }
                    ForEach(CloudProvider.allCases.filter(\.supportsWebCookieLogin)) { provider in
                        Button("登录" + provider.rawValue) { loginProvider = provider }
                    }
                    ForEach(MediaProvider.allCases.filter { $0.supportsAccountValidation }) { provider in
                        Button("登录" + provider.rawValue) { mediaLoginProvider = provider }
                    }
                }
                if let verification {
                    Section("账号验证") { Text(verification) }
                }
                Section("手动保存凭证") {
                    Picker("平台", selection: $platform) {
                        ForEach(platforms, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("账号备注", text: $remark)
                    SecureField("Cookie 或 Token", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存到钥匙串") {
                        vault.add(platform: platform, remark: remark, secret: secret)
                        if vault.message == nil { secret = ""; remark = "" }
                    }.disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("夸克、UC、123、光鸭、蓝奏优享、迅雷和媒体平台已接入解析；GitHub Token 用于仓库 API。百度、139、115 和蓝奏云暂时仅存储。迅雷凭据还需要对应设备标识，请使用官网登录或完整备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = vault.message {
                    Section("提示") { Text(message).foregroundStyle(.red) }
                }
                Section("已保存账号") {
                    ForEach(vault.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.platform + (account.isPrimary == true ? " · 主账号" : ""))
                                Text(account.remark.isEmpty ? "未填写备注" : account.remark)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if CloudProvider(rawValue: account.platform) != nil || MediaProvider(rawValue: account.platform)?.supportsAccountValidation == true || account.platform == "GitHub" {
                                Button(verifyingID == account.id ? "验证中" : "验证") { verify(account) }
                                    .disabled(verifyingID != nil).buttonStyle(.bordered)
                            }
                            Menu {
                                Button("编辑备注") { editingCredential = account }
                                Button("设为主账号") { vault.setPrimary(account.id) }
                                Button("删除", role: .destructive) { vault.delete(account.id) }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
            }.navigationTitle("账号")
                .sheet(item: $editingCredential) { CredentialEditScreen(account: $0, vault: vault) }
                .sheet(isPresented: $pan123Login) { Pan123LoginScreen(vault: vault) }
                .sheet(isPresented: $guangyaLogin) { GuangYaLoginScreen(vault: vault) }
                .sheet(isPresented: $ilanzouLogin) { ILanzouLoginScreen(vault: vault) }
                .sheet(isPresented: $xunleiLogin) { XunleiLoginScreen(vault: vault) }
                .sheet(item: $loginProvider) { provider in
                    CloudWebLogin(provider: provider, vault: vault)
                }
                .sheet(item: $mediaLoginProvider) { provider in
                    MediaWebLogin(provider: provider, vault: vault)
                }
        }
    }

    private func verify(_ account: SavedCredential) {
        verifyingID = account.id
        verification = nil
        Task { @MainActor in
            defer { verifyingID = nil }
            do {
                let name: String
                if let provider = CloudProvider(rawValue: account.platform) {
                    let client = CloudClient(provider: provider, cookie: account.secret, fields: account.backupFields ?? [:],
                                             credentialChanged: { vault.updateCredential(account.id, secret: $0, fields: $1) },
                                             cookieChanged: { vault.updateSecret(account.id, secret: $0) })
                    name = try await client.validateAccount()
                } else if let provider = MediaProvider(rawValue: account.platform) {
                    name = try await MediaClient().validate(provider: provider, cookie: account.secret)
                } else if account.platform == "GitHub" {
                    name = try await GitHubClient(token: account.secret).validateAccount()
                } else { return }
                verification = "\(account.platform)账号有效：\(name)"
            } catch { verification = "账号验证失败，请检查登录状态与网络。" }
        }
    }
}

struct PortStatusScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    Text("iOS 17 移植开发版 · 未做真机验证")
                    Text("此分支尚未达到桌面版完整功能；编译记录与开发版 IPA 见 GitHub Actions。")
                        .foregroundStyle(.secondary)
                }
                Section("已编写，等待真机验证") {
                    Label("夸克 / UC 分享解析与个人目录", systemImage: "externaldrive")
                    Label("网页登录、账号验证与 Cookie 刷新", systemImage: "person.crop.circle")
                    Label("B 站单文件解析、分 P 与画质", systemImage: "play.rectangle")
                    Label("Pixiv 多页原图与批量下载", systemImage: "photo.on.rectangle")
                    Label("原生 MP4 与图片预览", systemImage: "play.circle")
                    Label("HTTP(S) 直链与公开 HTTPS 后台会话", systemImage: "doc")
                    Label("暂停、断点数据保存、重试", systemImage: "pause.circle")
                    Label("任务记录与文件导出", systemImage: "square.and.arrow.up")
                    Label("Keychain 多账号凭证存储", systemImage: "key")
                    Label("GitHub 目录、README、Releases 与账号浏览", systemImage: "shippingbox")
                    Label("123 登录、游标目录与签名取链", systemImage: "externaldrive")
                    Label("口令加密认证备份与恢复预览", systemImage: "lock.shield")
                }
                Section("尚未移植") {
                    ForEach([
                        "其他网盘适配与转存管理",
                        "其余视频平台、B 站 DASH 合轨及 Pixiv 动图",
                        "GitHub 子路径链接、镜像和测速",
                        "多线程分片、校验、限速与多源下载",
                        "HLS、DASH 合轨与 Live Photo",
                        "BT、磁力、ed2k 与 Gopeed 引擎",
                        "其他平台登录/令牌适配与运行诊断",
                        "分享扩展、浏览器集成与后台真机验收"
                    ], id: \.self) { Text($0) }
                }
                Section("开源") {
                    Link("源码与移植说明", destination: URL(string: "https://github.com/zwthys-cyber/YunX-Desktop/tree/ios-port/ios")!)
                    Text("基于 tidain/YunX-Desktop，AGPL-3.0。")
                }
            }.navigationTitle("移植进度")
        }
    }
}
