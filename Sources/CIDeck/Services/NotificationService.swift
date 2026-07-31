import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// `UNUserNotificationCenter.current()` traps with "bundleProxyForCurrentProcess is nil"
    /// when the process has no real app bundle — e.g. running the bare SwiftPM binary
    /// (`swift run`) during development. Gate every call on the bundle identifier so dev
    /// builds launch instead of crashing; notifications simply no-op there.
    private let isAvailable = Bundle.main.bundleIdentifier != nil

    private override init() {
        super.init()
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notifyNewRun(_ item: RunItem, repository: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "CI/CD mới · \(repository)"
        content.subtitle = item.workflowName
        let branch = item.run.headBranch ?? "unknown branch"
        content.body = "#\(item.run.runNumber) · \(branch) · \(item.run.commitTitle)"
        content.sound = .default
        content.userInfo = ["url": item.run.htmlUrl]

        let request = UNNotificationRequest(
            identifier: "cideck-run-\(item.run.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
