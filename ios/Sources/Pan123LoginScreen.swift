// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct Pan123LoginScreen: View {
    @ObservedObject var vault: CredentialVault
    @State private var account = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var action: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("123 账号", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("登录并验证账号") { action = Task { await login() } }.disabled(busy || account.isEmpty || password.isEmpty)
                if busy { ProgressView() }
                if let message { Text(message).foregroundStyle(.red) }
                Link("打开 123 官方登录页", destination: URL(string: "https://user.123pan.cn/")!)
                Text("账号密码仅发送到 123 官方登录服务；应用只保存 JWT 到钥匙串，不保存密码。若服务要求额外验证，请先在官网处理，或在手动凭证中保存 JWT。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("123 登录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { action?.cancel(); dismiss() } } }
        }.onDisappear { action?.cancel(); password = "" }
    }
    @MainActor private func login() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false; password = "" }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let token = try await Pan123Client(token: "", session: session).login(account: account, password: password)
            let name = try await Pan123Client(token: token, session: session).validate()
            try Task.checkCancellation()
            vault.add(platform: "123", remark: name, secret: token)
            if let error = vault.message { message = error } else { dismiss() }
        } catch { if !Task.isCancelled { message = "123 登录失败，请检查账号密码、网络或官网验证要求。" } }
    }
}
