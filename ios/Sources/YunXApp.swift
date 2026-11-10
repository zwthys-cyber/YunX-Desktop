// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@main
struct YunXApp: App {
    @StateObject private var downloads = DownloadStore()
    @StateObject private var vault = CredentialVault()

    var body: some Scene {
        WindowGroup {
            TabView {
                DownloadScreen(store: downloads)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                AccountScreen(vault: vault)
                    .tabItem { Label("账号", systemImage: "person.crop.circle") }
                PortStatusScreen()
                    .tabItem { Label("移植进度", systemImage: "list.clipboard") }
            }
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
                    Text("网盘分享页和视频作品页尚未接入，不能作为文件直链下载。当前仅支持前台下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = store.storageError {
                    Section("存储提示") { Text(error).foregroundStyle(.red) }
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
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                            HStack {
                                if item.state == .downloading {
                                    Button("暂停") { store.pause(item.id) }.buttonStyle(.bordered)
                                } else if [.paused, .failed, .waiting].contains(item.state) {
                                    Button("继续") { store.start(item.id) }.buttonStyle(.bordered)
                                }
                                if let file = store.fileURL(item) {
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

struct AccountScreen: View {
    @ObservedObject var vault: CredentialVault
    @State private var platform = "夸克"
    @State private var remark = ""
    @State private var secret = ""
    private let platforms = [
        "夸克", "UC", "迅雷", "百度", "139", "123", "115", "光鸭",
        "蓝奏云", "蓝奏优享", "哔哩哔哩", "Pixiv", "GitHub"
    ]

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("目前仅提供凭证存储；尚未接入平台登录验证或解析请求。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = vault.message {
                    Section("提示") { Text(message).foregroundStyle(.red) }
                }
                Section("已保存账号") {
                    ForEach(vault.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.platform)
                                Text(account.remark.isEmpty ? "未填写备注" : account.remark)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { vault.delete(account.id) }
                        }
                    }
                }
            }.navigationTitle("账号")
        }
    }
}

struct PortStatusScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section("当前状态") {
                    Text("iOS 17 移植源码 · 未编译、未验证")
                    Text("此分支尚未达到桌面版完整功能，当前没有发布 IPA。")
                        .foregroundStyle(.secondary)
                }
                Section("已编写，等待本机验证") {
                    Label("HTTP(S) 直链前台下载", systemImage: "doc")
                    Label("暂停、断点数据保存、重试", systemImage: "pause.circle")
                    Label("任务记录与文件导出", systemImage: "square.and.arrow.up")
                    Label("Keychain 多账号凭证存储", systemImage: "key")
                }
                Section("尚未移植") {
                    ForEach([
                        "全部网盘的登录、目录、取链与转存清理",
                        "七个视频平台解析与高清分轨",
                        "GitHub 仓库浏览、镜像和测速",
                        "多线程分片、校验、限速与多源下载",
                        "HLS、DASH 合轨、Live Photo 与预览",
                        "BT、磁力、ed2k 与 Gopeed 引擎",
                        "网页登录、备份、历史、收藏与诊断",
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
