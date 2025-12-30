import AppKit
import SwiftUI

/// Controls the floating agent panel window
class AgentPanelController {
    private var panel: NSPanel?
    private var session: AgentSession?

    init() {
        setupPanel()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "PromptConduit Agent"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // Minimum size
        panel.minSize = NSSize(width: 400, height: 300)

        // Position in top-right quadrant
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let x = screenFrame.maxX - panelFrame.width - 20
            let y = screenFrame.maxY - panelFrame.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }

    // MARK: - Panel Control

    func showPanel(with session: AgentSession? = nil) {
        if let session = session {
            self.session = session
            updateContent()
        } else {
            showNewAgentView()
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    func closePanel() {
        panel?.close()
    }

    // MARK: - Content Management

    private func showNewAgentView() {
        let view = NewAgentView { [weak self] prompt, directory in
            self?.startNewAgent(prompt: prompt, directory: directory)
        }
        panel?.contentView = NSHostingView(rootView: view)
        panel?.title = "New Agent"
    }

    private func updateContent() {
        guard let session = session else { return }

        let view = AgentView(session: session)
        panel?.contentView = NSHostingView(rootView: view)
        panel?.title = "Agent: \(session.repoName)"
    }

    private func startNewAgent(prompt: String, directory: String) {
        session = AgentManager.shared.createSession(
            prompt: prompt,
            workingDirectory: directory
        )
        updateContent()
    }
}

// MARK: - New Agent View

struct NewAgentView: View {
    let onStart: (String, String) -> Void

    @State private var prompt: String = ""
    @State private var selectedDirectory: String = FileManager.default.currentDirectoryPath

    var body: some View {
        VStack(spacing: 20) {
            Text("New Agent")
                .font(.title)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory")
                    .font(.headline)

                HStack {
                    TextField("Directory path...", text: $selectedDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        selectDirectory()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.headline)

                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 100)
                    .border(Color.gray.opacity(0.3))
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    NSApp.sendAction(#selector(NSWindow.close), to: nil, from: nil)
                }
                .keyboardShortcut(.escape)

                Button("Start Agent") {
                    onStart(prompt, selectedDirectory)
                }
                .keyboardShortcut(.return)
                .disabled(prompt.isEmpty || selectedDirectory.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url.path
        }
    }
}

// MARK: - Agent View

struct AgentView: View {
    @ObservedObject var session: AgentSession
    @State private var inputText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            AgentHeaderView(session: session)

            Divider()

            // Transcript
            TranscriptView(entries: session.transcript, rawOutput: session.rawOutput)

            Divider()

            // Input
            AgentInputBar(
                text: $inputText,
                isEnabled: session.status == .waiting || session.status == .running,
                onSend: {
                    session.sendPrompt(inputText)
                    inputText = ""
                }
            )
        }
    }
}

// MARK: - Header View

struct AgentHeaderView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortPrompt)
                    .font(.headline)
                    .lineLimit(1)

                HStack {
                    Text(session.status.emoji)
                    Text(session.status.rawValue)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(session.repoName)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
            }

            Spacer()

            if session.status == .running {
                Button(action: { session.interrupt() }) {
                    Image(systemName: "stop.fill")
                }
                .help("Stop Agent")
            }
        }
        .padding()
    }
}
