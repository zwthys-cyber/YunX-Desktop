// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor
struct GuangYaSMSLoginScreen: View {
    @ObservedObject var vault: CredentialVault
    let onSaved: () -> Void
    @State private var phone = ""
    @State private var code = ""
    @State private var challenge: GuangYaSMSChallenge?
    @State private var allowRegistration = false
    @State private var busy = false
    @State private var resendAfter = Date.distantPast
    @State private var message: String?
    @State private var session: URLSession?
    @State private var client: GuangYaClient?
    @State private var action: Task<Void, Never>?
    var body: some View {
        Form {
            TextField("11 位手机号", text: $phone).keyboardType(.phonePad)
                .onChange(of: phone) { _, _ in challenge = nil; code = ""; allowRegistration = false }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(resendAfter.timeIntervalSince(context.date))))
                Button(remaining > 0 ? "\(remaining) 秒后可重新发送" : "发送短信验证码") {
                    action = Task { await send() }
                }.disabled(busy || remaining > 0 || phone.count != 11)
            }
            TextField("短信验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
            if let challenge, !challenge.existing {
                Toggle("我同意在光鸭注册此手机号", isOn: $allowRegistration)
                Link("查看光鸭官网及用户条款", destination: URL(string: "https://www.guangyapan.com/")!)
            }
            Button("验证并登录") { action = Task { await login() } }
                .disabled(busy || challenge == nil || code.isEmpty || (challenge?.existing == false && !allowRegistration))
            if busy { ProgressView() }
            if let message { Text(message).foregroundStyle(.red) }
            Text("短信仅在点击发送后请求光鸭官方服务。手机号变化将作废当前验证；新手机号需要明确同意后才注册。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("光鸭短信登录")
            .onDisappear { action?.cancel(); session?.invalidateAndCancel(); session = nil; client = nil; code = ""; challenge = nil }
    }
    private func service() -> GuangYaClient {
        if let client { return client }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        let client = GuangYaClient(session: session)
        self.session = session; self.client = client
        return client
    }
    private func send() async {
        guard !busy, Date() >= resendAfter else { return }
        busy = true; message = nil; challenge = nil
        let requested = phone
        defer { busy = false }
        do {
            let result = try await service().sendSMS(phone: requested)
            try Task.checkCancellation()
            resendAfter = Date().addingTimeInterval(60)
            guard phone == requested else { return }
            challenge = result
        } catch { if !Task.isCancelled { message = error is CloudError ? error.localizedDescription : "短信发送失败，请检查网络与平台验证要求。" } }
    }
    private func login() async {
        guard !busy, let challenge else { return }
        busy = true; message = nil
        defer { busy = false; code = "" }
        do {
            let client = service()
            let (token, fields) = try await client.loginSMS(challenge: challenge, code: code, allowRegistration: allowRegistration)
            let name = try await client.validate()
            try Task.checkCancellation()
            guard self.challenge?.id == challenge.id else { return }
            vault.add(platform: "光鸭", remark: name, secret: token, fields: fields)
            if let error = vault.message { message = error } else { onSaved() }
        } catch { if !Task.isCancelled { message = error is CloudError ? error.localizedDescription : "短信登录失败，请检查验证码与平台验证要求。" } }
    }
}
