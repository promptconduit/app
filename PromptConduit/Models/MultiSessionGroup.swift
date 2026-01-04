import Foundation
import SwiftTerm

/// Tracks a group of terminal sessions launched together
class MultiSessionGroup: ObservableObject, Identifiable {
    let id: UUID
    let layout: GridLayout
    let createdAt: Date

    @Published var sessions: [MultiSessionEntry]
    @Published var broadcastEnabled: Bool = false

    /// Number of sessions currently running
    var runningCount: Int {
        sessions.filter { $0.isRunning }.count
    }

    /// Number of sessions waiting for input
    var waitingCount: Int {
        sessions.filter { $0.isWaiting }.count
    }

    /// All sessions have terminated
    var allTerminated: Bool {
        sessions.allSatisfy { !$0.isRunning }
    }

    init(
        id: UUID = UUID(),
        layout: GridLayout,
        repositories: [String]
    ) {
        self.id = id
        self.layout = layout
        self.createdAt = Date()
        self.sessions = repositories.map { path in
            MultiSessionEntry(
                id: UUID(),
                repositoryPath: path,
                repoName: URL(fileURLWithPath: path).lastPathComponent
            )
        }
    }

    /// Find a session by ID
    func session(for id: UUID) -> MultiSessionEntry? {
        sessions.first { $0.id == id }
    }

    /// Update a session's terminal view reference
    func setTerminalView(_ view: LocalProcessTerminalView?, for sessionId: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].terminalView = view
        }
    }

    /// Update a session's waiting state
    func setWaiting(_ isWaiting: Bool, for sessionId: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].isWaiting = isWaiting
        }
    }

    /// Mark a session as terminated
    func markTerminated(sessionId: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].isRunning = false
            sessions[index].isWaiting = false
        }
    }

    /// Broadcast text to all running terminals
    func broadcast(text: String) {
        guard broadcastEnabled else { return }
        for session in sessions where session.isRunning {
            session.terminalView?.send(txt: text)
        }
    }
}

/// Individual session entry within a multi-session group
struct MultiSessionEntry: Identifiable {
    let id: UUID
    let repositoryPath: String
    let repoName: String

    var isRunning: Bool = true
    var isWaiting: Bool = false
    weak var terminalView: LocalProcessTerminalView?

    init(
        id: UUID = UUID(),
        repositoryPath: String,
        repoName: String
    ) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.repoName = repoName
    }
}
