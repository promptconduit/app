import Foundation
import Combine

/// Represents an active Claude Code agent session
class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let prompt: String
    let workingDirectory: String
    let createdAt: Date
    let resumeSessionId: String?

    @Published private(set) var status: AgentStatus = .idle {
        didSet {
            if status == .completed || status == .failed {
                saveToHistory()
            }
            // Process queued messages when Claude becomes ready
            if status == .completed && !messageQueue.isEmpty {
                processNextQueuedMessage()
            }
        }
    }
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var lastActivity: Date
    @Published private(set) var claudeSessionId: String?
    @Published private(set) var messageQueue: [String] = []

    private var ptySession: PTYSession?
    private var cancellables = Set<AnyCancellable>()
    private var jsonBuffer = ""
    private var outputDebouncer: AnyCancellable?
    private var accumulatedRawOutput = ""
    private var originalPromptForResume: String?

    init(id: UUID = UUID(), prompt: String, workingDirectory: String, resumeSessionId: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.createdAt = Date()
        self.lastActivity = Date()
        self.resumeSessionId = resumeSessionId

        // If resuming, set the claude session ID immediately
        if let resumeId = resumeSessionId {
            self.claudeSessionId = resumeId
        }
    }

    // MARK: - Computed Properties

    var repoName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    /// The GitHub URL for the repository, if available
    var gitHubURL: URL? {
        GitService.shared.getGitHubURL(for: workingDirectory)
    }

    var shortPrompt: String {
        if prompt.count > 50 {
            return String(prompt.prefix(47)) + "..."
        }
        return prompt
    }

    var rawOutput: String {
        accumulatedRawOutput + (ptySession?.output ?? "")
    }

    // MARK: - Session Control

    func start() {
        guard status == .idle else { return }

        setupPTYSession()

        do {
            // Add user prompt to transcript
            addEntry(.user(prompt))

            // Run claude in print mode with the prompt
            try ptySession?.runPrompt(prompt)
            status = .running
        } catch {
            status = .failed
            addEntry(.system("Failed to start: \(error.localizedDescription)"))
        }
    }

    /// Starts a resumed session from history
    func startResume(originalPrompt: String) {
        guard status == .idle else { return }
        guard let resumeId = resumeSessionId else {
            addEntry(.system("No session ID to resume"))
            status = .failed
            return
        }

        self.originalPromptForResume = originalPrompt

        setupPTYSession()

        // Set the session ID for resume
        ptySession?.setSessionId(resumeId)

        do {
            // Add a system message indicating we're resuming
            addEntry(.system("Resuming previous session..."))
            addEntry(.assistant("(Previous context: \(originalPrompt.prefix(100))\(originalPrompt.count > 100 ? "..." : ""))"))

            // Use --continue to just continue the session
            try ptySession?.runResume()
            status = .running
        } catch {
            status = .failed
            addEntry(.system("Failed to resume: \(error.localizedDescription)"))
        }
    }

    private func setupPTYSession() {
        ptySession = PTYSession(workingDirectory: workingDirectory)

        // Subscribe to output changes with throttling to prevent UI flooding
        ptySession?.$output
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] output in
                self?.processOutput(output)
            }
            .store(in: &cancellables)

        // Subscribe to running state
        ptySession?.$isRunning
            .receive(on: DispatchQueue.main)
            .dropFirst() // Skip initial value
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self = self else { return }
                if !isRunning && (self.status == .running || self.status == .waiting) {
                    self.status = .completed
                }
            }
            .store(in: &cancellables)
    }

    func sendPrompt(_ text: String) {
        guard status == .completed || status == .waiting else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let sessionId = claudeSessionId else {
            addEntry(.system("No session ID available for continuation. Please start a new session."))
            return
        }

        // Preserve raw output from previous session
        accumulatedRawOutput += ptySession?.output ?? ""
        accumulatedRawOutput += "\n\n--- Continuation ---\n\n"

        // Reset processing state
        lastProcessedLength = 0
        jsonBuffer = ""

        // Terminate previous PTY
        ptySession?.terminate()
        cancellables.removeAll()

        // Create new PTY session for follow-up
        ptySession = PTYSession(workingDirectory: workingDirectory)
        ptySession?.setSessionId(sessionId)

        // Subscribe to output changes with throttling
        ptySession?.$output
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] output in
                self?.processOutput(output)
            }
            .store(in: &cancellables)

        // Subscribe to running state
        ptySession?.$isRunning
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self = self else { return }
                if !isRunning && (self.status == .running || self.status == .waiting) {
                    self.status = .completed
                }
            }
            .store(in: &cancellables)

        do {
            addEntry(.user(text))
            try ptySession?.runPrompt(text)
            status = .running
            lastActivity = Date()
        } catch {
            addEntry(.system("Failed to continue: \(error.localizedDescription)"))
            status = .failed
        }
    }

    func stop() {
        ptySession?.terminate()
        status = .completed
    }

    func interrupt() {
        ptySession?.interrupt()
    }

    /// Interrupts the current response and sends a new prompt
    func interruptAndSend(_ text: String) {
        guard status == .running else {
            // If not running, just send normally
            sendPrompt(text)
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Add a system message indicating interruption
        addEntry(.system("Interrupted by user"))

        // Interrupt the current process
        ptySession?.interrupt()

        // Wait briefly for the interrupt to take effect, then send the new prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            // The process should have stopped or be stopping
            // Now send the follow-up prompt
            self.sendPrompt(text)
        }
    }

    // MARK: - Message Queue

    /// Queues a message to be sent when Claude finishes the current response
    func queueMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messageQueue.append(trimmed)
        addEntry(.system("Message queued (\(messageQueue.count) in queue)"))
    }

    /// Removes a message from the queue at the specified index
    func removeQueuedMessage(at index: Int) {
        guard index >= 0 && index < messageQueue.count else { return }
        messageQueue.remove(at: index)
    }

    /// Clears all queued messages
    func clearQueue() {
        if !messageQueue.isEmpty {
            messageQueue.removeAll()
            addEntry(.system("Queue cleared"))
        }
    }

    /// Processes the next message in the queue
    private func processNextQueuedMessage() {
        guard !messageQueue.isEmpty else { return }

        let nextMessage = messageQueue.removeFirst()
        addEntry(.system("Sending queued message (\(messageQueue.count) remaining)"))

        // Small delay to ensure status change has propagated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendPrompt(nextMessage)
        }
    }

    // MARK: - Output Processing

    private var lastProcessedLength = 0

    private func processOutput(_ output: String) {
        guard output.count > lastProcessedLength else { return }

        let newContent = String(output.suffix(output.count - lastProcessedLength))
        lastProcessedLength = output.count
        lastActivity = Date()

        // Append to JSON buffer and process line by line
        jsonBuffer += newContent

        // Process complete JSON lines
        while let newlineRange = jsonBuffer.range(of: "\n") {
            let line = String(jsonBuffer[..<newlineRange.lowerBound])
            jsonBuffer = String(jsonBuffer[newlineRange.upperBound...])

            processJSONLine(line)
        }
    }

    private func processJSONLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Try to parse as JSON
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not valid JSON - might be plain text output, add as assistant message
            if !trimmed.isEmpty {
                appendAssistantMessage(trimmed)
            }
            return
        }

        // Handle different message types from streaming JSON
        guard let type = json["type"] as? String else { return }

        switch type {
        case "system":
            // Extract session_id from init message
            if let subtype = json["subtype"] as? String, subtype == "init" {
                if let sessionId = json["session_id"] as? String {
                    self.claudeSessionId = sessionId
                }
            }

        case "assistant":
            // Handle assistant messages
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let blockType = block["type"] as? String {
                        if blockType == "text", let text = block["text"] as? String {
                            appendAssistantMessage(text)
                        } else if blockType == "tool_use" {
                            let toolName = block["name"] as? String ?? "tool"
                            let input = block["input"] as? [String: Any]
                            let target = describeToolInput(toolName: toolName, input: input)
                            addEntry(.tool(toolName, target))
                        }
                    }
                }
            }

        case "user":
            // User messages (including tool results) - we already log our own user messages
            break

        case "result":
            // Session complete
            if let subtype = json["subtype"] as? String {
                if subtype == "success" {
                    // Extract final session_id if present
                    if let sessionId = json["session_id"] as? String {
                        self.claudeSessionId = sessionId
                    }
                } else if subtype == "error" {
                    let errorMsg = json["error"] as? String ?? "Unknown error"
                    addEntry(.system("Error: \(errorMsg)"))
                }
            }

        default:
            break
        }
    }

    private func describeToolInput(toolName: String, input: [String: Any]?) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read":
            return input["file_path"] as? String ?? ""
        case "Edit", "Write":
            return input["file_path"] as? String ?? ""
        case "Bash":
            return input["command"] as? String ?? ""
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        default:
            return ""
        }
    }

    private func appendAssistantMessage(_ text: String) {
        // Merge with last assistant entry if applicable
        if case .assistant = transcript.last?.type {
            let lastIndex = transcript.count - 1
            transcript[lastIndex] = TranscriptEntry(
                type: .assistant(transcript[lastIndex].content + "\n" + text)
            )
        } else {
            addEntry(.assistant(text))
        }
    }

    private func addEntry(_ type: TranscriptEntry.EntryType) {
        transcript.append(TranscriptEntry(type: type))
    }

    // MARK: - History Persistence

    private func saveToHistory() {
        guard let sessionId = claudeSessionId else { return }

        let historyStatus: SessionHistoryStatus
        switch status {
        case .completed: historyStatus = .completed
        case .failed: historyStatus = .failed
        default: historyStatus = .interrupted
        }

        // Use the original prompt for resumed sessions, otherwise use the current prompt
        let promptToSave = originalPromptForResume ?? prompt

        SettingsService.shared.saveSession(
            sessionId: sessionId,
            repositoryPath: workingDirectory,
            prompt: promptToSave,
            createdAt: createdAt,
            lastActivity: lastActivity,
            status: historyStatus,
            messageCount: transcript.count
        )
    }
}

// MARK: - Supporting Types

enum AgentStatus: String {
    case idle = "Idle"
    case running = "Running"
    case waiting = "Waiting for input"
    case completed = "Completed"
    case failed = "Failed"

    var emoji: String {
        switch self {
        case .idle: return "⚪"
        case .running: return "🟢"
        case .waiting: return "🟡"
        case .completed: return "🔴"
        case .failed: return "❌"
        }
    }
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let type: EntryType
    let timestamp: Date

    init(type: EntryType) {
        self.type = type
        self.timestamp = Date()
    }

    var content: String {
        switch type {
        case .user(let text): return text
        case .assistant(let text): return text
        case .tool(let name, let target): return "[\(name)] \(target)"
        case .system(let message): return message
        }
    }

    enum EntryType {
        case user(String)
        case assistant(String)
        case tool(String, String)
        case system(String)
    }
}
