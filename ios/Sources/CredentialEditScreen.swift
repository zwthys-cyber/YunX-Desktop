// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct CredentialEditScreen: View {
    let account: SavedCredential
    @ObservedObject var vault: CredentialVault
    @State private var remark: String
    @Environment(\.dismiss) private var dismiss
    init(account: SavedCredential, vault: CredentialVault) {
        self.account = account; self.vault = vault
        _remark = State(initialValue: account.remark)
    }
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("平台", value: account.platform)
                TextField("账号备注", text: $remark)
                Button("保存备注") {
                    vault.rename(account.id, remark: remark.trimmingCharacters(in: .whitespacesAndNewlines))
                    if vault.message == nil { dismiss() }
                }
                if let error = vault.message { Text(error).foregroundStyle(.red) }
            }.navigationTitle("编辑账号")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
