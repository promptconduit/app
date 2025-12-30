import Foundation
import Combine

/// Manages app settings and user preferences
class SettingsService: ObservableObject {
    static let shared = SettingsService()

    // MARK: - Published Settings

    @Published var defaultProjectsDirectory: String {
        didSet { save() }
    }

    @Published var launchAtLogin: Bool {
        didSet { save() }
    }

    @Published var showInMenuBar: Bool {
        didSet { save() }
    }

    @Published var notificationSoundEnabled: Bool {
        didSet { save() }
    }

    @Published var globalHotkey: String {
        didSet { save() }
    }

    // MARK: - Paths

    /// Claude settings directory
    static var claudeSettingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .path
    }

    /// Claude commands directory
    static var claudeCommandsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands")
            .path
    }

    /// Claude settings.json file
    static var claudeSettingsFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
            .path
    }

    // MARK: - Init

    private let defaults = UserDefaults.standard

    private init() {
        // Load settings from UserDefaults
        self.defaultProjectsDirectory = defaults.string(forKey: "defaultProjectsDirectory")
            ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents/GitHub"

        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        self.notificationSoundEnabled = defaults.object(forKey: "notificationSoundEnabled") as? Bool ?? true
        self.globalHotkey = defaults.string(forKey: "globalHotkey") ?? "⌘⇧A"
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(defaultProjectsDirectory, forKey: "defaultProjectsDirectory")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(notificationSoundEnabled, forKey: "notificationSoundEnabled")
        defaults.set(globalHotkey, forKey: "globalHotkey")
    }

    // MARK: - Directory Validation

    func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func createDirectoryIfNeeded(_ path: String) throws {
        if !directoryExists(path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}
