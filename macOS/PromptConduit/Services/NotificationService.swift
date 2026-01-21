import Foundation
import UserNotifications
import AppKit

/// Manages macOS notifications for the app
class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    /// Whether notifications are authorized
    @Published private(set) var isAuthorized: Bool = false

    /// Category identifiers
    private enum CategoryIdentifier {
        static let waitingInput = "WAITING_INPUT"
        static let sessionCompleted = "SESSION_COMPLETED"
    }

    /// Action identifiers
    private enum ActionIdentifier {
        static let openSession = "OPEN_SESSION"
        static let dismiss = "DISMISS"
    }

    /// Callback when user taps a notification to focus a session
    var onFocusSession: ((UUID) -> Void)?

    /// Callback when user taps a notification to focus a multi-session group
    var onFocusGroup: ((UUID) -> Void)?

    // MARK: - Initialization

    override private init() {
        super.init()
    }

    // MARK: - Setup

    /// Setup notification service - call this from AppDelegate
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register notification categories
        registerCategories()

        // Check and request authorization if needed
        checkAndRequestAuthorization()
    }

    /// Check authorization and request if not determined
    private func checkAndRequestAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized:
                    self?.isAuthorized = true
                case .notDetermined:
                    // Request permission automatically
                    Task {
                        await self?.requestPermission()
                    }
                case .denied, .provisional, .ephemeral:
                    self?.isAuthorized = false
                @unknown default:
                    self?.isAuthorized = false
                }
            }
        }
    }

    /// Request notification permissions
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.isAuthorized = granted
            }
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    // MARK: - Notification Categories

    private func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: ActionIdentifier.openSession,
            title: "Open Session",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: ActionIdentifier.dismiss,
            title: "Dismiss",
            options: []
        )

        let waitingCategory = UNNotificationCategory(
            identifier: CategoryIdentifier.waitingInput,
            actions: [openAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let completedCategory = UNNotificationCategory(
            identifier: CategoryIdentifier.sessionCompleted,
            actions: [openAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            waitingCategory,
            completedCategory
        ])
    }

    // MARK: - Send Notifications

    /// Notify user that Claude is waiting for input
    func notifyWaitingForInput(
        sessionId: UUID,
        repoName: String,
        groupId: UUID? = nil
    ) {
        print("[NotificationService] notifyWaitingForInput called for \(repoName)")
        print("[NotificationService] notificationSoundEnabled: \(SettingsService.shared.notificationSoundEnabled)")
        print("[NotificationService] isAuthorized: \(isAuthorized)")

        guard SettingsService.shared.notificationSoundEnabled else {
            print("[NotificationService] Notifications disabled in settings")
            return
        }
        guard isAuthorized else {
            print("[NotificationService] Notifications not authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Claude needs input"
        content.body = "Session in \(repoName) is waiting for your response"
        content.sound = .default
        content.categoryIdentifier = CategoryIdentifier.waitingInput

        // Build deep link URL
        let deepLink: String
        if let groupId = groupId {
            deepLink = "promptconduit://group/\(groupId.uuidString)?highlight=\(sessionId.uuidString)"
        } else {
            deepLink = "promptconduit://session/\(sessionId.uuidString)"
        }

        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "groupId": groupId?.uuidString ?? "",
            "repoName": repoName,
            "action": "focus_terminal",
            "deepLink": deepLink
        ]

        // Use session ID as identifier to replace existing notification for same session
        let request = UNNotificationRequest(
            identifier: "waiting-\(sessionId.uuidString)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error sending notification: \(error)")
            }
        }
    }

    /// Notify user that a session has completed
    func notifySessionCompleted(
        sessionId: UUID,
        repoName: String,
        success: Bool = true,
        groupId: UUID? = nil
    ) {
        guard SettingsService.shared.notificationSoundEnabled else { return }
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = success ? "Session Completed" : "Session Failed"
        content.body = "\(repoName) has \(success ? "finished" : "encountered an error")"
        content.sound = .default
        content.categoryIdentifier = CategoryIdentifier.sessionCompleted

        // Build deep link URL
        let deepLink: String
        if let groupId = groupId {
            deepLink = "promptconduit://group/\(groupId.uuidString)?highlight=\(sessionId.uuidString)"
        } else {
            deepLink = "promptconduit://session/\(sessionId.uuidString)"
        }

        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "groupId": groupId?.uuidString ?? "",
            "repoName": repoName,
            "action": "focus_terminal",
            "deepLink": deepLink
        ]

        let request = UNNotificationRequest(
            identifier: "completed-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error sending notification: \(error)")
            }
        }
    }

    /// Remove a pending notification for a session
    func cancelNotification(for sessionId: UUID) {
        let identifiers = [
            "waiting-\(sessionId.uuidString)",
            "completed-\(sessionId.uuidString)"
        ]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Remove all notifications
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .list])
    }

    /// Handle notification action
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Bring app to foreground
        NSApp.activate(ignoringOtherApps: true)

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, ActionIdentifier.openSession:
            // User tapped the notification or "Open Session" action
            handleOpenSession(userInfo: userInfo)

        case ActionIdentifier.dismiss:
            // User dismissed - do nothing
            break

        default:
            break
        }

        completionHandler()
    }

    private func handleOpenSession(userInfo: [AnyHashable: Any]) {
        // Try to use deep link first (preferred method)
        if let deepLinkString = userInfo["deepLink"] as? String,
           let deepLinkURL = URL(string: deepLinkString) {
            NSWorkspace.shared.open(deepLinkURL)
            return
        }

        // Fallback: Try to get session ID
        if let sessionIdString = userInfo["sessionId"] as? String,
           let sessionId = UUID(uuidString: sessionIdString) {
            onFocusSession?(sessionId)
        }

        // Also try group ID if available
        if let groupIdString = userInfo["groupId"] as? String,
           !groupIdString.isEmpty,
           let groupId = UUID(uuidString: groupIdString) {
            onFocusGroup?(groupId)
        }
    }
}
