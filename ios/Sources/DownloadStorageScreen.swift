// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DownloadStorageScreen: View {
    @ObservedObject var downloads: DownloadStore
    @EnvironmentObject var assemblies: MediaAssemblyStore
    @State private var picking = false
    @State private var confirming = false
    @State private var selected: URL?
    @State private var busy = false
    @State private var location = ""
    @State private var message: String?
    var body: some View {
        Form {
            Section("下载保存目录") {
                Text(location)
                Button("选择目录并迁移现有下载") { picking = true }.disabled(busy)
                Button("迁回本机 YunX 目录") { selected = nil; confirming = true }.disabled(busy)
                if busy { ProgressView("暂停任务、复制和 SHA-256 校验中…") }
                if let message { Text(message).font(.footnote) }
            } footer: {
                Text("迁移普通下载、原生引擎文件与媒体成品，保持任务路径及断点记录。切换时暂停所有任务，完成后手动继续。请选择空间充足的本地目录，并保持应用在前台；云文件提供者或外置盘是否持续可用由 iOS 决定。")
            }
            Section("数据保护") {
                Text("账号留在设备钥匙串；任务数据库、缓存和浏览器会话留在 iOS 应用沙盒。跨设备迁移账号请使用「认证备份」。")
                Text("文件复制并逐一校验后才切换目录。初次迁移会在本机保留 YunX-original 开头的原文件目录，后续迁移保留旧目标目录。确认新目录可用后可在「文件」中自行清理这些副本。")
                Text("中断时未完成的 YunX-UUID 目录不会作为活动目录。若在最后切换阶段中断，重启会依据记录完成切换；存储位置不可用时停止写入，不另建空目录覆盖记录。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("数据与存储")
            .navigationBarBackButtonHidden(busy)
            .interactiveDismissDisabled(busy)
            .onAppear { location = (try? DownloadStorage.location()) ?? "目录记录无法读取" }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                do { selected = try result.get(); confirming = true }
                catch { message = "未选择可用目录。" }
            }
            .confirmationDialog("暂停所有任务并迁移下载文件？", isPresented: $confirming, titleVisibility: .visible) {
                Button("开始迁移") { Task { await migrate() } }
                Button("取消", role: .cancel) { selected = nil }
            } message: { Text("原文件会保留；迁移需要新目录容纳全部下载文件。完成后不会自动恢复传输。") }
    }
    private func migrate() async {
        guard !busy else { return }
        busy = true; message = nil
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = idle; selected = nil }
        do {
            try DownloadStorage.begin()
            defer { DownloadStorage.end() }
            try await assemblies.quiesceForStorage()
            try await downloads.quiesceForStorage()
            try await NativeEngine.shared.quiesceForStorage()
            try await DownloadStorage.migrate(to: selected)
            location = try DownloadStorage.location()
            message = "目录迁移完成。任务保持暂停，可到下载列表手动继续。原文件副本已保留。"
        } catch {
            message = "迁移未完成，原文件保留。请确认空间和目录权限后重试；若已开始切换路径，请连接原存储并重启应用恢复。"
        }
    }
}
