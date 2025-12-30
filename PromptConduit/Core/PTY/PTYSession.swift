import Foundation
import Darwin

/// Manages a pseudo-terminal session for running Claude Code CLI
class PTYSession: ObservableObject {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private let outputQueue = DispatchQueue(label: "com.promptconduit.pty.output")

    @Published var output: String = ""
    @Published var isRunning: Bool = false

    let id: UUID
    let workingDirectory: String
    let createdAt: Date

    init(id: UUID = UUID(), workingDirectory: String) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.createdAt = Date()
    }

    deinit {
        terminate()
    }

    // MARK: - Session Lifecycle

    /// Spawns the Claude CLI in a pseudo-terminal
    func spawn() throws {
        guard !isRunning else {
            throw PTYError.alreadyRunning
        }

        var winSize = winsize(
            ws_row: 24,
            ws_col: 120,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        childPID = forkpty(&masterFD, nil, nil, &winSize)

        if childPID == -1 {
            throw PTYError.forkFailed(errno: errno)
        }

        if childPID == 0 {
            // Child process
            if chdir(workingDirectory) != 0 {
                exit(1)
            }

            // Set up environment
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)

            // Execute claude
            let command = "claude"
            let args = [command]

            // Convert args to C-style array
            var cArgs = args.map { strdup($0) }
            cArgs.append(nil)

            execvp(command, &cArgs)

            // If we get here, exec failed
            exit(1)
        }

        // Parent process
        isRunning = true
        startReadingOutput()
    }

    /// Sends input to the PTY (as if user typed it)
    func send(_ input: String) {
        guard isRunning else { return }

        let data = input.data(using: .utf8) ?? Data()
        data.withUnsafeBytes { bytes in
            _ = write(masterFD, bytes.baseAddress, bytes.count)
        }
    }

    /// Sends a line of input followed by newline
    func sendLine(_ line: String) {
        send(line + "\n")
    }

    /// Terminates the PTY session
    func terminate() {
        guard isRunning else { return }

        readSource?.cancel()
        readSource = nil

        if childPID > 0 {
            kill(childPID, SIGTERM)
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
        }

        if masterFD != -1 {
            close(masterFD)
            masterFD = -1
        }

        isRunning = false
    }

    /// Sends Ctrl+C to interrupt current operation
    func interrupt() {
        send("\u{03}") // ASCII ETX (Ctrl+C)
    }

    // MARK: - Output Reading

    private func startReadingOutput() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: outputQueue)

        source.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.masterFD != -1 {
                close(self.masterFD)
                self.masterFD = -1
            }
        }

        readSource = source
        source.resume()
    }

    private func readAvailableOutput() {
        var buffer = [CChar](repeating: 0, count: 4096)
        let bytesRead = read(masterFD, &buffer, buffer.count - 1)

        if bytesRead > 0 {
            buffer[Int(bytesRead)] = 0
            if let str = String(cString: buffer, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in
                    self?.output += str
                }
            }
        } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN) {
            // EOF or error
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
            }
        }
    }

    // MARK: - Resize

    func resize(rows: UInt16, cols: UInt16) {
        guard isRunning else { return }

        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }
}

// MARK: - Errors

enum PTYError: Error, LocalizedError {
    case alreadyRunning
    case forkFailed(errno: Int32)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "PTY session is already running"
        case .forkFailed(let errno):
            return "Failed to fork PTY: \(String(cString: strerror(errno)))"
        case .notRunning:
            return "PTY session is not running"
        }
    }
}
