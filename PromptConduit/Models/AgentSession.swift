import Foundation
import Combine

/// Represents an active Claude Code agent session
class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let prompt: String
    let workingDirectory: String
    let createdAt: Date

    @Published private(set) var status: AgentStatus = .idle
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var lastActivity: Date

    private var ptySession: PTYSession?
    private var cancellables = Set<AnyCancellable>()

    init(id: UUID = UUID(), prompt: String, workingDirectory: String) {
        self.id = id
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.createdAt = Date()
        self.lastActivity = Date()
    }

    // MARK: - Computed Properties

    var repoName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    var shortPrompt: String {
        if prompt.count > 50 {
            return String(prompt.prefix(47)) + "..."
        }
        return prompt
    }

    var rawOutput: String {
        ptySession?.output ?? ""
    }

    // MARK: - Session Control

    func start() {
        guard status == .idle else { return }

        ptySession = PTYSession(workingDirectory: workingDirectory)

        // Subscribe to output changes
        ptySession?.$output
            .receive(on: DispatchQueue.main)
            .sink { [weak self] output in
                self?.processOutput(output)
            }
            .store(in: &cancellables)

        // Subscribe to running state
        ptySession?.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                if !isRunning && self?.status == .running {
                    self?.status = .completed
                }
            }
            .store(in: &cancellables)

        do {
            try ptySession?.spawn()
            status = .running

            // Wait a moment for Claude to initialize, then send the prompt
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendPrompt(self?.prompt ?? "")
            }
        } catch {
            status = .failed
            addEntry(.system("Failed to start: \(error.localizedDescription)"))
        }
    }

    func sendPrompt(_ text: String) {
        guard status == .running || status == .waiting else { return }

        addEntry(.user(text))
        ptySession?.sendLine(text)
        status = .running
        lastActivity = Date()
    }

    func stop() {
        ptySession?.terminate()
        status = .completed
    }

    func interrupt() {
        ptySession?.interrupt()
    }

    // MARK: - Output Processing

    private var lastProcessedLength = 0

    private func processOutput(_ output: String) {
        guard output.count > lastProcessedLength else { return }

        let newContent = String(output.suffix(output.count - lastProcessedLength))
        lastProcessedLength = output.count

        lastActivity = Date()

        // Check for status changes
        if OutputParser.isWaitingForInput(newContent) {
            status = .waiting
        }

        // Detect tool usage
        if let toolUse = OutputParser.detectToolUse(newContent) {
            addEntry(.tool(toolUse.name, toolUse.target))
        }

        // Add assistant response
        let cleanContent = OutputParser.stripANSI(newContent)
        if !cleanContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Merge with last assistant entry if applicable
            if case .assistant = transcript.last?.type {
                let lastIndex = transcript.count - 1
                transcript[lastIndex] = TranscriptEntry(
                    type: .assistant(transcript[lastIndex].content + cleanContent)
                )
            } else {
                addEntry(.assistant(cleanContent))
            }
        }
    }

    private func addEntry(_ type: TranscriptEntry.EntryType) {
        transcript.append(TranscriptEntry(type: type))
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
