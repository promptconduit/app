import Foundation
import Combine
import SwiftTerm

/// Information about a terminal session launched from PromptConduit
struct TerminalSessionInfo: Identifiable {
    let id: UUID
    let repoName: String
    let workingDirectory: String
    var isRunning: Bool
    weak var terminalView: LocalProcessTerminalView?
}

/// Manages terminal sessions launched from PromptConduit
/// Separate from AgentManager which handles PTY-based print-mode sessions
class TerminalSessionManager: ObservableObject {
    static let shared = TerminalSessionManager()

    @Published private(set) var sessions: [TerminalSessionInfo] = []

    private init() {}

    // MARK: - Session Management

    /// Registers a new terminal session
    func registerSession(id: UUID, repoName: String, workingDirectory: String) {
        let session = TerminalSessionInfo(
            id: id,
            repoName: repoName,
            workingDirectory: workingDirectory,
            isRunning: true,
            terminalView: nil
        )
        sessions.append(session)

        // Register working directory to exclude from external detection
        ProcessDetectionService.shared.registerManagedWorkingDirectory(workingDirectory)
    }

    /// Updates the terminal view reference for a session
    func updateTerminalView(_ id: UUID, terminalView: LocalProcessTerminalView?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminalView = terminalView
    }

    /// Gets a session by ID
    func session(for id: UUID) -> TerminalSessionInfo? {
        sessions.first { $0.id == id }
    }

    /// Marks a session as terminated (process ended naturally)
    func markTerminated(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isRunning = false
        // Note: We keep the working directory registered until the session is removed
        // so it doesn't appear in external list while window is still open
    }

    /// Terminates and removes a session (user closed the window)
    func terminateSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        let session = sessions[index]

        // Find and kill the process by working directory
        // SwiftTerm's terminate() is internal, so we use POSIX kill
        if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
            kill(pid, SIGTERM)
        }

        // Unregister working directory
        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)

        // Remove from sessions
        sessions.remove(at: index)
    }

    /// Removes a session without terminating (already terminated)
    func unregisterSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        // Unregister working directory
        ProcessDetectionService.shared.unregisterManagedWorkingDirectory(sessions[index].workingDirectory)

        sessions.remove(at: index)
    }

    /// Terminates all sessions
    func terminateAllSessions() {
        for session in sessions {
            // Find and kill the process by working directory
            if let pid = findClaudeProcessPID(workingDirectory: session.workingDirectory) {
                kill(pid, SIGTERM)
            }
            ProcessDetectionService.shared.unregisterManagedWorkingDirectory(session.workingDirectory)
        }
        sessions.removeAll()
    }

    // MARK: - Process Lookup

    /// Finds the PID of a Claude process running in the specified working directory
    private func findClaudeProcessPID(workingDirectory: String) -> pid_t? {
        // Use ps to find Claude processes
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

            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Find Claude processes
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      (trimmed.contains("/claude ") || trimmed.hasSuffix("/claude")) else { continue }

                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard let pidString = components.first,
                      let pid = pid_t(pidString) else { continue }

                // Verify this process is running in our working directory
                if getProcessWorkingDirectory(pid) == workingDirectory {
                    return pid
                }
            }
        } catch {
            // Process lookup failed
        }

        return nil
    }

    /// Gets the working directory of a process using lsof
    private func getProcessWorkingDirectory(_ pid: pid_t) -> String? {
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
