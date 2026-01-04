import Foundation
import Combine

/// Log with immediate flush for debugging
private func debugLog(_ message: String) {
    let msg = "[HookNotificationService] \(message)\n"
    FileHandle.standardOutput.write(msg.data(using: .utf8)!)
    // Also log to a file for reliability
    let logPath = "/tmp/promptconduit-hook.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: msg.data(using: .utf8))
    }
}

/// Service that listens for notifications from promptconduit CLI hooks
/// Uses a file-based approach for simplicity and reliability
class HookNotificationService: ObservableObject {
    static let shared = HookNotificationService()

    /// Path where CLI writes hook events
    private let hookEventsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".promptconduit")
        .appendingPathComponent("hook-events")

    /// File handle for monitoring
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?

    /// Published events
    @Published private(set) var lastSessionStartEvent: SessionStartEvent?
    @Published private(set) var lastStopEvent: StopEvent?

    // Callbacks
    var onSessionStart: ((SessionStartEvent) -> Void)?
    var onStop: ((StopEvent) -> Void)?

    private init() {}

    /// Start listening for hook events
    func startListening() {
        // Create directory if needed
        let dir = hookEventsPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create file if needed
        if !FileManager.default.fileExists(atPath: hookEventsPath.path) {
            FileManager.default.createFile(atPath: hookEventsPath.path, contents: nil)
        }

        // Open file for reading
        guard let handle = FileHandle(forReadingAtPath: hookEventsPath.path) else {
            debugLog("Failed to open hook events file")
            return
        }
        debugLog("Opened hook events file successfully")
        fileHandle = handle

        // Seek to end to only get new events
        handle.seekToEndOfFile()

        // Set up file system watcher
        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source?.setEventHandler { [weak self] in
            self?.readNewEvents()
        }

        source?.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }

        source?.resume()
        debugLog("Started listening for hook events at \(hookEventsPath.path)")
    }

    /// Stop listening
    func stopListening() {
        source?.cancel()
        source = nil
    }

    /// Read new events from the file
    private func readNewEvents() {
        debugLog("readNewEvents called")
        guard let handle = fileHandle else {
            debugLog("No file handle!")
            return
        }

        let data = handle.readDataToEndOfFile()
        debugLog("Read \(data.count) bytes")
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            debugLog("No data or failed to decode")
            return
        }

        debugLog("Got text: \(text.prefix(200))")

        // Parse each line as JSON event
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            parseEvent(line)
        }
    }

    /// Parse a single event line
    private func parseEvent(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let eventType = dict["event"] as? String {

                switch eventType {
                case "SessionStart":
                    let event = SessionStartEvent(
                        cwd: dict["cwd"] as? String ?? "",
                        sessionId: dict["session_id"] as? String,
                        timestamp: Date()
                    )
                    lastSessionStartEvent = event
                    debugLog("SessionStart event: \(event.cwd)")
                    debugLog("onSessionStart callback: \(onSessionStart != nil ? "set" : "nil")")
                    onSessionStart?(event)

                case "Stop":
                    let event = StopEvent(
                        cwd: dict["cwd"] as? String ?? "",
                        sessionId: dict["session_id"] as? String,
                        timestamp: Date()
                    )
                    lastStopEvent = event
                    debugLog("Stop event: \(event.cwd)")
                    onStop?(event)

                default:
                    debugLog("Unknown event type: \(eventType)")
                }
            }
        } catch {
            debugLog("Failed to parse event: \(error)")
        }
    }
}

// MARK: - Event Types

struct SessionStartEvent {
    let cwd: String
    let sessionId: String?
    let timestamp: Date
}

struct StopEvent {
    let cwd: String
    let sessionId: String?
    let timestamp: Date
}
