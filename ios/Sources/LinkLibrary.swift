// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Combine

struct LibraryLink: Codable, Identifiable {
    var id = UUID()
    let platform: String
    let text: String
    var date = Date()
    var favorite = false
}

final class LinkLibrary: ObservableObject {
    @Published private(set) var links: [LibraryLink] = []
    @Published private(set) var error: String?
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YunX/links.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                links = try JSONDecoder().decode([LibraryLink].self, from: Data(contentsOf: self.file))
            }
        } catch { self.error = "无法读取链接记录，原文件未覆盖。" }
    }
    func record(platform: String, text: String) {
        guard error == nil else { return }
        var next = links
        if let index = next.firstIndex(where: { $0.platform == platform && $0.text == text }) {
            var existing = next.remove(at: index)
            existing.date = Date(); next.insert(existing, at: 0)
        } else { next.insert(LibraryLink(platform: platform, text: text), at: 0) }
        var count = 0
        next = next.filter { link in
            if link.favorite { return true }
            count += 1; return count <= 200
        }
        persist(next)
    }
    func toggle(_ id: UUID) {
        var next = links
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].favorite.toggle(); persist(next)
    }
    func delete(_ ids: Set<UUID>) { persist(links.filter { !ids.contains($0.id) }) }
    func clearHistory() { persist(links.filter(\.favorite)) }
    private func persist(_ next: [LibraryLink]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
            links = next; error = nil
        } catch { self.error = "链接记录保存失败，请检查设备存储。" }
    }
}

struct LibraryPicker: View {
    @EnvironmentObject var library: LinkLibrary
    let platform: String
    let select: (String) -> Void
    @State private var showAll = false
    var body: some View {
        Menu("历史与收藏", systemImage: "clock.arrow.circlepath") {
            let links = library.links.filter { $0.platform == platform }
            if links.isEmpty { Text("暂无记录") }
            ForEach(links.prefix(30)) { link in
                Button((link.favorite ? "★ " : "") + link.text) { select(link.text) }
            }
            if !links.isEmpty { Button("搜索全部历史与收藏…") { showAll = true } }
        }.sheet(isPresented: $showAll) {
            LibrarySelectionScreen(platform: platform) { value in select(value); showAll = false }
        }
    }
}

private struct LibrarySelectionScreen: View {
    @EnvironmentObject var library: LinkLibrary
    let platform: String
    let selected: (String) -> Void
    @State private var query = ""
    @State private var favoritesOnly = false
    @Environment(\.dismiss) private var dismiss
    private var matching: [LibraryLink] {
        library.links.filter { $0.platform == platform && (!favoritesOnly || $0.favorite) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Toggle("只看收藏", isOn: $favoritesOnly)
                ForEach(matching) { link in
                    Button { selected(link.text) } label: {
                        Label(link.text, systemImage: link.favorite ? "star.fill" : "clock").lineLimit(4)
                    }
                }
                if matching.isEmpty { Text("没有匹配的记录。") }
            }.navigationTitle(platform + "记录")
                .searchable(text: $query, prompt: "搜索链接或提取码")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct SettingsScreen: View {
    @ObservedObject var downloads: DownloadStore
    @EnvironmentObject var library: LinkLibrary
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentRGB") private var accent = ThemeColor.initial
    @State private var favoritesOnly = false
    @State private var confirmClear = false
    @State private var search = ""
    private var matching: [LibraryLink] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.links.filter { (!favoritesOnly || $0.favorite) && (query.isEmpty || $0.platform.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        Form {
            Section("版本") { NavigationLink("iOS 更新") { IOSUpdatesScreen(store: .shared) } }
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                ColorPicker("强调色", selection: Binding(get: { ThemeColor.color(accent) }, set: { if let value = ThemeColor.value($0) { accent = value } }), supportsOpacity: false)
                Button("恢复默认强调色") { accent = ThemeColor.initial }
            }
            Section("下载") {
                NavigationLink("完成通知") { DownloadNotificationSettings() }
                Stepper("同时下载：\(downloads.maximumConcurrent)", value: $downloads.maximumConcurrent, in: 1...6)
                Text("调低并发后，正在下载的任务继续；新任务等待空闲位置。公开 HTTPS 任务使用系统后台传输，带账号鉴权头的任务使用前台会话。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("链接记录") {
                Toggle("只看收藏", isOn: $favoritesOnly)
                if let error = library.error { Text(error).foregroundStyle(.red) }
                if !search.isEmpty { Text("匹配 \(matching.count) 条记录").font(.caption).foregroundStyle(.secondary) }
                ForEach(matching) { link in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(link.platform).font(.caption).foregroundStyle(.secondary)
                        Text(link.text).textSelection(.enabled)
                        HStack {
                            Button(link.favorite ? "取消收藏" : "收藏") { library.toggle(link.id) }
                                .buttonStyle(.bordered)
                            ShareLink(item: link.text) { Text("分享") }.buttonStyle(.bordered)
                            Spacer()
                            Button("删除", role: .destructive) { library.delete([link.id]) }.buttonStyle(.bordered)
                        }
                    }
                }
                Button("清空未收藏历史", role: .destructive) { confirmClear = true }
                Text("保留最近 200 条历史和收藏。记录可能包含分享提取码，仅保存在本应用的受保护文件中；不保存账号凭证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section { NavigationLink("移植进度与开源许可") { PortStatusScreen() } }
        }.navigationTitle("设置与收藏")
            .searchable(text: $search, prompt: "搜索平台、链接或提取码")
            .confirmationDialog("清空未收藏的历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空历史", role: .destructive) { library.clearHistory() }
            }
    }
}
