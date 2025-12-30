import Foundation
import Combine

/// Represents a recently used repository
struct RecentRepository: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    var lastUsed: Date

    init(path: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.lastUsed = Date()
    }
}

/// Manages app settings and user preferences
class SettingsService: ObservableObject {
    static let shared = SettingsService()

    private static let maxRecentRepos = 10

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

    @Published private(set) var recentRepositories: [RecentRepository] = []

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

        // Load recent repositories
        if let data = defaults.data(forKey: "recentRepositories"),
           let repos = try? JSONDecoder().decode([RecentRepository].self, from: data) {
            self.recentRepositories = repos
        }
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(defaultProjectsDirectory, forKey: "defaultProjectsDirectory")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(notificationSoundEnabled, forKey: "notificationSoundEnabled")
        defaults.set(globalHotkey, forKey: "globalHotkey")
    }

    private func saveRecentRepositories() {
        if let data = try? JSONEncoder().encode(recentRepositories) {
            defaults.set(data, forKey: "recentRepositories")
        }
    }

    // MARK: - Recent Repositories

    /// Adds a repository to the recent list (or updates its last used time if already present)
    func addRecentRepository(path: String) {
        // Check if already exists
        if let index = recentRepositories.firstIndex(where: { $0.path == path }) {
            // Update last used time and move to top
            var repo = recentRepositories.remove(at: index)
            repo.lastUsed = Date()
            recentRepositories.insert(repo, at: 0)
        } else {
            // Add new repo at top
            let repo = RecentRepository(path: path)
            recentRepositories.insert(repo, at: 0)

            // Keep only the most recent N repos
            if recentRepositories.count > Self.maxRecentRepos {
                recentRepositories = Array(recentRepositories.prefix(Self.maxRecentRepos))
            }
        }

        saveRecentRepositories()
    }

    /// Removes a repository from the recent list
    func removeRecentRepository(path: String) {
        recentRepositories.removeAll { $0.path == path }
        saveRecentRepositories()
    }

    /// Clears all recent repositories
    func clearRecentRepositories() {
        recentRepositories.removeAll()
        saveRecentRepositories()
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
