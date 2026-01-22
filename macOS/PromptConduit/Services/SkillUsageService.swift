import Foundation
import Combine

/// Skill usage statistics
struct SkillUsageStats: Identifiable {
    var id: String { skillName }
    let skillName: String
    let invocationCount: Int
    let lastUsedAt: Date?

    var formattedLastUsed: String {
        guard let lastUsedAt = lastUsedAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastUsedAt, relativeTo: Date())
    }
}

/// Service for tracking skill (slash command) usage across Claude Code sessions
/// Monitors session files for /skill-name invocations and tracks usage statistics
class SkillUsageService: ObservableObject {

    static let shared = SkillUsageService()

    // MARK: - Published State

    @Published private(set) var usageStats: [SkillUsageStats] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanDate: Date?

    // MARK: - Private Properties

    private var database: TranscriptIndexDatabase?
    private let scanQueue = DispatchQueue(label: "com.promptconduit.skillusage", qos: .utility)

    /// Pattern to match skill invocations (e.g., /skill-name, /my-command)
    private let skillInvocationPattern = try? NSRegularExpression(
        pattern: "^/([a-z][a-z0-9-]*)",
        options: [.anchorsMatchLines]
    )

    /// Set of already processed message IDs to avoid double-counting
    private var processedMessageIds: Set<String> = []

    // MARK: - Initialization

    private init() {
        do {
            database = try TranscriptIndexDatabase()
            loadUsageStats()
        } catch {
            print("SkillUsageService: Failed to initialize database: \(error)")
        }
    }

    // MARK: - Public API

    /// Scan session files for skill invocations
    func scanForUsage() {
        guard !isScanning else { return }

        DispatchQueue.main.async {
            self.isScanning = true
        }

        scanQueue.async { [weak self] in
            self?.performScan()

            DispatchQueue.main.async {
                self?.isScanning = false
                self?.lastScanDate = Date()
                self?.loadUsageStats()
            }
        }
    }

    /// Get usage stats for a specific skill
    func getUsage(for skillName: String) -> SkillUsageStats? {
        return usageStats.first { $0.skillName.lowercased() == skillName.lowercased() }
    }

    /// Get skills sorted by most used
    func getMostUsedSkills(limit: Int = 10) -> [SkillUsageStats] {
        return Array(usageStats.sorted { $0.invocationCount > $1.invocationCount }.prefix(limit))
    }

    /// Get recently used skills
    func getRecentlyUsedSkills(limit: Int = 10) -> [SkillUsageStats] {
        return Array(
            usageStats
                .filter { $0.lastUsedAt != nil }
                .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
                .prefix(limit)
        )
    }

    /// Get skills that haven't been used (for cleanup suggestions)
    func getUnusedSkills(allSkillNames: [String]) -> [String] {
        let usedSkillNames = Set(usageStats.map { $0.skillName.lowercased() })
        return allSkillNames.filter { !usedSkillNames.contains($0.lowercased()) }
    }

    // MARK: - Private Methods

    private func loadUsageStats() {
        guard let database = database else { return }

        let allUsage = database.getAllSkillUsage()
        let stats = allUsage.map { usage in
            SkillUsageStats(
                skillName: usage.skillName,
                invocationCount: usage.invocationCount,
                lastUsedAt: usage.lastUsedAt
            )
        }

        DispatchQueue.main.async {
            self.usageStats = stats
        }
    }

    private func performScan() {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return
        }

        // Find all session files
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return
        }

        for entry in entries {
            let projectDir = projectsDir.appendingPathComponent(entry)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            scanProjectDirectory(projectDir.path)
        }
    }

    private func scanProjectDirectory(_ directory: String) {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            return
        }

        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                let fullPath = directory + "/" + file
                scanSessionFile(fullPath)
            }
        }
    }

    private func scanSessionFile(_ filePath: String) {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty else { continue }

            // Parse JSONL line
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Only look at user messages
            guard let type = json["type"] as? String, type == "user" else {
                continue
            }

            // Get message content
            guard let message = json["message"] as? [String: Any],
                  let messageContent = message["content"] as? String else {
                continue
            }

            // Create unique message ID
            let uuid = json["uuid"] as? String ?? UUID().uuidString
            let messageId = "\(filePath):\(uuid)"

            // Skip if already processed
            guard !processedMessageIds.contains(messageId) else {
                continue
            }

            // Check for skill invocations
            let skillNames = extractSkillInvocations(from: messageContent)

            for skillName in skillNames {
                recordSkillUsage(skillName)
            }

            processedMessageIds.insert(messageId)
        }
    }

    private func extractSkillInvocations(from content: String) -> [String] {
        guard let pattern = skillInvocationPattern else { return [] }

        var skillNames: [String] = []
        let range = NSRange(content.startIndex..., in: content)

        pattern.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
            guard let match = match,
                  let skillRange = Range(match.range(at: 1), in: content) else {
                return
            }

            let skillName = String(content[skillRange])

            // Filter out common non-skill patterns
            let skipPatterns = ["help", "clear", "exit", "quit", "version", "config", "settings"]
            if !skipPatterns.contains(skillName.lowercased()) {
                skillNames.append(skillName)
            }
        }

        return skillNames
    }

    private func recordSkillUsage(_ skillName: String) {
        guard let database = database else { return }

        do {
            try database.recordSkillUsage(skillName: skillName)
        } catch {
            print("SkillUsageService: Failed to record usage for \(skillName): \(error)")
        }
    }
}
