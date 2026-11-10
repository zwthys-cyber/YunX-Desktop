// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import UIKit
import UserNotifications

enum BackgroundDownloadPolicy {
    static let identifier = "io.github.zwthys.yunx.downloads.v1"
    static func allows(_ url: URL, headers: [String: String]) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return false }
        // Background sessions follow redirects without the app's redirect delegate.
        // Keep all account/custom credential headers in the foreground session.
        return headers.keys.allSatisfy { ["user-agent", "referer", "origin", "accept"].contains($0.lowercased()) }
    }
}

@MainActor
final class BackgroundCompletionRegistry {
    private var completions: [() -> Void] = []
    func register(_ handler: @escaping () -> Void) {
        completions.append(handler)
    }
    func finished() {
        DispatchQueue.main.async { [self] in
            let handlers = completions
            completions.removeAll()
            handlers.forEach { $0() }
        }
    }
}

@MainActor
enum BackgroundDownloadEvents {
    static let registry = BackgroundCompletionRegistry()
    static func register(_ handler: @escaping () -> Void) { registry.register(handler) }
    static func finished() { registry.finished() }
}

@MainActor
final class YunXAppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = YunXNotificationDelegate()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloadPolicy.identifier else { completionHandler(); return }
        BackgroundDownloadEvents.register(completionHandler)
        // Reconnect before processing events, even when there is no active scene.
        _ = DownloadStore.shared
    }
}
