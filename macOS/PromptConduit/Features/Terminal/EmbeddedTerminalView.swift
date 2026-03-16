import SwiftUI
import AppKit


/// A SwiftUI wrapper for GhosttyTerminalView (GPU-accelerated terminal).
struct EmbeddedTerminalView: NSViewRepresentable {
    let workingDirectory: String
    let command: String
    let arguments: [String]
    let onTerminated: (() -> Void)?
    let onTerminalReady: ((GhosttyTerminalView) -> Void)?
    let onOutputReceived: ((String) -> Void)?
    let onClaudeReady: (() -> Void)?

    init(
        workingDirectory: String,
        command: String? = nil,
        arguments: [String] = ["--dangerously-skip-permissions"],
        onTerminated: (() -> Void)? = nil,
        onTerminalReady: ((GhosttyTerminalView) -> Void)? = nil,
        onOutputReceived: ((String) -> Void)? = nil,
        onClaudeReady: (() -> Void)? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command ?? Self.findClaudeExecutable()
        self.arguments = arguments
        self.onTerminated = onTerminated
        self.onTerminalReady = onTerminalReady
        self.onOutputReceived = onOutputReceived
        self.onClaudeReady = onClaudeReady
    }

    /// Finds the claude executable in common installation paths
    private static func findClaudeExecutable() -> String {
        let possiblePaths = [
            "/opt/homebrew/bin/claude",      // Apple Silicon Homebrew
            "/usr/local/bin/claude",          // Intel Homebrew
            "\(NSHomeDirectory())/.local/bin/claude", // npm global install
            "/usr/bin/claude"                 // System install
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback to just "claude" and let PATH resolve it
        return "claude"
    }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let terminalView = GhosttyTerminalView(frame: .zero)

        // Set up output monitoring callbacks
        terminalView.onDataReceived = { [onOutputReceived] text in
            onOutputReceived?(text)
        }
        terminalView.onClaudeReady = { [onClaudeReady] in
            onClaudeReady?()
        }
        terminalView.onProcessTerminated = { [onTerminated] in
            onTerminated?()
        }

        // Ensure the terminal can accept keyboard input
        terminalView.becomeFirstResponder()

        // Also request focus after a brief delay to handle window setup timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminalView.window?.makeFirstResponder(terminalView)
        }

        // Build environment with user's PATH and proper terminal settings
        var environment = ProcessInfo.processInfo.environment
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = "en_US.UTF-8"

        // Build shell command — quote each argument to prevent injection
        let quotedArgs = arguments.map { "\"\($0)\"" }.joined(separator: " ")
        let shellCommand = "cd \"\(workingDirectory)\" && \"\(command)\" \(quotedArgs)"

        // Start the process
        terminalView.startProcess(
            shellCommand: shellCommand,
            environment: Array(environment.map { "\($0.key)=\($0.value)" })
        )

        // Notify that terminal is ready
        DispatchQueue.main.async {
            self.onTerminalReady?(terminalView)
        }

        return terminalView
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Nothing to update dynamically for now
    }
}

// MARK: - Terminal Session Panel View

/// A complete panel view containing the terminal and header
struct TerminalSessionView: View {
    let sessionId: UUID
    let repoName: String
    let workingDirectory: String
    let initialPrompt: String?
    /// Additional Claude Code arguments (e.g., ["--resume", "session-id"])
    let additionalArguments: [String]
    let onClose: () -> Void
    /// Callback when the process terminates naturally
    var onTerminated: (() -> Void)?
    /// Callback to insert text into the terminal (set by parent for paste handling)
    var onImageAttached: ((String) -> Void)?

    init(
        sessionId: UUID,
        repoName: String,
        workingDirectory: String,
        initialPrompt: String? = nil,
        additionalArguments: [String] = [],
        onClose: @escaping () -> Void,
        onTerminated: (() -> Void)? = nil,
        onImageAttached: ((String) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.repoName = repoName
        self.workingDirectory = workingDirectory
        self.initialPrompt = initialPrompt
        self.additionalArguments = additionalArguments
        self.onClose = onClose
        self.onTerminated = onTerminated
        self.onImageAttached = onImageAttached
    }

    @ObservedObject private var terminalManager = TerminalSessionManager.shared
    @State private var isTerminated = false
    @State private var terminalView: GhosttyTerminalView?
    @State private var showingImagePicker = false
    @State private var isDragOver = false
    @State private var promptSent = false

    private let imageService = ImageAttachmentService.shared

    /// Whether the session is waiting for input (from TerminalSessionManager)
    private var isWaiting: Bool {
        terminalManager.session(for: sessionId)?.isWaiting ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                        Text(repoName)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.gray)
                }

                Spacer()

                // Attach image button
                Button(action: { showingImagePicker = true }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("Attach image (or drag & drop, or paste with \u{2318}V)")
                .padding(.trailing, 8)

                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("Close terminal")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SwiftUI.Color(red: 0.12, green: 0.16, blue: 0.24))

            Divider()
                .background(SwiftUI.Color.gray.opacity(0.3))

            // Terminal view with drag & drop overlay
            ZStack {
                EmbeddedTerminalView(
                    workingDirectory: workingDirectory,
                    arguments: ["--dangerously-skip-permissions"] + additionalArguments,
                    onTerminated: {
                        isTerminated = true
                        onTerminated?()
                    },
                    onTerminalReady: { terminal in
                        terminalView = terminal
                    },
                    onOutputReceived: { text in
                        // Feed output to terminal session manager for waiting state detection
                        terminalManager.processOutput(sessionId, text: text)
                    },
                    onClaudeReady: {
                        sendInitialPromptIfNeeded()
                    }
                )
                .background(SwiftUI.Color.black)

                // Drag overlay
                if isDragOver {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SwiftUI.Color.cyan, lineWidth: 3)
                        .background(SwiftUI.Color.cyan.opacity(0.1))
                        .padding(4)
                }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
            }
        }
        .background(SwiftUI.Color.black)
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image, .png, .jpeg, .gif, .webP, .bmp, .tiff, .heic],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Status Helpers

    private var statusColor: SwiftUI.Color {
        if isTerminated {
            return .red
        } else if isWaiting {
            return .yellow
        } else {
            return .green
        }
    }

    private var statusText: String {
        if isTerminated {
            return "Terminated"
        } else if isWaiting {
            return "Waiting"
        } else {
            return "Running"
        }
    }

    // MARK: - Initial Prompt

    /// Sends the initial prompt to Claude when ready
    private func sendInitialPromptIfNeeded() {
        guard let prompt = initialPrompt, !prompt.isEmpty else { return }
        guard !promptSent else { return }

        promptSent = true
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Wait a short moment for Claude to be fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard let terminal = terminalView else { return }

            // Send prompt text
            terminal.sendText(trimmedPrompt)

            // Send Enter key after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                terminal.sendBytes([13]) // Carriage return
            }
        }
    }

    // MARK: - Image Handling

    /// Handles file drop from drag & drop
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            // Try to load as file URL first
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       isImageFile(url) {
                        DispatchQueue.main.async {
                            attachImageFile(url)
                        }
                    }
                }
                handled = true
            }
            // Try to load as image data
            else if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    if let data = data {
                        DispatchQueue.main.async {
                            attachImageData(data)
                        }
                    }
                }
                handled = true
            }
        }

        return handled
    }

    /// Handles file import from file picker
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                // Need to access security-scoped resource
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                attachImageFile(url)
            }
        case .failure(let error):
            print("File import failed: \(error)")
        }
    }

    /// Checks if a URL points to an image file
    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Attaches an image file by copying to temp and inserting path
    private func attachImageFile(_ url: URL) {
        if let savedURL = imageService.copyImageFile(url) {
            insertImagePath(savedURL)
        }
    }

    /// Attaches image data by saving to temp and inserting path
    private func attachImageData(_ data: Data) {
        if let savedURL = imageService.saveImageData(data, fileExtension: "png") {
            insertImagePath(savedURL)
        }
    }

    /// Inserts the image path into the terminal
    private func insertImagePath(_ url: URL) {
        let formattedPath = imageService.formatPathForTerminal(url)
        let textToInsert = " \(formattedPath) "

        // Try using terminal view directly
        if let terminal = terminalView {
            terminal.sendText(textToInsert)
            // Restore focus to terminal
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
        }

        // Also notify parent (for paste handling coordination)
        onImageAttached?(textToInsert)
    }

    /// Called by parent when paste contains an image
    func handleImagePaste() {
        if let savedURL = imageService.saveImageFromPasteboard() {
            insertImagePath(savedURL)
        }
    }
}

// MARK: - Preview

#Preview {
    TerminalSessionView(
        sessionId: UUID(),
        repoName: "my-project",
        workingDirectory: "/Users/user/Projects/my-project",
        initialPrompt: nil,
        onClose: {}
    )
    .frame(width: 800, height: 600)
}
