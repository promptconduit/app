import Foundation
import Combine

/// Represents an externally running Claude Code process
struct ExternalClaudeProcess: Identifiable, Hashable {
    let id: Int32  // Process ID
    let workingDirectory: String
    let startTime: Date?

    var displayName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ExternalClaudeProcess, rhs: ExternalClaudeProcess) -> Bool {
        lhs.id == rhs.id
    }
}

/// Service to detect externally running Claude Code processes
class ProcessDetectionService: ObservableObject {
    static let shared = ProcessDetectionService()

    @Published private(set) var externalProcesses: [ExternalClaudeProcess] = []

    private var timer: Timer?
    private var managedPIDs: Set<Int32> = []

    private init() {
        startMonitoring()
    }

    /// Register a PID as managed by PromptConduit (to exclude from external list)
    func registerManagedPID(_ pid: Int32) {
        managedPIDs.insert(pid)
        refreshProcesses()
    }

    /// Unregister a PID when the managed session ends
    func unregisterManagedPID(_ pid: Int32) {
        managedPIDs.remove(pid)
        refreshProcesses()
    }

    /// Start periodic monitoring
    func startMonitoring() {
        // Initial scan
        refreshProcesses()

        // Periodic refresh every 3 seconds - must be on main thread for timer to work
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.refreshProcesses()
            }
            if let timer = self.timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Manually refresh the process list
    func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let processes = self?.detectClaudeProcesses() ?? []

            DispatchQueue.main.async {
                self?.externalProcesses = processes
            }
        }
    }

    /// Detect running Claude Code processes using ps command
    private func detectClaudeProcesses() -> [ExternalClaudeProcess] {
        var processes: [ExternalClaudeProcess] = []

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,lstart,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            // IMPORTANT: Read output BEFORE waitUntilExit to avoid deadlock
            // If pipe buffer fills, ps blocks, and we block waiting for ps = deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }

            // Parse each line
            for line in output.components(separatedBy: "\n") {
                if let process = parseProcessLine(line) {
                    // Exclude PIDs managed by PromptConduit
                    if !managedPIDs.contains(process.id) {
                        processes.append(process)
                    }
                }
            }
        } catch {
            // Silently fail - process detection is best-effort
        }

        return processes
    }

    /// Parse a ps output line to detect Claude Code processes
    private func parseProcessLine(_ line: String) -> ExternalClaudeProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Exclude helper processes and our own grep/ps
        guard !trimmed.contains("grep"),
              !trimmed.contains("ps -eo"),
              !trimmed.contains("--chrome-native-host"),
              !trimmed.contains("--claude-in-chrome-mcp") else { return nil }

        // Look for "claude" binary in the command
        // Patterns to match:
        // - "claude --options..." (starts with claude after the date)
        // - "/path/to/claude --options..." (full path)
        // - "/opt/homebrew/bin/claude --options..."
        let hasClaude = trimmed.contains("/claude ") ||
                        trimmed.contains("/claude\n") ||
                        trimmed.hasSuffix("/claude") ||
                        trimmed.contains(" claude --") ||
                        trimmed.contains(" claude\n")

        guard hasClaude else { return nil }

        // Parse PID (first field)
        let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let pidString = components.first,
              let pid = Int32(pidString) else { return nil }

        // Verify process is actually alive (not zombie/stale)
        guard isProcessAlive(pid) else { return nil }

        // Try to get the working directory using lsof
        let workingDir = getWorkingDirectory(for: pid) ?? "Unknown"

        // Parse start time from lstart (format: "Day Mon DD HH:MM:SS YYYY")
        let startTime = parseStartTime(from: trimmed)

        return ExternalClaudeProcess(
            id: pid,
            workingDirectory: workingDir,
            startTime: startTime
        )
    }

    /// Get the working directory of a process using lsof
    private func getWorkingDirectory(for pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", String(pid), "-Fn", "-a", "-d", "cwd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            // Read before wait to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // lsof output format: lines starting with 'n' contain the path
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n") && line.count > 1 {
                    let path = String(line.dropFirst())
                    // Return the path if it's a valid directory
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
                        return path
                    }
                }
            }
        } catch {
            // Fall through
        }

        return nil
    }

    /// Check if a process is actually alive (not zombie/terminated)
    /// Uses kill(pid, 0) which tests if process exists without sending a signal
    private func isProcessAlive(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }

    /// Parse start time from ps lstart output
    private func parseStartTime(from line: String) -> Date? {
        // lstart format: "Fri Jan  3 10:00:00 2025"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Try to extract the date portion
        let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        for dayName in dayNames {
            if let range = line.range(of: dayName) {
                let startIndex = range.lowerBound
                let endIndex = line.index(startIndex, offsetBy: min(24, line.distance(from: startIndex, to: line.endIndex)))
                let dateString = String(line[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)

                // Handle double spaces in date (e.g., "Jan  3" vs "Jan 10")
                let normalized = dateString.replacingOccurrences(of: "  ", with: " ")

                if let date = dateFormatter.date(from: normalized) {
                    return date
                }
            }
        }

        return nil
    }
}
