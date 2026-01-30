import SwiftUI
import AppKit

// MARK: - Design Tokens

private enum LauncherTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundCard = Color(red: 0.13, green: 0.16, blue: 0.24)
    static let backgroundCardHover = Color(red: 0.16, green: 0.20, blue: 0.28)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let textMuted = Color(red: 0.4, green: 0.45, blue: 0.55)
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)
    static let accentPurple = Color(red: 0.58, green: 0.44, blue: 0.86)
    static let statusRunning = Color(red: 0.62, green: 0.81, blue: 0.42)
    static let borderColor = Color(red: 0.20, green: 0.24, blue: 0.32)
}

/// A simple launcher view that opens Claude Code in native Terminal.app
/// Replaces the embedded terminal approach for reliability
struct SessionGroupLauncherView: View {
    let groupId: UUID
    let repositories: [String]
    let initialPrompt: String?
    let onClose: () -> Void

    @StateObject private var tracker = TerminalSessionTracker.shared
    @State private var launchedRepos: Set<String> = []
    @State private var sessionIds: [String: UUID] = [:]  // repo path -> session ID
    @State private var isLaunchingAll = false
    @State private var broadcastText = ""
    @State private var showBroadcastInput = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with launch all button
            headerBar

            // Broadcast input (when terminals are launched)
            if !launchedRepos.isEmpty {
                broadcastBar
            }

            // Prompt preview if provided
            if let prompt = initialPrompt, !prompt.isEmpty {
                promptPreview(prompt)
            }

            // Repository cards
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(repositories, id: \.self) { repoPath in
                        RepoLaunchCard(
                            repoPath: repoPath,
                            prompt: initialPrompt,
                            isLaunched: launchedRepos.contains(repoPath),
                            sessionId: sessionIds[repoPath],
                            onLaunch: {
                                launchClaude(for: repoPath)
                            },
                            onFocus: {
                                if let sid = sessionIds[repoPath] {
                                    tracker.focusSession(sid)
                                }
                            }
                        )
                    }
                }
                .padding(20)
            }
        }
        .background(LauncherTokens.backgroundPrimary)
    }

    // MARK: - Broadcast Bar

    private var broadcastBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14))
                .foregroundColor(LauncherTokens.accentCyan)

            TextField("Send to all terminals...", text: $broadcastText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(LauncherTokens.textPrimary)
                .onSubmit {
                    sendBroadcast()
                }

            Button(action: sendBroadcast) {
                Text("Send")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(broadcastText.isEmpty ? LauncherTokens.backgroundCard : LauncherTokens.accentCyan)
                    .foregroundColor(broadcastText.isEmpty ? LauncherTokens.textMuted : LauncherTokens.backgroundPrimary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(broadcastText.isEmpty)

            Text("⏎")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(LauncherTokens.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LauncherTokens.accentCyan.opacity(0.1))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(LauncherTokens.borderColor),
            alignment: .bottom
        )
    }

    private func sendBroadcast() {
        guard !broadcastText.isEmpty else { return }

        // Send to all tracked sessions using --resume
        for (repoPath, sessionId) in sessionIds {
            _ = TerminalLauncher.sendFollowUp(
                prompt: broadcastText,
                sessionId: sessionId,
                workingDirectory: repoPath
            )
        }

        broadcastText = ""
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch Claude Code")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LauncherTokens.textPrimary)

                Text("\(repositories.count) repositories")
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.textSecondary)
            }

            Spacer()

            // Launch all button
            Button(action: launchAll) {
                HStack(spacing: 8) {
                    if isLaunchingAll {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "terminal.fill")
                    }
                    Text("Open All in Terminal")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(LauncherTokens.accentCyan)
                .foregroundColor(LauncherTokens.backgroundPrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isLaunchingAll)
        }
        .padding(20)
        .background(Color(red: 0.08, green: 0.11, blue: 0.18))
    }

    // MARK: - Prompt Preview

    private func promptPreview(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.accentPurple)

                Text("Initial Prompt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LauncherTokens.textSecondary)

                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(LauncherTokens.accentCyan)
                }
                .buttonStyle(.plain)
            }

            Text(prompt)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(LauncherTokens.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(LauncherTokens.accentPurple.opacity(0.1))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(LauncherTokens.borderColor),
            alignment: .bottom
        )
    }

    // MARK: - Actions

    private func launchAll() {
        isLaunchingAll = true

        // Calculate optimal column count based on repo count
        let columns: Int
        switch repositories.count {
        case 1: columns = 1
        case 2: columns = 2
        case 3...4: columns = 2
        case 5...6: columns = 3
        case 7...9: columns = 3
        default: columns = 4
        }

        // Launch in a grid layout with window positioning and session tracking
        // Prompt is passed via -p flag directly to Claude
        let newSessionIds = TerminalLauncher.launchClaudeGrid(
            repositories: repositories,
            prompt: initialPrompt,
            columns: columns,
            trackSessions: true
        )

        // Store session IDs and mark as launched
        sessionIds.merge(newSessionIds) { _, new in new }
        for repo in repositories {
            launchedRepos.insert(repo)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(repositories.count) * 0.3 + 0.5) {
            isLaunchingAll = false
        }
    }

    private func launchClaude(for repoPath: String) {
        let sessionId = UUID()
        sessionIds[repoPath] = sessionId
        launchedRepos.insert(repoPath)

        // Prompt is passed via -p flag directly to Claude
        TerminalLauncher.launchClaudeInTerminal(
            workingDirectory: repoPath,
            prompt: initialPrompt,
            sessionId: sessionId
        )
    }
}

// MARK: - Repo Launch Card

struct RepoLaunchCard: View {
    let repoPath: String
    let prompt: String?
    let isLaunched: Bool
    let sessionId: UUID?
    let onLaunch: () -> Void
    let onFocus: () -> Void

    @State private var isHovered = false

    private var repoName: String {
        URL(fileURLWithPath: repoPath).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 16) {
            // Folder icon
            Image(systemName: "folder.fill")
                .font(.system(size: 24))
                .foregroundColor(LauncherTokens.accentCyan)
                .frame(width: 40)

            // Repo info
            VStack(alignment: .leading, spacing: 4) {
                Text(repoName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(LauncherTokens.textPrimary)

                Text(repoPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(LauncherTokens.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Status / Launch button
            if isLaunched {
                HStack(spacing: 8) {
                    // Focus button - brings Terminal window to front
                    Button(action: onFocus) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(LauncherTokens.textSecondary)
                    .help("Bring terminal to front")

                    HStack(spacing: 6) {
                        Circle()
                            .fill(LauncherTokens.statusRunning)
                            .frame(width: 8, height: 8)
                        Text("Running")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(LauncherTokens.statusRunning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LauncherTokens.statusRunning.opacity(0.15))
                    .cornerRadius(6)
                }
            } else {
                Button(action: onLaunch) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("Open")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isHovered ? LauncherTokens.accentCyan : LauncherTokens.backgroundCardHover)
                    .foregroundColor(isHovered ? LauncherTokens.backgroundPrimary : LauncherTokens.textPrimary)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovered = hovering
                }
            }
        }
        .padding(16)
        .background(LauncherTokens.backgroundCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isLaunched ? LauncherTokens.statusRunning.opacity(0.3) : LauncherTokens.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Window Frame

struct TerminalWindowFrame {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

// MARK: - Terminal Session Tracker

/// Tracks launched Terminal windows so we can send commands to them later
class TerminalSessionTracker: ObservableObject {
    static let shared = TerminalSessionTracker()

    /// Maps our session ID to Terminal window ID
    @Published private(set) var windowIds: [UUID: Int] = [:]

    /// Maps our session ID to Claude's session ID (for --resume)
    @Published private(set) var claudeSessionIds: [UUID: String] = [:]

    /// Maps session ID to repo path
    private var sessionRepos: [UUID: String] = [:]

    private init() {}

    /// Register a launched terminal session
    func registerSession(id: UUID, repoPath: String, windowId: Int) {
        DispatchQueue.main.async {
            self.windowIds[id] = windowId
            self.sessionRepos[id] = repoPath
        }
    }

    /// Register Claude's session ID for a session (for --resume)
    func registerClaudeSessionId(id: UUID, claudeSessionId: String) {
        DispatchQueue.main.async {
            self.claudeSessionIds[id] = claudeSessionId
        }
    }

    /// Get Claude's session ID for resuming
    func getClaudeSessionId(for id: UUID) -> String? {
        return claudeSessionIds[id]
    }

    /// Send text to a specific terminal session
    func sendText(_ text: String, to sessionId: UUID) -> Bool {
        guard let windowId = windowIds[sessionId] else {
            print("[TerminalSessionTracker] No window ID for session \(sessionId)")
            return false
        }

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            set targetWindow to window id \(windowId)
            do script "\(escapedText)" in targetWindow
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[TerminalSessionTracker] Error sending text: \(error)")
                return false
            }
            return true
        }
        return false
    }

    /// Send a keystroke to a specific terminal (useful for Enter, Ctrl+C, etc.)
    func sendKeystroke(_ key: String, modifiers: [String] = [], to sessionId: UUID) -> Bool {
        guard let windowId = windowIds[sessionId] else { return false }

        var modifierClause = ""
        if !modifiers.isEmpty {
            modifierClause = " using {\(modifiers.joined(separator: ", "))}"
        }

        let script = """
        tell application "Terminal"
            set frontmost to true
            set index of window id \(windowId) to 1
        end tell
        delay 0.1
        tell application "System Events"
            keystroke "\(key)"\(modifierClause)
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[TerminalSessionTracker] Error sending keystroke: \(error)")
                return false
            }
            return true
        }
        return false
    }

    /// Bring a terminal window to front
    func focusSession(_ sessionId: UUID) -> Bool {
        guard let windowId = windowIds[sessionId] else { return false }

        let script = """
        tell application "Terminal"
            activate
            set index of window id \(windowId) to 1
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    /// Close a terminal session
    func closeSession(_ sessionId: UUID) {
        guard let windowId = windowIds[sessionId] else { return }

        let script = """
        tell application "Terminal"
            close window id \(windowId)
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }

        DispatchQueue.main.async {
            self.windowIds.removeValue(forKey: sessionId)
            self.sessionRepos.removeValue(forKey: sessionId)
        }
    }

    /// Remove a session (when window is closed externally)
    func removeSession(_ sessionId: UUID) {
        DispatchQueue.main.async {
            self.windowIds.removeValue(forKey: sessionId)
            self.sessionRepos.removeValue(forKey: sessionId)
        }
    }

    /// Get all active session IDs
    var activeSessions: [UUID] {
        Array(windowIds.keys)
    }
}

// MARK: - Terminal Launcher

/// Configuration for launching Claude
struct ClaudeLaunchConfig {
    var allowedTools: [String] = ["Read", "Edit", "Bash", "Write", "Glob", "Grep"]
    var systemPromptAppend: String? = nil
    var outputFormat: OutputFormat = .json

    enum OutputFormat: String {
        case text = "text"
        case json = "json"
        case streamJson = "stream-json"
    }

    /// Default config for most use cases
    static let `default` = ClaudeLaunchConfig()

    /// Config for read-only analysis (safer)
    static let readOnly = ClaudeLaunchConfig(allowedTools: ["Read", "Glob", "Grep"])
}

enum TerminalLauncher {
    /// Launches Claude Code in Terminal.app with optional window positioning
    /// Returns the session ID if tracking is enabled
    @discardableResult
    static func launchClaudeInTerminal(
        workingDirectory: String,
        prompt: String? = nil,
        windowFrame: TerminalWindowFrame? = nil,
        sessionId: UUID? = nil,
        config: ClaudeLaunchConfig = .default
    ) -> UUID? {
        // Find the claude executable
        let claudePath = findClaudeExecutable()

        // Create a unique output file to capture Claude's session ID
        let outputFile = sessionId.map { "/tmp/claude-session-\($0.uuidString).json" }

        // Build the command to run in Terminal
        var command = "cd \"\(workingDirectory)\" && \"\(claudePath)\""

        if let prompt = prompt, !prompt.isEmpty {
            // Escape the prompt for shell (handle newlines, quotes, etc.)
            let escapedPrompt = escapeForShell(prompt)

            // Use -p flag for programmatic mode
            command += " -p \(escapedPrompt)"

            // Use --allowedTools instead of --dangerously-skip-permissions (more secure)
            let toolsArg = config.allowedTools.joined(separator: ",")
            command += " --allowedTools \"\(toolsArg)\""

            // Add custom system prompt if provided
            if let systemPrompt = config.systemPromptAppend {
                let escapedSystemPrompt = escapeForShell(systemPrompt)
                command += " --append-system-prompt \(escapedSystemPrompt)"
            }

            // Output format for structured response
            command += " --output-format \(config.outputFormat.rawValue)"

            // Capture output to file so we can extract session_id
            if let outFile = outputFile {
                command += " | tee \"\(outFile)\""
            }
        } else {
            // Interactive mode without prompt - still use allowedTools for safety
            let toolsArg = config.allowedTools.joined(separator: ",")
            command += " --allowedTools \"\(toolsArg)\""
        }

        // Build AppleScript that returns window ID for tracking
        let script: String
        if let frame = windowFrame {
            script = """
            tell application "Terminal"
                activate
                do script "\(escapeForAppleScript(command))"
                set theWindow to front window
                set bounds of theWindow to {\(frame.x), \(frame.y), \(frame.x + frame.width), \(frame.y + frame.height)}
                return id of theWindow
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(escapeForAppleScript(command))"
                return id of front window
            end tell
            """
        }

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)

            if let error = error {
                print("[TerminalLauncher] AppleScript error: \(error)")
                return nil
            }

            // If we have a session ID, register the window for tracking
            if let sid = sessionId {
                let windowId = Int(result.int32Value)
                if windowId > 0 {
                    TerminalSessionTracker.shared.registerSession(
                        id: sid,
                        repoPath: workingDirectory,
                        windowId: windowId
                    )

                    // Schedule parsing of Claude's session ID from output file
                    if let outFile = outputFile {
                        parseClaudeSessionId(from: outFile, for: sid)
                    }

                    return sid
                }
            }
        }

        return sessionId
    }

    /// Parse Claude's session ID from the JSON output file
    private static func parseClaudeSessionId(from filePath: String, for sessionId: UUID) {
        // Wait for Claude to finish and write output (poll for file)
        DispatchQueue.global(qos: .background).async {
            var attempts = 0
            let maxAttempts = 120  // Wait up to 2 minutes for long-running tasks

            defer {
                // Always clean up temp file, even on failure
                try? FileManager.default.removeItem(atPath: filePath)
            }

            while attempts < maxAttempts {
                attempts += 1
                Thread.sleep(forTimeInterval: 1.0)

                // Check if file exists and has content
                guard let data = FileManager.default.contents(atPath: filePath),
                      let content = String(data: data, encoding: .utf8),
                      !content.isEmpty else {
                    continue
                }

                // Try to parse JSON and extract session_id
                if let jsonData = content.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                    // Check for errors in the response
                    if let isError = json["is_error"] as? Bool, isError {
                        let errorMsg = json["result"] as? String ?? "Unknown error"
                        print("[TerminalLauncher] Claude returned error: \(errorMsg)")
                    }

                    // Extract session_id
                    if let claudeSessionId = json["session_id"] as? String {
                        DispatchQueue.main.async {
                            TerminalSessionTracker.shared.registerClaudeSessionId(
                                id: sessionId,
                                claudeSessionId: claudeSessionId
                            )
                            print("[TerminalLauncher] Captured Claude session ID: \(claudeSessionId)")
                        }
                        return
                    }
                }
            }

            print("[TerminalLauncher] Failed to capture Claude session ID after \(maxAttempts) seconds")
        }
    }

    /// Send a follow-up prompt to a Claude session using --resume
    static func sendFollowUp(
        prompt: String,
        sessionId: UUID,
        workingDirectory: String,
        config: ClaudeLaunchConfig = .default
    ) -> Bool {
        guard let claudeSessionId = TerminalSessionTracker.shared.getClaudeSessionId(for: sessionId) else {
            print("[TerminalLauncher] No Claude session ID for \(sessionId), falling back to --continue")
            // Fallback: use --continue for most recent session in that directory
            return sendFollowUpWithContinue(prompt: prompt, sessionId: sessionId, workingDirectory: workingDirectory, config: config)
        }

        guard let windowId = TerminalSessionTracker.shared.windowIds[sessionId] else {
            print("[TerminalLauncher] No window ID for \(sessionId)")
            return false
        }

        let claudePath = findClaudeExecutable()
        let escapedPrompt = escapeForShell(prompt)
        let toolsArg = config.allowedTools.joined(separator: ",")

        // Use --resume with Claude's session ID
        let command = "cd \"\(workingDirectory)\" && \"\(claudePath)\" -p \(escapedPrompt) --resume \"\(claudeSessionId)\" --allowedTools \"\(toolsArg)\" --output-format json"

        let script = """
        tell application "Terminal"
            do script "\(escapeForAppleScript(command))" in window id \(windowId)
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[TerminalLauncher] Error sending follow-up: \(error)")
                return false
            }
            return true
        }
        return false
    }

    /// Fallback: send follow-up using --continue (continues most recent session)
    private static func sendFollowUpWithContinue(
        prompt: String,
        sessionId: UUID,
        workingDirectory: String,
        config: ClaudeLaunchConfig
    ) -> Bool {
        guard let windowId = TerminalSessionTracker.shared.windowIds[sessionId] else {
            print("[TerminalLauncher] No window ID for \(sessionId)")
            return false
        }

        let claudePath = findClaudeExecutable()
        let escapedPrompt = escapeForShell(prompt)
        let toolsArg = config.allowedTools.joined(separator: ",")

        // Use --continue for most recent session
        let command = "cd \"\(workingDirectory)\" && \"\(claudePath)\" -p \(escapedPrompt) --continue --allowedTools \"\(toolsArg)\" --output-format json"

        let script = """
        tell application "Terminal"
            do script "\(escapeForAppleScript(command))" in window id \(windowId)
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[TerminalLauncher] Error sending follow-up with --continue: \(error)")
                return false
            }
            return true
        }
        return false
    }

    /// Launches multiple Terminal windows in a grid layout
    /// Returns a dictionary mapping repo paths to session IDs
    @discardableResult
    static func launchClaudeGrid(
        repositories: [String],
        prompt: String? = nil,
        columns: Int = 2,
        trackSessions: Bool = true
    ) -> [String: UUID] {
        var sessionMap: [String: UUID] = [:]

        // Get screen size
        guard let screen = NSScreen.main else {
            // Fallback: launch without positioning
            for repo in repositories {
                let sessionId = trackSessions ? UUID() : nil
                launchClaudeInTerminal(workingDirectory: repo, prompt: prompt, sessionId: sessionId)
                if let sid = sessionId {
                    sessionMap[repo] = sid
                }
            }
            return sessionMap
        }

        let screenFrame = screen.visibleFrame
        let rows = Int(ceil(Double(repositories.count) / Double(columns)))

        // Calculate window dimensions
        let windowWidth = Int(screenFrame.width) / columns
        let windowHeight = Int(screenFrame.height) / rows

        // Pre-generate session IDs
        if trackSessions {
            for repo in repositories {
                sessionMap[repo] = UUID()
            }
        }

        // Launch each terminal with calculated position
        // Prompt is passed via -p flag to each Claude instance
        for (index, repoPath) in repositories.enumerated() {
            let col = index % columns
            let row = index / columns

            // Calculate position (y is from bottom on macOS)
            let x = Int(screenFrame.minX) + (col * windowWidth)
            let y = Int(screenFrame.minY) + ((rows - 1 - row) * windowHeight)

            let frame = TerminalWindowFrame(
                x: x,
                y: y,
                width: windowWidth,
                height: windowHeight
            )

            let sessionId = sessionMap[repoPath]

            // Small delay between launches to avoid race conditions
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                launchClaudeInTerminal(
                    workingDirectory: repoPath,
                    prompt: prompt,  // Pass prompt via -p flag
                    windowFrame: frame,
                    sessionId: sessionId
                )
            }
        }

        return sessionMap
    }

    /// Opens a folder in Finder
    static func openInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: - Private

    private static func findClaudeExecutable() -> String {
        let possiblePaths = [
            "/opt/homebrew/bin/claude",      // Apple Silicon Homebrew
            "/usr/local/bin/claude",          // Intel Homebrew
            "\(NSHomeDirectory())/.local/bin/claude", // npm global install
            "/usr/bin/claude"                 // System install
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback to just "claude" and let PATH resolve it
        return "claude"
    }

    private static func escapeForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escape a string for use in shell command (handles newlines, quotes, etc.)
    private static func escapeForShell(_ string: String) -> String {
        // Use $'...' syntax which handles escape sequences properly
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "$'\(escaped)'"
    }

    /// Clean up any orphaned temp files from previous sessions
    static func cleanupTempFiles() {
        let tempDir = "/tmp"
        let fileManager = FileManager.default

        do {
            let files = try fileManager.contentsOfDirectory(atPath: tempDir)
            for file in files where file.hasPrefix("claude-session-") && file.hasSuffix(".json") {
                let filePath = "\(tempDir)/\(file)"
                try? fileManager.removeItem(atPath: filePath)
            }
        } catch {
            print("[TerminalLauncher] Error cleaning temp files: \(error)")
        }
    }
}

// MARK: - Preview

#Preview("Launcher View") {
    SessionGroupLauncherView(
        groupId: UUID(),
        repositories: [
            "/Users/test/Documents/project-alpha",
            "/Users/test/Documents/project-beta",
            "/Users/test/Documents/project-gamma"
        ],
        initialPrompt: "Please review the code and suggest improvements",
        onClose: {}
    )
    .frame(width: 800, height: 600)
}

#Preview("Repo Card") {
    VStack(spacing: 12) {
        RepoLaunchCard(
            repoPath: "/Users/test/Documents/my-project",
            prompt: nil,
            isLaunched: false,
            sessionId: nil,
            onLaunch: {},
            onFocus: {}
        )
        RepoLaunchCard(
            repoPath: "/Users/test/Documents/another-project",
            prompt: nil,
            isLaunched: true,
            sessionId: UUID(),
            onLaunch: {},
            onFocus: {}
        )
    }
    .padding()
    .background(Color(red: 0.06, green: 0.09, blue: 0.16))
}
