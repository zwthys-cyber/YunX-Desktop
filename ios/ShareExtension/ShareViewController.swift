// SPDX-License-Identifier: AGPL-3.0-only
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let preview = UITextView()
    private let status = UILabel()
    private let saveButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private var content = ""
    private var loading: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "保存到云析"; title.font = .preferredFont(forTextStyle: .title2)
        preview.isEditable = false; preview.font = .preferredFont(forTextStyle: .body); preview.backgroundColor = .secondarySystemBackground
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .footnote)
        status.text = "正在读取分享内容…"
        saveButton.setTitle("保存链接或文字", for: .normal); saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        copyButton.setTitle("复制链接并完成", for: .normal); copyButton.isEnabled = false
        copyButton.addTarget(self, action: #selector(copyContent), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("取消", for: .normal); cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, preview, status, saveButton, copyButton, cancel]); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20), preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)])
        loading = Task { await read() }
    }
    private func read() async {
        do {
            let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let providers = items.flatMap { $0.attachments ?? [] }
            var texts = items.compactMap { $0.attributedContentText?.string }.filter { !$0.isEmpty }
            guard !providers.isEmpty || !texts.isEmpty, providers.count <= 4 else { throw ShareInboxError.invalid }
            guard texts.allSatisfy({ $0.utf8.count <= 32768 }) else { throw ShareInboxError.tooLarge }
            for provider in providers {
                let type: String
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { type = UTType.url.identifier }
                else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) { type = UTType.text.identifier }
                else { continue }
                let text: String = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                        if error != nil { continuation.resume(throwing: ShareInboxError.invalid); return }
                        if let url = item as? URL, !url.isFileURL { continuation.resume(returning: url.absoluteString) }
                        else if let text = item as? String { continuation.resume(returning: text) }
                        else if let text = item as? NSAttributedString { continuation.resume(returning: text.string) }
                        else { continuation.resume(throwing: ShareInboxError.invalid) }
                    }
                }
                try Task.checkCancellation()
                guard text.utf8.count <= 32768 else { throw ShareInboxError.tooLarge }
                if !texts.contains(text) { texts.append(text) }
            }
            content = texts.joined(separator: "\n")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShareInboxError.invalid }
            guard content.utf8.count <= 32768 else { throw ShareInboxError.tooLarge }
            preview.text = content
            status.text = "保存后请打开云析 → 我的 → 分享收件箱。这里只保存内容，选择解析或下载后才发起网络请求。"
            saveButton.isEnabled = true
            copyButton.isEnabled = true
        } catch { status.text = error is ShareInboxError ? error.localizedDescription : "无法读取分享内容，请改为分享链接或文字。" }
    }
    @objc private func copyContent() {
        guard !content.isEmpty else { return }
        UIPasteboard.general.string = content
        copyButton.isEnabled = false
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    @objc private func save() {
        do {
            try ShareInbox().append(content)
            saveButton.isEnabled = false
            status.text = "已保存，请打开云析的分享收件箱继续。"
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch { status.text = error is ShareInboxError ? error.localizedDescription : "保存失败，请检查设备空间后重试。" }
    }
    @objc private func close() { loading?.cancel(); extensionContext?.completeRequest(returningItems: [], completionHandler: nil) }
    deinit { loading?.cancel() }
}
