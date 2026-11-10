// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

struct EncryptedAccountDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= AuthBackup.maximumBytes else {
            throw CloudError.message("备份文件无效或过大。")
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AccountBackupScreen: View {
    @ObservedObject var vault: CredentialVault
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var message: String?
    @State private var document: EncryptedAccountDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var preview: [SavedCredential] = []
    @State private var confirmRestore = false
    var body: some View {
        Form {
            Section("备份口令") {
                SecureField("至少 8 位口令", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("导出时再次输入口令", text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("口令无法找回。备份只包含账号凭证、备注和主账号标记，不包含下载文件；导出文件使用口令加密。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("导出全部账号（\(vault.accounts.count) 个）") { export() }
                    .disabled(busy || password.utf16.count < 8 || password != confirmation || vault.accounts.isEmpty)
                Button("选择 .yunx 备份并预览") { importing = true }
                    .disabled(busy || password.isEmpty)
                if busy { ProgressView("正在处理加密备份…") }
                if let message { Text(message).textSelection(.enabled) }
            }
            if !preview.isEmpty {
                Section("恢复预览（\(preview.count) 个账号）") {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, account in
                        HStack {
                            Text(account.platform)
                            Text(account.remark).foregroundStyle(.secondary)
                            if account.isPrimary == true { Text("主账号").font(.caption) }
                        }
                    }
                    Button("合并到本机钥匙串") { confirmRestore = true }.disabled(busy)
                    Button("取消预览", role: .cancel) { preview = [] }
                }
            }
            Section {
                Text("兼容桌面版 V1/V2 加密封装。导入保留现有账号，相同平台和凭证合并；不同凭证增加为新账号。桌面版部分网盘只恢复一个主账号，因此多账号备份在桌面恢复时可能只保留最后一项。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("认证备份")
            .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "yunx_auth_backup.yunx") { result in
                switch result {
                case .success: message = "加密备份已导出。"; password = ""; confirmation = ""
                case .failure: message = "备份未导出。"
                }
                document = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { message = "未选择备份文件。"; return }
                restorePreview(url)
            }
            .confirmationDialog("将恢复预览中的账号，现有其他账号会保留。", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("恢复账号") {
                    let count = vault.restore(preview)
                    message = vault.message ?? "已合并恢复 \(count) 个账号。"
                    if vault.message == nil { preview = []; password = ""; confirmation = "" }
                }
            }
            .onDisappear { preview = []; password = ""; confirmation = ""; document = nil }
    }
    private func export() {
        busy = true; message = nil
        let accounts = vault.accounts
        let pass = password
        Task { @MainActor in
            defer { busy = false }
            do {
                let encrypted = try await Task.detached(priority: .userInitiated) { try AuthBackup.encode(accounts, password: pass) }.value
                document = EncryptedAccountDocument(data: encrypted)
                exporting = true
            } catch { message = "备份加密失败，请检查口令或减少账号数量。" }
        }
    }
    private func restorePreview(_ url: URL) {
        busy = true; message = nil; preview = []
        let pass = password
        Task { @MainActor in
            defer { busy = false }
            do {
                let accounts = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= AuthBackup.maximumBytes else { throw CloudError.message("备份文件无效或超过 8MB。") }
                    return try AuthBackup.decode(Data(contentsOf: url), password: pass)
                }.value
                preview = accounts
                message = accounts.isEmpty ? "备份中没有账号。" : "备份已解密，请核对账号后确认恢复。"
            } catch { message = "无法读取备份：口令错误、文件损坏或包含不受支持的账号结构。" }
        }
    }
}
