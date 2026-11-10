// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var selectedTab = 0
    @Published var cloudInput: String?
    @Published var mediaInput: String?
    @Published var githubInput: String?
    @Published var githubOwner: String?
    @Published var downloadInput: String?
}

actor DownloadNotifications {
    static let shared = DownloadNotifications()
    static let preferenceKey = "notifyDownloadCompletions"
    private let enabled: @Sendable () -> Bool
    private let delivery: @Sendable (Int) async -> Void
    private var count = 0
    private var pending: Task<Void, Never>?
    private var lastCompletion = Date.distantPast
    private var generation = UUID()
    private static let requestID = "yunx.download.summary"
    init(enabled: (@Sendable () -> Bool)? = nil, delivery: (@Sendable (Int) async -> Void)? = nil) {
        self.enabled = enabled ?? { UserDefaults.standard.bool(forKey: DownloadNotifications.preferenceKey) }
        self.delivery = delivery ?? { await DownloadNotifications.deliverSystem($0) }
    }
    func completed() async {
        guard enabled() else { return }
        let now = Date()
        if now.timeIntervalSince(lastCompletion) > 2 { count = 0 }
        lastCompletion = now
        count = min(9999, count + 1)
        let total = count
        let previous = pending
        let delivery = delivery
        let ticket = UUID(); generation = ticket
        let task = Task {
            await previous?.value
            await delivery(total)
        }
        pending = task
        await task.value
        if generation == ticket { pending = nil }
    }
    func cancelPending() async {
        await pending?.value
        guard !enabled() else { return }
        count = 0; lastCompletion = .distantPast
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }
    private static func deliverSystem(_ completed: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard UserDefaults.standard.bool(forKey: preferenceKey), settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = "近期有 \(completed) 项下载完成，点按在云析中查看。"
        content.sound = .default
        // OS scheduling survives app suspension; replacing this ID coalesces nearby completions.
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        try? await center.add(request)
    }
}

final class YunXNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if response.notification.request.identifier.hasPrefix("yunx.download.") { AppNavigation.shared.selectedTab = 2 }
            completionHandler()
        }
    }
}

@MainActor
struct DownloadNotificationSettings: View {
    @AppStorage(DownloadNotifications.preferenceKey) private var enabled = false
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var busy = false
    @State private var message: String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Form {
            if status == .authorized || status == .provisional {
                Toggle("下载完成通知", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        Task {
                            if value { await NativeEngine.shared.watchCurrentCompletions() }
                            else { await DownloadNotifications.shared.cancelPending() }
                        }
                    }
            } else if status == .notDetermined {
                Button("请求通知权限并启用") { Task { await request() } }.disabled(busy)
            } else {
                Text("系统未允许通知，可在系统设置中修改。")
                Link("打开系统通知设置", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
            if busy { ProgressView() }
            if let message { Text(message) }
            Text("默认关闭。相近时间完成的任务合并提示，不显示文件名、链接或账号；点按通知打开下载页。通知是否送达由系统设置决定。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("完成通知").task { await refresh() }
            .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
    }
    private func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    private func request() async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
            if enabled { await NativeEngine.shared.watchCurrentCompletions() }
        } catch { message = "暂时无法获取通知授权，请在系统设置中确认。" }
    }
}
