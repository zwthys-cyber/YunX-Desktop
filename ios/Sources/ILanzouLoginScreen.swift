// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor
struct ILanzouLoginScreen: View {
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
                TextField("蓝奏优享账号", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button("登录并验证账号") { action = Task { await login() } }.disabled(busy || account.isEmpty || password.isEmpty)
                if busy { ProgressView() }
                if let message { Text(message).foregroundStyle(.red) }
                Link("蓝奏优享官方网站", destination: URL(string: "https://www.ilanzou.com/")!)
                Text("仅向官方服务提交密码；账号令牌和设备标识保存在钥匙串，密码不保存。平台要求访问验证时停止自动登录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("蓝奏优享登录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { action?.cancel(); dismiss() } } }
        }.onDisappear { action?.cancel(); password = "" }
    }
    private func login() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false; password = "" }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let client = ILanzouClient(session: session)
            let (token, fields) = try await client.login(account: account, password: password)
            let name = try await client.validate()
            try Task.checkCancellation()
            vault.add(platform: "蓝奏优享", remark: name, secret: token, fields: fields)
            if let error = vault.message { message = error } else { dismiss() }
        } catch { if !Task.isCancelled { message = "蓝奏优享登录失败，请检查账号密码、网络和官方验证要求。" } }
    }
}
