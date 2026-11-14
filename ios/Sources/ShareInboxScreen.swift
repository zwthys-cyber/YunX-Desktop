// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct InboxDestination: Equatable {
    enum Kind: Equatable { case cloud, media, github, githubOwner, download, p2p, unknown }
    let kind: Kind
    let text: String
    var title: String {
        switch kind { case .cloud: return "填入网盘解析"; case .media: return "填入媒体解析"; case .github: return "填入 GitHub 浏览"; case .githubOwner: return "填入 GitHub 账号浏览"; case .download: return "填入文件下载"; case .p2p: return "填入 P2P 下载"; case .unknown: return "尚未识别此内容" }
    }
    static func parse(_ text: String) -> Self {
        if (try? CloudShare.parse(text)) != nil { return Self(kind: .cloud, text: text) }
        if (try? MediaLink.parse(text)) != nil { return Self(kind: .media, text: text) }
        if (try? P2PInput.link(text)) != nil { return Self(kind: .p2p, text: text) }
        if (try? GitHubInput.parse(text)) != nil { return Self(kind: .github, text: text) }
        let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive])
        if let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text), let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "，。；、！？）》」』】"))), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
            if (try? GitHubInput.parse(url.absoluteString)) != nil { return Self(kind: .github, text: url.absoluteString) }
            let path = url.path.split(separator: "/")
            if url.host?.lowercased() == "github.com", path.count == 1, path[0].range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil { return Self(kind: .githubOwner, text: String(path[0])) }
            return Self(kind: .download, text: url.absoluteString)
        }
        return Self(kind: .unknown, text: text)
    }
}

@MainActor
final class ShareInboxModel: ObservableObject {
    @Published var pending: [ShareInboxItem] = []
    @Published var message: String?
    private let store: ShareInbox
    init(store: ShareInbox = ShareInbox()) { self.store = store }
    func refresh() {
        if Bundle.main.object(forInfoDictionaryKey: "YunXShareExtensionEnabled") as? Bool == false {
            pending = []; message = nil; return
        }
        do { pending = try store.items(); message = nil }
        catch { message = error is ShareInboxError ? error.localizedDescription : "分享收件箱无法读取，原内容已保留。" }
    }
    func remove(_ item: ShareInboxItem) {
        do { try store.remove(item.id); refresh() }
        catch { message = "删除失败，原内容已保留，请检查设备空间后重试。" }
    }
}

@MainActor
struct ShareInboxScreen: View {
    private var supportsExtension: Bool { Bundle.main.object(forInfoDictionaryKey: "YunXShareExtensionEnabled") as? Bool != false }
    @ObservedObject var model: ShareInboxModel
    @ObservedObject private var navigation = AppNavigation.shared
    @State private var p2p: ShareInboxItem?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text(supportsExtension ? "从 Safari 或其他应用分享的链接在此等待处理。填入解析页后仍需确认解析或下载；内容会保留，处理后可左滑删除。" : "此兼容签名包可复制链接后到解析页粘贴。需要系统分享扩展时，请使用支持它的完整重签包。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = model.message { Text(message).foregroundStyle(.red) }
            }
            ForEach(model.pending) { item in
                let destination = InboxDestination.parse(item.text)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.text).lineLimit(4).textSelection(.enabled)
                    Text(item.created, style: .date).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if destination.kind != .unknown { Button(destination.title) { route(destination, item: item) }.buttonStyle(.bordered) }
                        else if CloudCommandClient.candidate(item.text) {
                            Button("作为网盘口令填入") { route(InboxDestination(kind: .cloud, text: item.text), item: item) }.buttonStyle(.bordered)
                        }
                        ShareLink(item: item.text) { Text("分享文字") }.buttonStyle(.bordered)
                    }
                }.swipeActions { Button("删除", role: .destructive) { model.remove(item) } }
            }
            if supportsExtension && model.pending.isEmpty && model.message == nil { ContentUnavailableView("分享收件箱为空", systemImage: "tray") }
        }.navigationTitle("分享收件箱").onAppear { model.refresh() }.refreshable { model.refresh() }
            .sheet(item: $p2p) { item in NavigationStack { P2PScreen(initialInput: item.text).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { p2p = nil } } } } }
    }
    private func route(_ destination: InboxDestination, item: ShareInboxItem) {
        switch destination.kind {
        case .cloud: navigation.cloudInput = destination.text; navigation.selectedTab = 0
        case .media: navigation.mediaInput = destination.text; navigation.selectedTab = 1
        case .github: navigation.githubInput = destination.text; navigation.selectedTab = 4
        case .githubOwner: navigation.githubOwner = destination.text; navigation.selectedTab = 4
        case .download: navigation.downloadInput = destination.text; navigation.selectedTab = 2
        case .p2p: p2p = item; return
        case .unknown: return
        }
        dismiss()
    }
}
