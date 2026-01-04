import SwiftUI
import AppKit

// MARK: - Design Tokens

private enum LauncherTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundSecondary = Color(red: 0.10, green: 0.13, blue: 0.20)
    static let backgroundCard = Color(red: 0.13, green: 0.16, blue: 0.24)
    static let backgroundCardHover = Color(red: 0.16, green: 0.20, blue: 0.28)
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)
    static let accentPurple = Color(red: 0.58, green: 0.44, blue: 0.86)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let textMuted = Color(red: 0.4, green: 0.45, blue: 0.55)
    static let borderColor = Color(red: 0.20, green: 0.24, blue: 0.32)
    static let successGreen = Color(red: 0.3, green: 0.85, blue: 0.5)
    static let warningYellow = Color(red: 0.95, green: 0.75, blue: 0.3)
    static let errorRed = Color(red: 0.95, green: 0.35, blue: 0.35)
}

// MARK: - Session Launcher View

struct SessionLauncherView: View {
    let onStartNew: (String, String) -> Void
    let onResume: (SessionHistory) -> Void
    let onLaunchTerminal: (String) -> Void  // Launch single embedded terminal with directory
    let onLaunchMultiTerminal: ([String], GridLayout, String?) -> Void  // Launch multiple terminals
    let onCancel: () -> Void

    @ObservedObject private var settings = SettingsService.shared
    @StateObject private var commandsService = SlashCommandsService.shared

    @State private var selectedRepository: RecentRepository?
    @State private var selectedRepositories: Set<String> = []  // For multi-select mode
    @State private var isMultiSelectMode: Bool = false
    @State private var selectedLayout: GridLayout = .auto
    @State private var customDirectoryPath: String = ""
    @State private var prompt: String = ""
    @State private var selectedCommand: SlashCommand?
    @State private var showAllSessions = false
    @State private var showTemplateSheet = false

    private var effectiveDirectory: String {
        selectedRepository?.path ?? customDirectoryPath
    }

    /// Maximum number of repos that can be selected
    private let maxSelectedRepos = 8

    private var sessionsForSelectedRepo: [SessionHistory] {
        guard !effectiveDirectory.isEmpty else { return [] }
        return settings.sessionsForRepository(path: effectiveDirectory)
    }

    private var mostRecentSession: SessionHistory? {
        sessionsForSelectedRepo.first
    }

    var body: some View {
        ZStack {
            LauncherTokens.backgroundPrimary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection

                    // Repository Selection
                    repositorySection

                    // Session History (if repo selected and has sessions)
                    if !effectiveDirectory.isEmpty && !sessionsForSelectedRepo.isEmpty {
                        sessionHistorySection
                    }

                    // Divider with "or"
                    if mostRecentSession != nil {
                        dividerWithOr
                    }

                    // New Session Form
                    newSessionSection

                    // Actions
                    actionButtons
                }
                .padding(24)
            }
        }
        .frame(minWidth: 580, minHeight: 600)
        .onAppear {
            // Auto-select most recent repo
            if selectedRepository == nil, let mostRecent = settings.recentRepositories.first {
                selectedRepository = mostRecent
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(
                        colors: [LauncherTokens.accentCyan, LauncherTokens.accentPurple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Start Session")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(LauncherTokens.textPrimary)
        }
    }

    // MARK: - Repository Selection

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isMultiSelectMode ? "Repositories" : "Repository")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LauncherTokens.textSecondary)

                Spacer()

                // Multi-select toggle
                Toggle(isOn: $isMultiSelectMode) {
                    Text("Multi")
                        .font(.system(size: 11))
                        .foregroundColor(LauncherTokens.textMuted)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isMultiSelectMode) { _, newValue in
                    if !newValue {
                        selectedRepositories.removeAll()
                    }
                }

                // Templates button
                if !settings.repositoryTemplates.isEmpty {
                    Button("Templates") {
                        showTemplateSheet = true
                    }
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.accentPurple)
                    .buttonStyle(.plain)
                }

                Button("Browse...") {
                    selectDirectory()
                }
                .font(.system(size: 12))
                .foregroundColor(LauncherTokens.accentCyan)
                .buttonStyle(.plain)
            }

            // Selection count badge (multi-select mode)
            if isMultiSelectMode && !selectedRepositories.isEmpty {
                HStack {
                    Text("\(selectedRepositories.count) selected")
                        .font(.system(size: 12))
                        .foregroundColor(LauncherTokens.textSecondary)

                    if selectedRepositories.count >= maxSelectedRepos {
                        Text("(max)")
                            .font(.system(size: 11))
                            .foregroundColor(LauncherTokens.warningYellow)
                    }

                    Spacer()

                    Button("Clear") {
                        selectedRepositories.removeAll()
                    }
                    .font(.system(size: 11))
                    .foregroundColor(LauncherTokens.textMuted)
                    .buttonStyle(.plain)
                }
            }

            if settings.recentRepositories.isEmpty {
                // No recent repos - show text field
                customDirectoryInput
            } else {
                // Recent repos as cards
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach(settings.recentRepositories.prefix(8)) { repo in
                        if isMultiSelectMode {
                            MultiSelectRepositoryCard(
                                repo: repo,
                                isSelected: selectedRepositories.contains(repo.path),
                                sessionCount: settings.sessionsForRepository(path: repo.path).count,
                                isDisabled: !selectedRepositories.contains(repo.path) && selectedRepositories.count >= maxSelectedRepos
                            ) {
                                toggleRepoSelection(repo.path)
                            }
                        } else {
                            RepositoryCard(
                                repo: repo,
                                isSelected: selectedRepository?.path == repo.path,
                                sessionCount: settings.sessionsForRepository(path: repo.path).count
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedRepository = repo
                                    customDirectoryPath = ""
                                }
                            }
                        }
                    }
                }

                // Custom directory option (single-select mode only)
                if !isMultiSelectMode && (!customDirectoryPath.isEmpty || selectedRepository == nil) {
                    customDirectoryInput
                        .padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showTemplateSheet) {
            TemplateSelectionSheet(
                isPresented: $showTemplateSheet,
                onSelectTemplate: { template in
                    applyTemplate(template)
                }
            )
        }
    }

    private func toggleRepoSelection(_ path: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedRepositories.contains(path) {
                selectedRepositories.remove(path)
            } else if selectedRepositories.count < maxSelectedRepos {
                selectedRepositories.insert(path)
            }
        }
    }

    private func applyTemplate(_ template: RepositoryTemplate) {
        isMultiSelectMode = true
        selectedRepositories = Set(template.repositoryPaths.prefix(maxSelectedRepos))
        selectedLayout = template.defaultLayout
        settings.markTemplateUsed(template.id)
    }

    private var customDirectoryInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(LauncherTokens.textMuted)
                .frame(width: 20)

            TextField("Or enter a custom path...", text: $customDirectoryPath)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(LauncherTokens.textPrimary)
                .onChange(of: customDirectoryPath) { _, newValue in
                    if !newValue.isEmpty {
                        selectedRepository = nil
                    }
                }
        }
        .padding(12)
        .background(LauncherTokens.backgroundCard)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LauncherTokens.borderColor, lineWidth: 1)
        )
    }

    // MARK: - Session History

    private var sessionHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Previous Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LauncherTokens.textSecondary)

                Spacer()

                if sessionsForSelectedRepo.count > 2 {
                    Button(showAllSessions ? "Show Less" : "Show All (\(sessionsForSelectedRepo.count))") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllSessions.toggle()
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.accentCyan)
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 8) {
                let sessionsToShow = showAllSessions ? sessionsForSelectedRepo : Array(sessionsForSelectedRepo.prefix(2))
                ForEach(sessionsToShow) { session in
                    SessionCard(session: session, isFirst: session.id == mostRecentSession?.id) {
                        onResume(session)
                    }
                }
            }
        }
    }

    // MARK: - Divider

    private var dividerWithOr: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(LauncherTokens.borderColor)
                .frame(height: 1)

            Text("or start new")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(LauncherTokens.textMuted)
                .textCase(.uppercase)
                .tracking(1)

            Rectangle()
                .fill(LauncherTokens.borderColor)
                .frame(height: 1)
        }
    }

    // MARK: - New Session Form

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Slash Commands
            if !commandsService.commands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quick Start")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(LauncherTokens.textSecondary)
                        Text("(optional)")
                            .font(.system(size: 11))
                            .foregroundColor(LauncherTokens.textMuted)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(commandsService.commands.prefix(8)) { command in
                                SlashCommandChip(
                                    command: command,
                                    isSelected: selectedCommand?.id == command.id
                                ) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if selectedCommand?.id == command.id {
                                            selectedCommand = nil
                                        } else {
                                            selectedCommand = command
                                            if prompt.isEmpty {
                                                prompt = command.prompt
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Prompt
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prompt")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(LauncherTokens.textSecondary)

                    Spacer()

                    if selectedCommand != nil || !prompt.isEmpty {
                        Button("Clear") {
                            selectedCommand = nil
                            prompt = ""
                        }
                        .font(.system(size: 12))
                        .foregroundColor(LauncherTokens.textMuted)
                        .buttonStyle(.plain)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What would you like Claude to help with?")
                            .font(.system(size: 14))
                            .foregroundColor(LauncherTokens.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }

                    TextEditor(text: $prompt)
                        .font(.system(size: 14))
                        .foregroundColor(LauncherTokens.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 100, maxHeight: 200)
                        .padding(8)
                }
                .background(LauncherTokens.backgroundCard)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            prompt.isEmpty ? LauncherTokens.borderColor : LauncherTokens.accentCyan.opacity(0.5),
                            lineWidth: 1
                        )
                )
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 16) {
            if isMultiSelectMode && selectedRepositories.count > 1 {
                // Multi-repo launch section
                multiLaunchSection
            } else {
                // Single-repo launch (original)
                singleLaunchButton
            }

            // Secondary actions row
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                .buttonStyle(SecondaryButtonStyle())

                Spacer()

                // Text-based agent option (legacy/alternative, single-select only)
                if !isMultiSelectMode && !prompt.isEmpty {
                    Button(action: {
                        settings.addRecentRepository(path: effectiveDirectory)
                        onStartNew(prompt, effectiveDirectory)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 11))
                            Text("Start with Prompt")
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(prompt.isEmpty || effectiveDirectory.isEmpty)
                    .help("Start a text-based session with the prompt above")
                }
            }
        }
    }

    private var singleLaunchButton: some View {
        Button(action: {
            settings.addRecentRepository(path: effectiveDirectory)
            onLaunchTerminal(effectiveDirectory)
        }) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14))
                Text("Launch Claude Code")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [LauncherTokens.accentCyan, LauncherTokens.accentPurple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(effectiveDirectory.isEmpty)
        .help("Open interactive Claude Code terminal in this repository")
    }

    private var multiLaunchSection: some View {
        VStack(spacing: 12) {
            // Layout picker
            HStack {
                Text("Layout")
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.textSecondary)

                Picker("", selection: $selectedLayout) {
                    ForEach(GridLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Multi-launch button
            Button(action: {
                let repos = Array(selectedRepositories)
                for path in repos {
                    settings.addRecentRepository(path: path)
                }
                onLaunchMultiTerminal(repos, selectedLayout, prompt.isEmpty ? nil : prompt)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 14))
                    Text("Launch \(selectedRepositories.count) Terminals")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [LauncherTokens.accentCyan, LauncherTokens.accentPurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .help("Open \(selectedRepositories.count) Claude Code terminals in a grid")
        }
    }

    // MARK: - Helpers

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if settings.directoryExists(effectiveDirectory) {
            panel.directoryURL = URL(fileURLWithPath: effectiveDirectory)
        } else if settings.directoryExists(settings.defaultProjectsDirectory) {
            panel.directoryURL = URL(fileURLWithPath: settings.defaultProjectsDirectory)
        }

        if panel.runModal() == .OK, let url = panel.url {
            customDirectoryPath = url.path
            selectedRepository = nil
        }
    }
}

// MARK: - Repository Card

struct RepositoryCard: View {
    let repo: RecentRepository
    let isSelected: Bool
    let sessionCount: Int
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(isSelected ? LauncherTokens.accentCyan.opacity(0.2) : LauncherTokens.backgroundSecondary)
                        .frame(width: 36, height: 36)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? LauncherTokens.accentCyan : LauncherTokens.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(LauncherTokens.textPrimary)
                        .lineLimit(1)

                    Text(sessionCount == 0 ? "No sessions" : "\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(LauncherTokens.textMuted)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(LauncherTokens.accentCyan)
                        .font(.system(size: 16))
                }
            }
            .padding(12)
            .background(
                isSelected ? LauncherTokens.accentCyan.opacity(0.1) :
                    (isHovered ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundCard)
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? LauncherTokens.accentCyan : LauncherTokens.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(repo.path)
    }
}

// MARK: - Session Card

struct SessionCard: View {
    let session: SessionHistory
    let isFirst: Bool
    let onResume: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            // Status indicator
            VStack {
                Image(systemName: session.status.icon)
                    .foregroundColor(statusColor)
                    .font(.system(size: 14))
            }
            .frame(width: 24)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortPrompt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(LauncherTokens.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(session.detailedTime)
                        .font(.system(size: 11))
                        .foregroundColor(LauncherTokens.textMuted)

                    Text("•")
                        .foregroundColor(LauncherTokens.textMuted)

                    Text("\(session.messageCount) messages")
                        .font(.system(size: 11))
                        .foregroundColor(LauncherTokens.textMuted)
                }
            }

            Spacer()

            // Resume button
            Button(action: onResume) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Resume")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isFirst ?
                        LauncherTokens.accentCyan :
                        (isHovered ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundSecondary)
                )
                .foregroundColor(isFirst ? LauncherTokens.backgroundPrimary : LauncherTokens.textPrimary)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(isHovered ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFirst ? LauncherTokens.accentCyan.opacity(0.3) : LauncherTokens.borderColor, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .completed: return LauncherTokens.successGreen
        case .failed: return LauncherTokens.errorRed
        case .interrupted: return LauncherTokens.warningYellow
        }
    }
}

// MARK: - Slash Command Chip

struct SlashCommandChip: View {
    let command: SlashCommand
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text("/\(command.name)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isSelected ? LauncherTokens.backgroundPrimary : LauncherTokens.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? LauncherTokens.accentCyan :
                        (isHovered ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundSecondary)
                )
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? LauncherTokens.accentCyan : LauncherTokens.borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(command.description ?? command.name)
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isEnabled ? LauncherTokens.backgroundPrimary : LauncherTokens.textMuted)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                isEnabled ?
                    (configuration.isPressed ? LauncherTokens.accentCyan.opacity(0.8) : LauncherTokens.accentCyan) :
                    LauncherTokens.backgroundSecondary
            )
            .cornerRadius(8)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(LauncherTokens.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundCard)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(LauncherTokens.borderColor, lineWidth: 1)
            )
    }
}

// MARK: - Multi-Select Repository Card

struct MultiSelectRepositoryCard: View {
    let repo: RecentRepository
    let isSelected: Bool
    let sessionCount: Int
    let isDisabled: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? LauncherTokens.accentCyan : LauncherTokens.borderColor, lineWidth: 1.5)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LauncherTokens.accentCyan)
                            .frame(width: 18, height: 18)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                // Icon
                ZStack {
                    Circle()
                        .fill(isSelected ? LauncherTokens.accentCyan.opacity(0.2) : LauncherTokens.backgroundSecondary)
                        .frame(width: 32, height: 32)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? LauncherTokens.accentCyan : LauncherTokens.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isDisabled ? LauncherTokens.textMuted : LauncherTokens.textPrimary)
                        .lineLimit(1)

                    Text(sessionCount == 0 ? "No sessions" : "\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(LauncherTokens.textMuted)
                }

                Spacer()
            }
            .padding(10)
            .background(
                isSelected ? LauncherTokens.accentCyan.opacity(0.1) :
                    (isHovered && !isDisabled ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundCard)
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? LauncherTokens.accentCyan : LauncherTokens.borderColor, lineWidth: 1)
            )
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(repo.path)
    }
}

// MARK: - Template Selection Sheet

struct TemplateSelectionSheet: View {
    @Binding var isPresented: Bool
    let onSelectTemplate: (RepositoryTemplate) -> Void

    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Repository Templates")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LauncherTokens.textPrimary)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(LauncherTokens.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(LauncherTokens.backgroundSecondary)

            Divider()

            // Template list
            if settings.repositoryTemplates.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(LauncherTokens.textMuted)

                    Text("No templates yet")
                        .font(.system(size: 14))
                        .foregroundColor(LauncherTokens.textSecondary)

                    Text("Create templates by selecting multiple repos and saving them.")
                        .font(.system(size: 12))
                        .foregroundColor(LauncherTokens.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(settings.repositoryTemplates) { template in
                            TemplateRow(template: template) {
                                onSelectTemplate(template)
                                isPresented = false
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 400, height: 350)
        .background(LauncherTokens.backgroundPrimary)
    }
}

// MARK: - Template Row

struct TemplateRow: View {
    let template: RepositoryTemplate
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LauncherTokens.accentPurple.opacity(0.2))
                        .frame(width: 40, height: 40)

                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(LauncherTokens.accentPurple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(LauncherTokens.textPrimary)
                        .lineLimit(1)

                    Text("\(template.repositoryCount) repositories")
                        .font(.system(size: 11))
                        .foregroundColor(LauncherTokens.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(LauncherTokens.textMuted)
            }
            .padding(12)
            .background(isHovered ? LauncherTokens.backgroundCardHover : LauncherTokens.backgroundCard)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
