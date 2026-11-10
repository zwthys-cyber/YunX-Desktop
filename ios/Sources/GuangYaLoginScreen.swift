// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor
struct GuangYaLoginScreen: View {
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
                TextField("手机、邮箱或用户名", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button("登录并验证账号") { action = Task { await login() } }.disabled(busy || account.isEmpty || password.isEmpty)
                if busy { ProgressView() }
                if let message { Text(message).foregroundStyle(.red) }
                NavigationLink("短信验证码登录") { GuangYaSMSLoginScreen(vault: vault, onSaved: { dismiss() }) }
                Link("光鸭官方网站", destination: URL(string: "https://www.guangyapan.com/")!)
                Text("密码只发送至光鸭官方账号服务，应用只保存账号令牌和设备标识到钥匙串。若要求短信或网页安全验证，将停止登录并显示提示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("光鸭登录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { action?.cancel(); dismiss() } } }
        }.onDisappear { action?.cancel(); password = "" }
    }
    private func login() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false; password = "" }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = NetworkProxy.session(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let client = GuangYaClient(session: session)
            let (token, fields) = try await client.login(account: account, password: password)
            let name = try await client.validate()
            try Task.checkCancellation()
            vault.add(platform: "光鸭", remark: name, secret: token, fields: fields)
            if let error = vault.message { message = error } else { dismiss() }
        } catch { if !Task.isCancelled { message = error is CloudError ? error.localizedDescription : "光鸭登录失败，请检查网络和官方验证要求。" } }
    }
}
