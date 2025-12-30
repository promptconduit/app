import Foundation

/// Manages a Claude Code CLI session in print mode
class PTYSession: ObservableObject {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    @Published var output: String = ""
    @Published var isRunning: Bool = false

    let id: UUID
    let workingDirectory: String
    let createdAt: Date
    private var sessionId: String?
    private var isFirstPrompt = true

    init(id: UUID = UUID(), workingDirectory: String) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.createdAt = Date()
    }

    deinit {
        terminate()
    }

    // MARK: - Session Lifecycle

    /// Runs Claude CLI with a prompt in print mode
    func runPrompt(_ prompt: String) throws {
        guard !isRunning else {
            throw PTYError.alreadyRunning
        }

        output = "" // Clear previous output

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Build arguments
        // --dangerously-skip-permissions allows file edits without prompts since user consented by using this app
        var arguments = ["-p", "--verbose", "--output-format", "stream-json", "--dangerously-skip-permissions"]

        if !isFirstPrompt, let sid = sessionId {
            arguments.append(contentsOf: ["--resume", sid])
        }

        arguments.append(prompt)
        process.arguments = arguments

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        // Set up pipes for output capture
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        // Handle stdout
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.output += str
                }
            }
        }

        // Handle stderr (also capture as output)
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.output += str
                }
            }
        }

        // Handle process termination
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self?.errorPipe?.fileHandleForReading.readabilityHandler = nil
            }
        }

        do {
            try process.run()
            isRunning = true
        } catch {
            throw PTYError.forkFailed(errno: Int32(error._code))
        }
    }

    /// Sets the session ID for follow-up prompts
    func setSessionId(_ sid: String) {
        self.sessionId = sid
        self.isFirstPrompt = false
    }

    /// Legacy spawn method - now just initializes without running
    func spawn() throws {
        // No longer spawns interactive mode - use runPrompt() instead
    }

    /// Sends input to the process (not used in print mode)
    func send(_ input: String) {
        // Not used in print mode
    }

    /// Sends a line of input (not used in print mode)
    func sendLine(_ line: String) {
        // Not used in print mode
    }

    /// Terminates the session
    func terminate() {
        process?.terminate()
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
    }

    /// Sends interrupt signal to the process
    func interrupt() {
        process?.interrupt()
    }

    // MARK: - Resize (not used in print mode)

    func resize(rows: UInt16, cols: UInt16) {
        // Not used in print mode
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
            return "Session is already running"
        case .forkFailed(let errno):
            return "Failed to start process: error \(errno)"
        case .notRunning:
            return "Session is not running"
        }
    }
}
