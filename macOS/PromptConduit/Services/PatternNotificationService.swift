import Foundation
import UserNotifications
import AppKit

/// Service for sending proactive macOS notifications when repeated patterns are detected
class PatternNotificationService: NSObject, ObservableObject {

    static let shared = PatternNotificationService()

    // MARK: - Published State

    @Published private(set) var isAuthorized = false
    @Published private(set) var pendingNotification: PatternSuggestion?

    // MARK: - Private Properties

    private let notificationCenter = UNUserNotificationCenter.current()
    private var notificationObserver: Any?

    // Notification action identifiers
    private enum ActionIdentifier {
        static let saveAsSkill = "SAVE_AS_SKILL"
        static let dismiss = "DISMISS"
        static let categoryId = "PATTERN_DETECTED"
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        setupNotificationActions()
        requestAuthorization()
        observePatternReadyNotifications()
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupNotificationActions() {
        // Define actions
        let saveAction = UNNotificationAction(
            identifier: ActionIdentifier.saveAsSkill,
            title: "Save as Skill",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: ActionIdentifier.dismiss,
            title: "Dismiss",
            options: []
        )

        // Create category with actions
        let category = UNNotificationCategory(
            identifier: ActionIdentifier.categoryId,
            actions: [saveAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([category])
        notificationCenter.delegate = self
    }

    private func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }

            if let error = error {
                print("PatternNotificationService: Authorization error: \(error)")
            }
        }
    }

    private func observePatternReadyNotifications() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .patternReadyToSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let suggestion = notification.userInfo?["suggestion"] as? PatternSuggestion else { return }
            self?.handlePatternReady(suggestion)
        }
    }

    // MARK: - Public API

    /// Manually trigger a notification for a pattern suggestion
    func notifyUser(about suggestion: PatternSuggestion) {
        guard isAuthorized else {
            print("PatternNotificationService: Not authorized to send notifications")
            return
        }

        let repeatTracker = RepeatTracker.shared
        guard repeatTracker.canSendNotification else {
            print("PatternNotificationService: Daily notification limit reached")
            return
        }

        sendNotification(for: suggestion)
        repeatTracker.recordNotificationSent()
    }

    /// Request notification permission if not already granted
    func requestPermission(completion: @escaping (Bool) -> Void) {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                completion(granted)
            }
        }
    }

    // MARK: - Private Methods

    private func handlePatternReady(_ suggestion: PatternSuggestion) {
        // Check if we should notify
        let repeatTracker = RepeatTracker.shared
        guard repeatTracker.canSendNotification else {
            print("PatternNotificationService: Skipping notification (daily limit reached)")
            return
        }

        guard isAuthorized else {
            print("PatternNotificationService: Not authorized, storing for later")
            pendingNotification = suggestion
            return
        }

        sendNotification(for: suggestion)
        repeatTracker.recordNotificationSent()
    }

    private func sendNotification(for suggestion: PatternSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Repeated Pattern Detected"
        content.subtitle = "You've asked this \(suggestion.candidate.repeatCount) times"
        content.body = truncateContent(suggestion.candidate.content, maxLength: 100)
        content.sound = .default
        content.categoryIdentifier = ActionIdentifier.categoryId

        // Store candidate ID for action handling
        content.userInfo = [
            "candidateId": suggestion.candidate.id.uuidString,
            "suggestedSkillName": suggestion.suggestedSkillName,
            "suggestedDescription": suggestion.suggestedDescription,
            "suggestedLocation": suggestion.suggestedLocation.rawValue
        ]

        // Create request with unique identifier
        let request = UNNotificationRequest(
            identifier: "pattern-\(suggestion.candidate.id.uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("PatternNotificationService: Failed to send notification: \(error)")
            } else {
                print("PatternNotificationService: Notification sent for pattern \(suggestion.candidate.id)")
            }
        }
    }

    private func truncateContent(_ content: String, maxLength: Int) -> String {
        if content.count <= maxLength {
            return content
        }
        return String(content.prefix(maxLength - 3)) + "..."
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PatternNotificationService: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        guard let candidateIdString = userInfo["candidateId"] as? String,
              let candidateId = UUID(uuidString: candidateIdString) else {
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case ActionIdentifier.saveAsSkill, UNNotificationDefaultActionIdentifier:
            // User wants to save as skill - bring app to front and show save dialog
            handleSaveAsSkill(candidateId: candidateId, userInfo: userInfo)

        case ActionIdentifier.dismiss:
            // User dismissed - mark as dismissed
            RepeatTracker.shared.dismissCandidate(candidateId)

        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }

    private func handleSaveAsSkill(candidateId: UUID, userInfo: [AnyHashable: Any]) {
        // Bring app to foreground
        NSApp.activate(ignoringOtherApps: true)

        // Post notification for UI to handle
        NotificationCenter.default.post(
            name: .showSaveSkillFromPattern,
            object: nil,
            userInfo: [
                "candidateId": candidateId,
                "suggestedSkillName": userInfo["suggestedSkillName"] as? String ?? "",
                "suggestedDescription": userInfo["suggestedDescription"] as? String ?? "",
                "suggestedLocation": userInfo["suggestedLocation"] as? String ?? "Global"
            ]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showSaveSkillFromPattern = Notification.Name("showSaveSkillFromPattern")
}
