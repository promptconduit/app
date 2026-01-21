import SwiftUI
import AppKit

// MARK: - Session Composer View

/// Chat-like view for composing a new session with repo selection and prompt input
struct SessionComposerView: View {
    @StateObject private var settings = SettingsService.shared
    @StateObject private var commandsService = SlashCommandsService.shared

    // Selection state
    @State private var selectedRepoPaths: Set<String> = []
    @State private var selectedLayout: GridLayout = .auto
    @State private var prompt: String = ""
    @State private var selectedCommand: SlashCommand?

    private let maxSelectedRepos = 8

    let onLaunchGroup: ([String], GridLayout, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            composerHeader

            Divider()
                .background(TokyoNight.borderColor)

            // Main content
            ScrollView {
                VStack(spacing: 24) {
                    // Repository selection
                    repositorySelectionSection

                    // Layout picker (when 2+ repos selected)
                    if selectedRepoPaths.count >= 2 {
                        layoutPickerSection
                    }

                    // Quick start / slash commands
                    if !commandsService.commands.isEmpty {
                        quickStartSection
                    }
                }
                .padding(24)
            }

            Spacer()

            // Prompt input at bottom (Claude chat style)
            promptInputSection
        }
        .background(TokyoNight.backgroundPrimary)
        .onAppear {
            // Auto-select most recent repo if none selected
            if selectedRepoPaths.isEmpty, let mostRecent = settings.recentRepositories.first {
                selectedRepoPaths.insert(mostRecent.path)
            }
        }
    }

    // MARK: - Header

    private var composerHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 28))
                .foregroundStyle(
                    LinearGradient(
                        colors: [TokyoNight.accentCyan, TokyoNight.accentPurple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("New Session")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(TokyoNight.textPrimary)

            Text("Select repositories and describe your task")
                .font(.system(size: 13))
                .foregroundColor(TokyoNight.textSecondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Repository Selection

    private var repositorySelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repositories")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TokyoNight.textSecondary)

                Spacer()

                // Selection count
                if !selectedRepoPaths.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(selectedRepoPaths.count) selected")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textSecondary)

                        if selectedRepoPaths.count >= maxSelectedRepos {
                            Text("(max)")
                                .font(.system(size: 11))
                                .foregroundColor(TokyoNight.statusWaiting)
                        }

                        Button("Clear") {
                            selectedRepoPaths.removeAll()
                        }
                        .font(.system(size: 11))
                        .foregroundColor(TokyoNight.textMuted)
                        .buttonStyle(.plain)
                    }
                }

                Button("Browse...") {
                    selectDirectory()
                }
                .font(.system(size: 12))
                .foregroundColor(TokyoNight.accentCyan)
                .buttonStyle(.plain)
            }

            // Repository chips
            if settings.recentRepositories.isEmpty {
                emptyRepositoriesPrompt
            } else {
                repositoryChipsGrid
            }
        }
    }

    private var emptyRepositoriesPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 24))
                .foregroundColor(TokyoNight.textMuted)

            Text("No recent repositories")
                .font(.system(size: 13))
                .foregroundColor(TokyoNight.textMuted)

            Button("Add Repository...") {
                selectDirectory()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(TokyoNight.accentCyan.opacity(0.2))
            .foregroundColor(TokyoNight.accentCyan)
            .cornerRadius(8)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(TokyoNight.backgroundCard)
        .cornerRadius(12)
    }

    private var repositoryChipsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            ForEach(settings.recentRepositories.prefix(8)) { repo in
                RepoSelectionChip(
                    repo: repo,
                    isSelected: selectedRepoPaths.contains(repo.path),
                    isDisabled: !selectedRepoPaths.contains(repo.path) && selectedRepoPaths.count >= maxSelectedRepos,
                    onToggle: {
                        toggleRepoSelection(repo.path)
                    }
                )
            }
        }
    }

    private func toggleRepoSelection(_ path: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedRepoPaths.contains(path) {
                selectedRepoPaths.remove(path)
            } else if selectedRepoPaths.count < maxSelectedRepos {
                selectedRepoPaths.insert(path)
            }
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        if settings.directoryExists(settings.defaultProjectsDirectory) {
            panel.directoryURL = URL(fileURLWithPath: settings.defaultProjectsDirectory)
        }

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                settings.addRecentRepository(path: path)
                if selectedRepoPaths.count < maxSelectedRepos {
                    selectedRepoPaths.insert(path)
                }
            }
        }
    }

    // MARK: - Layout Picker

    private var layoutPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            HStack(spacing: 8) {
                ForEach(GridLayout.allCases, id: \.self) { layout in
                    LayoutChip(
                        layout: layout,
                        repoCount: selectedRepoPaths.count,
                        isSelected: selectedLayout == layout,
                        onSelect: { selectedLayout = layout }
                    )
                }
            }
        }
    }

    // MARK: - Quick Start

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TokyoNight.textSecondary)

                Text("(optional)")
                    .font(.system(size: 11))
                    .foregroundColor(TokyoNight.textMuted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(commandsService.commands.prefix(8)) { command in
                        QuickStartCommandChip(
                            command: command,
                            isSelected: selectedCommand?.id == command.id,
                            onTap: {
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
                        )
                    }
                }
            }
        }
    }

    // MARK: - Prompt Input

    private var promptInputSection: some View {
        VStack(spacing: 0) {
            Divider()
                .background(TokyoNight.borderColor)

            HStack(alignment: .bottom, spacing: 12) {
                // Text input
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What would you like Claude to help with?")
                            .font(.system(size: 14))
                            .foregroundColor(TokyoNight.textMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }

                    TextEditor(text: $prompt)
                        .font(.system(size: 14))
                        .foregroundColor(TokyoNight.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 40, maxHeight: 120)
                }
                .padding(12)
                .background(TokyoNight.backgroundCard)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            prompt.isEmpty ? TokyoNight.borderColor : TokyoNight.accentCyan.opacity(0.5),
                            lineWidth: 1
                        )
                )

                // Launch button
                Button(action: launchSession) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            canLaunch ?
                            LinearGradient(
                                colors: [TokyoNight.accentCyan, TokyoNight.accentPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ) :
                            LinearGradient(
                                colors: [TokyoNight.textMuted, TokyoNight.textMuted],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canLaunch)
            }
            .padding(16)
            .background(TokyoNight.backgroundSecondary)
        }
    }

    private var canLaunch: Bool {
        !selectedRepoPaths.isEmpty
    }

    private func launchSession() {
        guard canLaunch else { return }

        let repoPaths = Array(selectedRepoPaths)
        let layout = selectedRepoPaths.count > 1 ? selectedLayout : .auto

        onLaunchGroup(repoPaths, layout, prompt)

        // Reset state
        prompt = ""
        selectedCommand = nil
    }
}

// MARK: - Repo Selection Chip

struct RepoSelectionChip: View {
    let repo: RecentRepository
    let isSelected: Bool
    let isDisabled: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? TokyoNight.accentCyan : TokyoNight.borderColor, lineWidth: 1.5)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(TokyoNight.accentCyan)
                            .frame(width: 18, height: 18)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                // Folder icon
                ZStack {
                    Circle()
                        .fill(isSelected ? TokyoNight.accentCyan.opacity(0.2) : TokyoNight.backgroundSecondary)
                        .frame(width: 32, height: 32)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? TokyoNight.accentCyan : TokyoNight.textSecondary)
                }

                // Repo info
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isDisabled ? TokyoNight.textMuted : TokyoNight.textPrimary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(10)
            .background(
                isSelected ? TokyoNight.accentCyan.opacity(0.1) :
                    (isHovered && !isDisabled ? TokyoNight.backgroundCardHover : TokyoNight.backgroundCard)
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? TokyoNight.accentCyan : TokyoNight.borderColor, lineWidth: 1)
            )
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(repo.path)
    }
}

// MARK: - Layout Chip

struct LayoutChip: View {
    let layout: GridLayout
    let repoCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                layoutIcon
                    .font(.system(size: 16))

                Text(layout.displayName)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? TokyoNight.accentCyan : TokyoNight.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? TokyoNight.accentCyan.opacity(0.15) :
                    (isHovered ? TokyoNight.backgroundCardHover : TokyoNight.backgroundCard)
            )
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? TokyoNight.accentCyan : TokyoNight.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var layoutIcon: some View {
        switch layout {
        case .auto:
            Image(systemName: "square.grid.2x2")
        case .horizontal:
            Image(systemName: "rectangle.split.3x1")
        case .vertical:
            Image(systemName: "rectangle.split.1x2")
        case .grid2x2:
            Image(systemName: "square.grid.2x2")
        case .grid2x3:
            Image(systemName: "rectangle.grid.2x2")
        case .grid2x4:
            Image(systemName: "rectangle.grid.2x2")
        }
    }
}

// MARK: - Quick Start Command Chip

private struct QuickStartCommandChip: View {
    let command: SlashCommand
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text("/\(command.name)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isSelected ? TokyoNight.backgroundPrimary : TokyoNight.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? TokyoNight.accentCyan :
                        (isHovered ? TokyoNight.backgroundCardHover : TokyoNight.backgroundSecondary)
                )
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? TokyoNight.accentCyan : TokyoNight.borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(command.description ?? command.name)
    }
}
