import Foundation
import Combine
import AppKit

/// Supported terminal apps for launching Claude Code
enum TerminalApp: String, CaseIterable, Codable, Identifiable {
    case terminal       // macOS Terminal.app
    case iterm2         // iTerm2
    case warp           // Warp
    case kitty          // Kitty
    case alacritty      // Alacritty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        case .kitty: return "Kitty"
        case .alacritty: return "Alacritty"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        }
    }

    /// Returns true if the terminal app is installed on the system
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Returns the first installed terminal app, defaulting to Terminal.app
    static var defaultTerminal: TerminalApp {
        // Terminal.app is always installed on macOS
        .terminal
    }

    /// Returns all installed terminal apps
    static var installedApps: [TerminalApp] {
        allCases.filter { $0.isInstalled }
    }
}

/// Supported code editors for opening projects
enum CodeEditor: String, CaseIterable, Codable, Identifiable {
    case none
    case vscode
    case cursor
    case xcode
    case sublimeText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .xcode: return "Xcode"
        case .sublimeText: return "Sublime Text"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .none: return nil
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .xcode: return "com.apple.dt.Xcode"
        case .sublimeText: return "com.sublimetext.4"
        }
    }

    /// Returns true if the editor is installed on the system
    var isInstalled: Bool {
        guard let bundleId = bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    /// Opens the specified directory in this editor
    func open(directory: String) {
        guard let bundleId = bundleIdentifier else { return }

        let directoryURL = URL(fileURLWithPath: directory)

        NSWorkspace.shared.open(
            [directoryURL],
            withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)!,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error = error {
                print("Failed to open \(self.displayName): \(error)")
            }
        }
    }
}

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
    private static let maxSessionHistory = 50
    private static let maxSessionGroups = 50

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

    @Published var preferredCodeEditor: CodeEditor {
        didSet { save() }
    }

    @Published var preferredTerminalApp: TerminalApp {
        didSet { save() }
    }

    @Published var allAgentsHidden: Bool {
        didSet { save() }
    }

    @Published private(set) var recentRepositories: [RecentRepository] = []
    @Published private(set) var sessionHistory: [SessionHistory] = []
    @Published private(set) var sessionGroups: [SessionGroup] = []

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

        // Load preferred code editor
        if let editorString = defaults.string(forKey: "preferredCodeEditor"),
           let editor = CodeEditor(rawValue: editorString) {
            self.preferredCodeEditor = editor
        } else {
            self.preferredCodeEditor = .none
        }

        // Load preferred terminal app
        if let terminalString = defaults.string(forKey: "preferredTerminalApp"),
           let terminal = TerminalApp(rawValue: terminalString) {
            self.preferredTerminalApp = terminal
        } else {
            self.preferredTerminalApp = .terminal
        }

        // Load agents hidden state
        self.allAgentsHidden = defaults.bool(forKey: "allAgentsHidden")

        // Load recent repositories
        if let data = defaults.data(forKey: "recentRepositories"),
           let repos = try? JSONDecoder().decode([RecentRepository].self, from: data) {
            self.recentRepositories = repos
        }

        // Load session history
        if let data = defaults.data(forKey: "sessionHistory"),
           let history = try? JSONDecoder().decode([SessionHistory].self, from: data) {
            self.sessionHistory = history
        }

        // Load session groups
        if let data = defaults.data(forKey: "sessionGroups"),
           let groups = try? JSONDecoder().decode([SessionGroup].self, from: data) {
            self.sessionGroups = groups
        }
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(defaultProjectsDirectory, forKey: "defaultProjectsDirectory")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(notificationSoundEnabled, forKey: "notificationSoundEnabled")
        defaults.set(globalHotkey, forKey: "globalHotkey")
        defaults.set(preferredCodeEditor.rawValue, forKey: "preferredCodeEditor")
        defaults.set(preferredTerminalApp.rawValue, forKey: "preferredTerminalApp")
        defaults.set(allAgentsHidden, forKey: "allAgentsHidden")
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

    // MARK: - Session History

    private func saveSessionHistory() {
        if let data = try? JSONEncoder().encode(sessionHistory) {
            defaults.set(data, forKey: "sessionHistory")
        }
    }

    /// Saves a completed session to history
    func saveSession(
        sessionId: String,
        repositoryPath: String,
        prompt: String,
        createdAt: Date,
        lastActivity: Date,
        status: SessionHistoryStatus,
        messageCount: Int
    ) {
        // Check if session already exists (update it)
        if let index = sessionHistory.firstIndex(where: { $0.sessionId == sessionId }) {
            sessionHistory[index].lastActivity = lastActivity
            sessionHistory[index].status = status
            sessionHistory[index].messageCount = messageCount
        } else {
            // Add new session at the beginning
            let history = SessionHistory(
                sessionId: sessionId,
                repositoryPath: repositoryPath,
                prompt: prompt,
                createdAt: createdAt,
                lastActivity: lastActivity,
                status: status,
                messageCount: messageCount
            )
            sessionHistory.insert(history, at: 0)

            // Keep only the most recent N sessions
            if sessionHistory.count > Self.maxSessionHistory {
                sessionHistory = Array(sessionHistory.prefix(Self.maxSessionHistory))
            }
        }

        saveSessionHistory()
    }

    /// Gets sessions for a specific repository, sorted by most recent first
    func sessionsForRepository(path: String) -> [SessionHistory] {
        sessionHistory
            .filter { $0.repositoryPath == path }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Gets the most recent session for a repository (if any)
    func mostRecentSession(forRepository path: String) -> SessionHistory? {
        sessionsForRepository(path: path).first
    }

    /// Removes a session from history
    func removeSession(sessionId: String) {
        sessionHistory.removeAll { $0.sessionId == sessionId }
        saveSessionHistory()
    }

    /// Clears all session history
    func clearSessionHistory() {
        sessionHistory.removeAll()
        saveSessionHistory()
    }

    /// Clears session history for a specific repository
    func clearSessionHistory(forRepository path: String) {
        sessionHistory.removeAll { $0.repositoryPath == path }
        saveSessionHistory()
    }

    // MARK: - Session Groups

    private func saveSessionGroups() {
        if let data = try? JSONEncoder().encode(sessionGroups) {
            defaults.set(data, forKey: "sessionGroups")
        }
    }

    /// Saves a new session group
    func saveSessionGroup(_ group: SessionGroup) {
        // Check if already exists (update it)
        if let index = sessionGroups.firstIndex(where: { $0.id == group.id }) {
            sessionGroups[index] = group
        } else {
            // Add new group at the beginning
            sessionGroups.insert(group, at: 0)

            // Keep only the most recent N groups
            if sessionGroups.count > Self.maxSessionGroups {
                sessionGroups = Array(sessionGroups.prefix(Self.maxSessionGroups))
            }
        }

        saveSessionGroups()
    }

    /// Updates an existing session group
    func updateSessionGroup(_ group: SessionGroup) {
        if let index = sessionGroups.firstIndex(where: { $0.id == group.id }) {
            sessionGroups[index] = group
            saveSessionGroups()
        }
    }

    /// Updates a session group by ID with a closure
    func updateSessionGroup(id: UUID, update: (inout SessionGroup) -> Void) {
        if let index = sessionGroups.firstIndex(where: { $0.id == id }) {
            update(&sessionGroups[index])
            saveSessionGroups()
        }
    }

    /// Archives a session group (moves to completed state)
    func archiveSessionGroup(_ id: UUID) {
        if let index = sessionGroups.firstIndex(where: { $0.id == id }) {
            sessionGroups[index].archive()
            saveSessionGroups()
        }
    }

    /// Deletes a session group by ID
    func deleteSessionGroup(_ id: UUID) {
        sessionGroups.removeAll { $0.id == id }
        saveSessionGroups()
    }

    /// Gets a session group by ID
    func sessionGroup(for id: UUID) -> SessionGroup? {
        sessionGroups.first { $0.id == id }
    }

    /// Gets active session groups (not completed or archived)
    func activeSessionGroups() -> [SessionGroup] {
        sessionGroups.filter { $0.isActive }
    }

    /// Gets recent session groups (completed or archived, for history)
    func recentSessionGroups(limit: Int = 10) -> [SessionGroup] {
        sessionGroups
            .filter { !$0.isActive }
            .prefix(limit)
            .map { $0 }
    }

    /// Gets all session groups sorted by last activity
    func allSessionGroupsSortedByActivity() -> [SessionGroup] {
        sessionGroups.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Clears all session groups
    func clearSessionGroups() {
        sessionGroups.removeAll()
        saveSessionGroups()
    }

    /// Clears completed/archived session groups only
    func clearCompletedSessionGroups() {
        sessionGroups.removeAll { !$0.isActive }
        saveSessionGroups()
    }

    /// Archives stale session groups that have no running Claude processes
    /// Call this on app launch to clean up groups left over from previous sessions
    func archiveStaleSessionGroups() {
        let activeGroups = activeSessionGroups()
        guard !activeGroups.isEmpty else { return }

        // Get all running Claude process working directories
        let runningDirectories = getRunningClaudeDirectories()

        var archivedCount = 0
        for group in activeGroups {
            // Check if any of the group's repo paths have a running Claude process
            let hasRunningProcess = group.repoPaths.contains { repoPath in
                runningDirectories.contains(repoPath)
            }

            if !hasRunningProcess {
                archiveSessionGroup(group.id)
                archivedCount += 1
            }
        }

        if archivedCount > 0 {
            print("[SettingsService] Archived \(archivedCount) stale session groups on startup")
        }
    }

    /// Gets working directories of all running Claude processes
    private func getRunningClaudeDirectories() -> Set<String> {
        var directories = Set<String>()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return directories }

            // Find Claude processes
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      (trimmed.contains("/claude ") || trimmed.hasSuffix("/claude")),
                      !trimmed.contains("--chrome-native-host"),
                      !trimmed.contains("--claude-in-chrome-mcp") else { continue }

                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let pidString = components.first,
                      let pid = Int32(pidString) else { continue }

                // Get working directory for this process
                if let cwd = getProcessWorkingDirectory(pid) {
                    directories.insert(cwd)
                }
            }
        } catch {
            // Process lookup failed - return empty set
        }

        return directories
    }

    /// Gets the working directory of a process using lsof
    private func getProcessWorkingDirectory(_ pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-Fn", "-a", "-d", "cwd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return nil }

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n") && line.count > 1 {
                    return String(line.dropFirst())
                }
            }
        } catch {
            // lsof failed
        }

        return nil
    }
}
