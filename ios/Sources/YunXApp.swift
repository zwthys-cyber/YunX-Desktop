// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@main
struct YunXApp: App {
    @StateObject private var downloads = DownloadStore()
    @StateObject private var vault = CredentialVault()
    @StateObject private var library = LinkLibrary()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            TabView {
                CloudHomeScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("网盘", systemImage: "externaldrive") }
                MediaScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("视频与图集", systemImage: "play.rectangle") }
                DownloadScreen(store: downloads)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                NavigationStack {
                    List {
                        NavigationLink("账号管理") { AccountScreen(vault: vault) }
                        NavigationLink("认证备份") { AccountBackupScreen(vault: vault) }
                        NavigationLink("设置与收藏") { SettingsScreen(downloads: downloads) }
                    }.navigationTitle("我的")
                }.tabItem { Label("我的", systemImage: "person.crop.circle") }
                GitHubScreen(vault: vault, downloads: downloads)
                    .tabItem { Label("GitHub", systemImage: "shippingbox") }
            }
            .environmentObject(library)
            .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
        }
    }
}

struct DownloadScreen: View {
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
                        store.add(url)
                        input = ""
                    }
                    if let inputError { Text(inputError).foregroundStyle(.red) }
                    Text("夸克和 UC 分享链接请到「网盘」解析；此处只接受文件直链。当前仅支持前台下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = store.storageError {
                    Section("存储提示") { Text(error).foregroundStyle(.red) }
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
    @State private var editingCredential: SavedCredential?
    @State private var verifyingID: UUID?
    @State private var verification: String?
    private let platforms = [
        "夸克", "UC", "迅雷", "百度", "139", "123", "115", "光鸭",
        "蓝奏云", "蓝奏优享", "哔哩哔哩", "Pixiv", "GitHub"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("登录") {
                    Button("123 账号密码登录") { pan123Login = true }
                    ForEach(CloudProvider.allCases.filter { $0 != .pan123 }) { provider in
                        Button("登录" + provider.rawValue) { loginProvider = provider }
                    }
                    ForEach(MediaProvider.allCases) { provider in
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
                    Text("夸克、UC、哔哩哔哩和 Pixiv 已接入解析；GitHub Token 已用于仓库 API；其他平台暂时仅存储。")
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
                            if CloudProvider(rawValue: account.platform) != nil || MediaProvider(rawValue: account.platform) != nil || account.platform == "GitHub" {
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
                    let client = CloudClient(provider: provider, cookie: account.secret,
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
                    Label("HTTP(S) 直链前台下载", systemImage: "doc")
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
                        "分享扩展、浏览器集成与后台下载"
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
