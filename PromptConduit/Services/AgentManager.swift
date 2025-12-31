import Foundation
import Combine

/// Manages all active agent sessions
class AgentManager: ObservableObject {
    static let shared = AgentManager()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var activeSessionId: UUID?

    // Trigger to force UI updates when session status changes
    @Published private(set) var lastStatusChange: Date = Date()

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables: [UUID: AnyCancellable] = [:]

    private init() {}

    // MARK: - Session Management

    /// Creates and starts a new agent session
    func createSession(prompt: String, workingDirectory: String) -> AgentSession {
        let session = AgentSession(
            prompt: prompt,
            workingDirectory: workingDirectory
        )

        setupSessionObserver(session)
        sessions.append(session)
        activeSessionId = session.id

        // Start the PTY session
        session.start()

        return session
    }

    /// Resumes a session from history
    func resumeSession(from history: SessionHistory, withPrompt prompt: String? = nil) -> AgentSession {
        // Create a session that will resume the previous conversation
        let session = AgentSession(
            prompt: prompt ?? "Continuing previous session...",
            workingDirectory: history.repositoryPath,
            resumeSessionId: history.sessionId
        )

        setupSessionObserver(session)
        sessions.append(session)
        activeSessionId = session.id

        // Start with resume
        session.startResume(originalPrompt: history.prompt)

        return session
    }

    /// Sets up status change observer for a session
    private func setupSessionObserver(_ session: AgentSession) {
        let cancellable = session.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastStatusChange = Date()
                self?.objectWillChange.send()
            }
        sessionCancellables[session.id] = cancellable
    }

    /// Gets a session by ID
    func session(for id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// Gets the currently active session
    var activeSession: AgentSession? {
        guard let id = activeSessionId else { return nil }
        return session(for: id)
    }

    /// Sets the active session
    func setActiveSession(_ session: AgentSession) {
        activeSessionId = session.id
    }

    /// Terminates a specific session
    func terminateSession(_ session: AgentSession) {
        session.stop()
        sessionCancellables.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }

        if activeSessionId == session.id {
            activeSessionId = sessions.first?.id
        }
    }

    /// Terminates all sessions
    func terminateAllSessions() {
        for session in sessions {
            session.stop()
        }
        sessions.removeAll()
        sessionCancellables.removeAll()
        activeSessionId = nil
    }

    // MARK: - Statistics

    var runningCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    var waitingCount: Int {
        sessions.filter { $0.status == .waiting }.count
    }

    var completedCount: Int {
        sessions.filter { $0.status == .completed }.count
    }
}
