import SwiftUI

struct AppSettingsView: View {
    @ObservedObject private var settings = SettingsService.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            SlashCommandsTab()
                .tabItem {
                    Label("Commands", systemImage: "terminal")
                }
                .tag(1)

            HooksSettingsTab()
                .tabItem {
                    Label("Hooks", systemImage: "link")
                }
                .tag(2)
        }
        .frame(width: 550, height: 400)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @ObservedObject private var settings = SettingsService.shared
    @State private var isSelectingDirectory = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Default Projects Directory")
                        .font(.headline)

                    HStack {
                        TextField("Path", text: $settings.defaultProjectsDirectory)
                            .textFieldStyle(.roundedBorder)

                        Button("Browse...") {
                            selectDirectory()
                        }
                    }

                    Text("New agents will start browsing from this directory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Startup")
                        .font(.headline)

                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notifications")
                        .font(.headline)

                    Toggle("Play sound when agent completes", isOn: $settings.notificationSoundEnabled)
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Code Editor")
                        .font(.headline)

                    Picker("Preferred editor:", selection: $settings.preferredCodeEditor) {
                        ForEach(CodeEditor.allCases) { editor in
                            HStack {
                                Text(editor.displayName)
                                if editor != .none && !editor.isInstalled {
                                    Text("(not installed)")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                            .tag(editor)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 250)

                    Text("Opens the project directory with a button in the agent header")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keyboard Shortcut")
                        .font(.headline)

                    HStack {
                        Text("Global hotkey:")
                        Text(settings.globalHotkey)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)

                        Text("(requires Accessibility permission)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding()
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.defaultProjectsDirectory)

        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultProjectsDirectory = url.path
        }
    }
}

// MARK: - Slash Commands Tab

struct SlashCommandsTab: View {
    @StateObject private var commandsService = SlashCommandsService.shared
    @State private var selectedCommand: SlashCommand?
    @State private var isCreatingNew = false

    var body: some View {
        HSplitView {
            // Commands List
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Commands")
                        .font(.headline)
                    Spacer()
                    Button(action: { isCreatingNew = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    Button(action: { commandsService.reload() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()

                Divider()

                if commandsService.commands.isEmpty {
                    VStack {
                        Spacer()
                        Text("No commands found")
                            .foregroundColor(.secondary)
                        Text("Commands are loaded from\n~/.claude/commands/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(commandsService.commands, selection: $selectedCommand) { command in
                        CommandRow(command: command)
                            .tag(command)
                    }
                }
            }
            .frame(minWidth: 200)

            // Command Detail
            if let command = selectedCommand {
                CommandDetailView(command: command)
            } else {
                VStack {
                    Text("Select a command")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            NewCommandSheet(isPresented: $isCreatingNew)
        }
    }
}

struct CommandRow: View {
    let command: SlashCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("/\(command.name)")
                .font(.headline)
            if let description = command.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CommandDetailView: View {
    let command: SlashCommand

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("/\(command.name)")
                    .font(.title)

                if let description = command.description {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.headline)
                        Text(description)
                            .foregroundColor(.secondary)
                    }
                }

                if let allowedTools = command.allowedTools {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed Tools")
                            .font(.headline)
                        Text(allowedTools)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                        .font(.headline)
                    Text(command.prompt)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("File")
                        .font(.headline)
                    Text(command.filePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
        }
    }
}

struct NewCommandSheet: View {
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var description = ""
    @State private var prompt = ""
    @State private var allowedTools = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("New Slash Command")
                .font(.title2)

            Form {
                TextField("Command name (without /)", text: $name)
                TextField("Description", text: $description)
                TextField("Allowed tools (optional)", text: $allowedTools)

                VStack(alignment: .leading) {
                    Text("Prompt")
                    TextEditor(text: $prompt)
                        .frame(minHeight: 100)
                        .border(Color.gray.opacity(0.3))
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Create") {
                    createCommand()
                }
                .keyboardShortcut(.return)
                .disabled(name.isEmpty || prompt.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }

    private func createCommand() {
        SlashCommandsService.shared.createCommand(
            name: name,
            description: description.isEmpty ? nil : description,
            prompt: prompt,
            allowedTools: allowedTools.isEmpty ? nil : allowedTools
        )
        isPresented = false
    }
}

// MARK: - Hooks Settings Tab

struct HooksSettingsTab: View {
    @State private var hooksInstalled: Bool = false
    @State private var isInstalling: Bool = false
    @State private var errorMessage: String?
    @State private var showingConfirmUninstall: Bool = false

    private let hookManager = ClaudeCodeHookManager.shared

    var body: some View {
        Form {
            Section {
                Text("Claude Code Hooks")
                    .font(.headline)
                Text("Hooks enable precise session state tracking")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: hooksInstalled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(hooksInstalled ? .green : .secondary)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(hooksInstalled ? "Hooks Installed" : "Hooks Not Installed")
                                .font(.headline)
                            Text(hooksInstalled
                                ? "Session state is tracked via Claude Code hooks"
                                : "Session state is tracked via terminal output parsing")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.vertical, 4)
                    }

                    HStack {
                        if hooksInstalled {
                            Button("Uninstall Hooks") {
                                showingConfirmUninstall = true
                            }
                            .disabled(isInstalling)
                        } else {
                            Button("Install Hooks") {
                                installHooks()
                            }
                            .disabled(isInstalling)
                        }

                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.7)
                                .padding(.leading, 4)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Hooks")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        HookInfoRow(event: "SessionStart", description: "Detects when Claude is ready for input")
                        HookInfoRow(event: "UserPromptSubmit", description: "Detects when user submits a prompt")
                        HookInfoRow(event: "Stop", description: "Detects when Claude finishes responding")
                    }

                    Text("Hooks are added to ~/.claude/settings.json (your existing settings are preserved)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            Divider()

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fallback Mode")
                        .font(.headline)

                    Text("Without hooks, PromptConduit uses terminal output parsing to detect session state. This works with any CLI but may be less accurate than hooks.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Open Claude Settings File") {
                        NSWorkspace.shared.selectFile(
                            SettingsService.claudeSettingsFilePath,
                            inFileViewerRootedAtPath: SettingsService.claudeSettingsPath
                        )
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding()
        .onAppear {
            checkHooksInstalled()
        }
        .alert("Uninstall Hooks?", isPresented: $showingConfirmUninstall) {
            Button("Cancel", role: .cancel) { }
            Button("Uninstall", role: .destructive) {
                uninstallHooks()
            }
        } message: {
            Text("Session state will be tracked via terminal output parsing instead. This may be less accurate.")
        }
    }

    private func checkHooksInstalled() {
        hooksInstalled = hookManager.areHooksInstalled()
    }

    private func installHooks() {
        isInstalling = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = hookManager.installHooks()

            DispatchQueue.main.async {
                isInstalling = false
                switch result {
                case .success:
                    hooksInstalled = true
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func uninstallHooks() {
        isInstalling = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = hookManager.uninstallHooks()

            DispatchQueue.main.async {
                isInstalling = false
                switch result {
                case .success:
                    hooksInstalled = false
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct HookInfoRow: View {
    let event: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(event)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    AppSettingsView()
}
