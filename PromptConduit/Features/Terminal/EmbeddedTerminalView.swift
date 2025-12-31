import SwiftUI
import AppKit
import SwiftTerm

/// A SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView
struct EmbeddedTerminalView: NSViewRepresentable {
    let workingDirectory: String
    let command: String
    let arguments: [String]
    let onTerminated: (() -> Void)?

    init(
        workingDirectory: String,
        command: String? = nil,
        arguments: [String] = ["--dangerously-skip-permissions"],
        onTerminated: (() -> Void)? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command ?? Self.findClaudeExecutable()
        self.arguments = arguments
        self.onTerminated = onTerminated
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

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)

        // Configure terminal appearance with dark theme
        let bgColor = NSColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1.0)
        let fgColor = NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)

        terminalView.configureNativeColors()
        terminalView.nativeForegroundColor = fgColor
        terminalView.nativeBackgroundColor = bgColor
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Set the delegate for terminal events
        terminalView.processDelegate = context.coordinator

        // Ensure the terminal can accept keyboard input
        terminalView.becomeFirstResponder()

        // Also request focus after a brief delay to handle window setup timing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminalView.window?.makeFirstResponder(terminalView)
        }

        // Build environment with user's PATH
        var environment = ProcessInfo.processInfo.environment
        // Ensure common paths are in PATH for finding claude
        if let existingPath = environment["PATH"] {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        }

        // Build shell command that changes to working directory then runs claude
        // We use a shell to handle directory change since startProcess doesn't support it
        let shellCommand = "cd \"\(workingDirectory)\" && \"\(command)\" \(arguments.joined(separator: " "))"

        // Start the process via shell
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", shellCommand],
            environment: Array(environment.map { "\($0.key)=\($0.value)" }),
            execName: nil
        )

        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Nothing to update dynamically for now
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onTerminated)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: (() -> Void)?

        init(onTerminated: (() -> Void)?) {
            self.onTerminated = onTerminated
        }

        // From LocalProcessTerminalViewDelegate (uses LocalProcessTerminalView)
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // Terminal size changed
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // Terminal title changed
        }

        // From TerminalViewDelegate (uses TerminalView)
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                self.onTerminated?()
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Current directory changed in the terminal
        }
    }
}

// MARK: - Terminal Session Panel View

/// A complete panel view containing the terminal and header
struct TerminalSessionView: View {
    let repoName: String
    let workingDirectory: String
    let onClose: () -> Void

    @State private var isTerminated = false

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

                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(isTerminated ? SwiftUI.Color.red : SwiftUI.Color.green)
                        .frame(width: 8, height: 8)
                    Text(isTerminated ? "Terminated" : "Running")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isTerminated ? .red : .green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((isTerminated ? SwiftUI.Color.red : SwiftUI.Color.green).opacity(0.15))
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

            // Terminal view
            EmbeddedTerminalView(
                workingDirectory: workingDirectory,
                onTerminated: {
                    isTerminated = true
                }
            )
            .background(SwiftUI.Color.black)
        }
        .background(SwiftUI.Color.black)
    }
}

// MARK: - Preview

#Preview {
    TerminalSessionView(
        repoName: "my-project",
        workingDirectory: "/Users/user/Projects/my-project",
        onClose: {}
    )
    .frame(width: 800, height: 600)
}
