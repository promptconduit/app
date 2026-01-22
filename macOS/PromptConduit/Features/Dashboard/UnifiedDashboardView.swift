import SwiftUI
import SwiftTerm

// MARK: - Design Tokens (Tokyo Night theme)

enum TokyoNight {
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

    // Status colors
    static let statusRunning = Color(red: 0.62, green: 0.81, blue: 0.42)   // Green
    static let statusWaiting = Color(red: 0.88, green: 0.69, blue: 0.41)   // Yellow/Orange
    static let statusIdle = Color(red: 0.34, green: 0.37, blue: 0.53)      // Gray
    static let statusError = Color(red: 0.97, green: 0.47, blue: 0.47)     // Red
}

// MARK: - Sidebar View Mode

enum SidebarViewMode: String, CaseIterable {
    case byGroup = "By Group"
    case byRepo = "By Repo"
}

// MARK: - Dashboard Tab

enum DashboardTab: String, CaseIterable {
    case sessions = "Sessions"
    case semantic = "Semantic"
    case patterns = "Patterns"
    case skills = "Skills"

    var icon: String {
        switch self {
        case .sessions: return "terminal.fill"
        case .semantic: return "brain"
        case .patterns: return "rectangle.3.group"
        case .skills: return "command.square"
        }
    }
}

// MARK: - Unified Dashboard View

struct UnifiedDashboardView: View {
    @StateObject private var settings = SettingsService.shared
    @StateObject private var discovery = ClaudeSessionDiscovery.shared
    @StateObject private var indexService = TranscriptIndexService.shared
    @StateObject private var patternService = PatternDetectionService.shared
    @StateObject private var commandsService = SlashCommandsService.shared
    @StateObject private var terminalManager = TerminalSessionManager.shared

    // Sidebar state
    @State private var sidebarViewMode: SidebarViewMode = .byGroup
    @State private var selectedTab: DashboardTab = .sessions

    // Selection state
    @State private var selectedGroupId: UUID?
    @State private var selectedSession: DiscoveredSession?
    @State private var selectedSearchResult: TranscriptSearchResult?
    @State private var selectedPattern: DetectedPattern?
    @State private var selectedSkill: SlashCommand?

    // Search state
    @State private var searchText: String = ""

    // Pattern/Skill state
    @State private var expandedPatternId: UUID?
    @State private var showSaveSkillSheet = false
    @State private var showDeleteSkillConfirmation = false
    @State private var savedSkillPath: String?

    // Deep link highlight state
    @State private var highlightedSessionId: UUID?
    @State private var highlightOpacity: Double = 0

    // Callbacks
    let onResumeSession: (DiscoveredSession) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            TokyoNight.backgroundPrimary.ignoresSafeArea()

            // Main content area
            HSplitView {
                // Sidebar
                sidebar
                    .frame(minWidth: 280, maxWidth: 400)

                // Content area
                contentArea
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .onAppear {
            discovery.startMonitoring()
            // Start indexing when dashboard opens
            indexService.startIndexing()
        }
        .onDisappear {
            discovery.stopMonitoring()
        }
        .onChange(of: selectedTab) { _, newTab in
            // Clear tab-specific selections when switching tabs
            selectedSearchResult = nil
            selectedPattern = nil
            selectedSkill = nil
            searchText = ""

            // Start pattern detection when switching to patterns mode
            if newTab == .patterns && patternService.patterns.isEmpty && !patternService.isAnalyzing {
                patternService.detectPatterns()
            }

            // Reload skills when switching to skills mode
            if newTab == .skills {
                commandsService.reload()
            }
        }
        .sheet(isPresented: $showSaveSkillSheet) {
            if let pattern = selectedPattern {
                SaveSkillSheet(
                    pattern: pattern,
                    isPresented: $showSaveSkillSheet,
                    onSave: { path in
                        savedSkillPath = path
                    }
                )
            }
        }
        .alert("Skill Saved", isPresented: .init(
            get: { savedSkillPath != nil },
            set: { if !$0 { savedSkillPath = nil } }
        )) {
            Button("OK") { savedSkillPath = nil }
            Button("Open in Finder") {
                if let path = savedSkillPath {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                savedSkillPath = nil
            }
        } message: {
            if let path = savedSkillPath {
                Text("Skill saved to:\n\(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSessionGroup)) { notification in
            handleNavigateToSessionGroupNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTerminalSession)) { notification in
            handleNavigateToTerminalSessionNotification(notification)
        }
    }

    // MARK: - Notification Handlers

    private func handleNavigateToSessionGroupNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let groupId = userInfo["groupId"] as? UUID else {
            return
        }

        selectedGroupId = groupId
        selectedSession = nil
        sidebarViewMode = .byGroup

        // Check if we should highlight a specific session
        if let sessionId = userInfo["highlightSessionId"] as? UUID {
            highlightSession(sessionId)
        }
    }

    private func handleNavigateToTerminalSessionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["sessionId"] as? UUID else {
            return
        }

        // Find the session in terminal manager
        if let session = terminalManager.session(for: sessionId) {
            if let groupId = session.groupId {
                // Navigate to the group and highlight the session
                selectedGroupId = groupId
                selectedSession = nil
                sidebarViewMode = .byGroup
                highlightSession(sessionId)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header with view toggle
            sidebarHeader

            // Tab bar (content type selector)
            sidebarTabBar

            Divider()
                .background(TokyoNight.borderColor)

            // Search bar
            searchBar

            // View mode toggle (only for Sessions tab)
            if selectedTab == .sessions {
                viewModePicker
            }

            // Sidebar content based on view mode and selected tab
            if selectedTab == .sessions {
                if sidebarViewMode == .byGroup {
                    groupsListView
                } else {
                    repoSessionsListView
                }
            } else {
                // Other tabs show placeholder or their content
                otherTabContent
            }

            // Footer with stats
            sidebarFooter
        }
        .background(TokyoNight.backgroundSecondary)
    }

    @ViewBuilder
    private var otherTabContent: some View {
        switch selectedTab {
        case .sessions:
            EmptyView()  // Should not happen
        case .semantic:
            semanticSidebarContent
        case .patterns:
            patternsSidebarContent
        case .skills:
            skillsSidebarContent
        }
    }

    // MARK: - Semantic Sidebar Content

    private var semanticSidebarContent: some View {
        Group {
            if indexService.isIndexing {
                // Indexing in progress
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                    Text("Indexing transcripts...")
                        .font(.system(size: 14))
                        .foregroundColor(TokyoNight.textSecondary)

                    Text("\(indexService.indexedCount) / \(indexService.totalCount) sessions")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)

                    ProgressView(value: indexService.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                        .tint(TokyoNight.accentPurple)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchText.isEmpty {
                // Prompt to search
                VStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 32))
                        .foregroundColor(TokyoNight.accentPurple)

                    Text("Semantic Search")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(TokyoNight.textPrimary)

                    Text("Search across all transcripts using natural language.\nPress Enter to search.")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                        .multilineTextAlignment(.center)

                    if indexService.messageCount > 0 {
                        Text("\(indexService.messageCount) messages indexed from \(indexService.sessionCount) sessions")
                            .font(.system(size: 11))
                            .foregroundColor(TokyoNight.textMuted)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if indexService.searchResults.isEmpty {
                // No results
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(TokyoNight.textMuted)

                    Text("No results found")
                        .font(.system(size: 14))
                        .foregroundColor(TokyoNight.textMuted)

                    Text("Try a different search query")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Search results
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(indexService.searchResults) { result in
                            SearchResultRow(
                                result: result,
                                isSelected: selectedSearchResult?.id == result.id,
                                onSelect: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedSearchResult = result
                                        selectedSession = nil
                                        selectedPattern = nil
                                        selectedSkill = nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Patterns Sidebar Content

    private var filteredPatterns: [DetectedPattern] {
        if searchText.isEmpty {
            return patternService.patterns
        }
        return patternService.patterns.filter {
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var patternsSidebarContent: some View {
        Group {
            if patternService.isAnalyzing {
                // Analyzing in progress
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                    Text("Analyzing patterns...")
                        .font(.system(size: 14))
                        .foregroundColor(TokyoNight.textSecondary)

                    Text("Finding similar prompts across your sessions")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if patternService.patterns.isEmpty {
                // No patterns found
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 32))
                        .foregroundColor(TokyoNight.textMuted)

                    Text("No Patterns Found")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(TokyoNight.textPrimary)

                    Text("Patterns will appear when you have similar prompts\nacross multiple sessions.")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                        .multilineTextAlignment(.center)

                    if indexService.messageCount > 0 {
                        Button(action: { patternService.detectPatterns() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Analyze Patterns")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(TokyoNight.accentPurple.opacity(0.2))
                            .foregroundColor(TokyoNight.accentPurple)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Pattern list
                VStack(spacing: 8) {
                    // Header with count and refresh
                    HStack {
                        Text("\(patternService.patterns.count) patterns detected")
                            .font(.system(size: 11))
                            .foregroundColor(TokyoNight.textMuted)

                        Spacer()

                        Button(action: { patternService.detectPatterns() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(TokyoNight.accentPurple)
                        }
                        .buttonStyle(.plain)
                        .help("Re-analyze patterns")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredPatterns) { pattern in
                                PatternRow(
                                    pattern: pattern,
                                    isSelected: selectedPattern?.id == pattern.id,
                                    isExpanded: expandedPatternId == pattern.id,
                                    onSelect: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedPattern = pattern
                                            selectedSession = nil
                                            selectedSearchResult = nil
                                            selectedSkill = nil
                                        }
                                    },
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if expandedPatternId == pattern.id {
                                                expandedPatternId = nil
                                            } else {
                                                expandedPatternId = pattern.id
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
    }

    // MARK: - Skills Sidebar Content

    private var filteredSkills: [SlashCommand] {
        if searchText.isEmpty {
            return commandsService.commands
        }
        return commandsService.commands.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var skillsSidebarContent: some View {
        Group {
            if commandsService.isLoading {
                // Loading
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)

                    Text("Loading skills...")
                        .font(.system(size: 14))
                        .foregroundColor(TokyoNight.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commandsService.commands.isEmpty {
                // No skills found
                VStack(spacing: 12) {
                    Image(systemName: "command.square")
                        .font(.system(size: 32))
                        .foregroundColor(TokyoNight.textMuted)

                    Text("No Skills Found")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(TokyoNight.textPrimary)

                    Text("Skills are slash commands stored in\n~/.claude/commands/ or [project]/.claude/commands/")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                        .multilineTextAlignment(.center)

                    Button(action: { commandsService.reload() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(TokyoNight.accentCyan.opacity(0.2))
                        .foregroundColor(TokyoNight.accentCyan)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Skills list
                VStack(spacing: 8) {
                    // Header with count and refresh
                    HStack {
                        Text("\(commandsService.commands.count) skills")
                            .font(.system(size: 11))
                            .foregroundColor(TokyoNight.textMuted)

                        Spacer()

                        Button(action: { commandsService.reload() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(TokyoNight.accentCyan)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh skills")
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            // Global skills section
                            if !commandsService.globalSkills.isEmpty {
                                SkillSectionHeader(title: "Global Skills", count: filteredSkills.filter { $0.location == .global }.count, isProject: false)
                                ForEach(filteredSkills.filter { $0.location == .global }) { skill in
                                    SkillRow(
                                        skill: skill,
                                        isSelected: selectedSkill?.id == skill.id,
                                        onSelect: { selectSkill(skill) }
                                    )
                                }
                            }

                            // Project skills grouped by repo
                            ForEach(commandsService.sortedProjectPaths, id: \.self) { projectPath in
                                let skills = commandsService.skillsByProject[projectPath] ?? []
                                let filteredProjectSkills = skills.filter { filteredSkills.contains($0) }
                                if !filteredProjectSkills.isEmpty {
                                    let repoName = URL(fileURLWithPath: projectPath).lastPathComponent
                                    SkillSectionHeader(title: repoName, count: filteredProjectSkills.count, isProject: true)
                                    ForEach(filteredProjectSkills) { skill in
                                        SkillRow(
                                            skill: skill,
                                            isSelected: selectedSkill?.id == skill.id,
                                            onSelect: { selectSkill(skill) }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
        }
    }

    private func selectSkill(_ skill: SlashCommand) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedSkill = skill
            selectedSession = nil
            selectedSearchResult = nil
            selectedPattern = nil
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Text(selectedTab.rawValue)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(TokyoNight.textPrimary)

            Spacer()

            // New Session button (only for Sessions tab)
            if selectedTab == .sessions {
                Button(action: {
                    selectedGroupId = nil
                    selectedSession = nil
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(TokyoNight.accentCyan)
                }
                .buttonStyle(.plain)
                .help("New Session")
            }
        }
        .padding(16)
    }

    private var sidebarTabBar: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.self) { tab in
                Button(action: {
                    selectedTab = tab
                    // Clear selection when switching tabs to avoid confusion
                    if tab != .sessions {
                        selectedGroupId = nil
                        selectedSession = nil
                    }
                }) {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14))
                        Text(tab.rawValue)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(selectedTab == tab ? TokyoNight.accentCyan : TokyoNight.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selectedTab == tab ? TokyoNight.accentCyan.opacity(0.1) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(TokyoNight.backgroundPrimary.opacity(0.5))
    }

    private var searchBarPlaceholder: String {
        switch selectedTab {
        case .sessions: return "Filter sessions..."
        case .semantic: return "Semantic search... (press Enter)"
        case .patterns: return "Filter patterns..."
        case .skills: return "Filter skills..."
        }
    }

    private var searchBarIcon: String {
        selectedTab == .semantic ? "brain" : "line.3.horizontal.decrease"
    }

    private var searchBarIconColor: SwiftUI.Color {
        selectedTab == .semantic ? TokyoNight.accentPurple : TokyoNight.textMuted
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: searchBarIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(searchBarIconColor)

            TextField(searchBarPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(TokyoNight.textPrimary)
                .onSubmit {
                    if selectedTab == .semantic && !searchText.isEmpty {
                        indexService.search(query: searchText)
                    }
                }

            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    if selectedTab == .semantic {
                        indexService.clearSearch()
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(TokyoNight.textMuted)
                }
                .buttonStyle(.plain)
            }

            // Indexing progress indicator for semantic tab
            if selectedTab == .semantic && indexService.isIndexing {
                ProgressView(value: indexService.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 50)
                    .tint(TokyoNight.accentPurple)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TokyoNight.backgroundCard.opacity(0.6))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(TokyoNight.borderColor.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var viewModePicker: some View {
        Picker("View Mode", selection: $sidebarViewMode) {
            ForEach(SidebarViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Groups List View (By Group mode)

    private var filteredActiveGroups: [SessionGroup] {
        let active = settings.activeSessionGroups()
        if searchText.isEmpty {
            return active
        }
        return active.filter { group in
            group.displayName.localizedCaseInsensitiveContains(searchText) ||
            group.prompt.localizedCaseInsensitiveContains(searchText) ||
            group.repoPaths.contains { path in
                URL(fileURLWithPath: path).lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private var filteredRecentGroups: [SessionGroup] {
        let recent = settings.recentSessionGroups(limit: 10)
        if searchText.isEmpty {
            return recent
        }
        return recent.filter { group in
            group.displayName.localizedCaseInsensitiveContains(searchText) ||
            group.prompt.localizedCaseInsensitiveContains(searchText) ||
            group.repoPaths.contains { path in
                URL(fileURLWithPath: path).lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private var groupsListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Active groups section
                if !filteredActiveGroups.isEmpty {
                    GroupSectionHeader(title: "Active", count: filteredActiveGroups.count)

                    ForEach(filteredActiveGroups) { group in
                        SessionGroupRow(
                            group: group,
                            isSelected: selectedGroupId == group.id,
                            isHighlighted: false,
                            onSelect: {
                                selectedGroupId = group.id
                                selectedSession = nil
                            }
                        )
                    }
                }

                // Recent groups section
                if !filteredRecentGroups.isEmpty {
                    GroupSectionHeader(title: "Recent", count: filteredRecentGroups.count)

                    ForEach(filteredRecentGroups) { group in
                        SessionGroupRow(
                            group: group,
                            isSelected: selectedGroupId == group.id,
                            isHighlighted: false,
                            onSelect: {
                                selectedGroupId = group.id
                                selectedSession = nil
                            }
                        )
                    }
                }

                // Empty state
                if filteredActiveGroups.isEmpty && filteredRecentGroups.isEmpty {
                    if searchText.isEmpty {
                        emptyGroupsState
                    } else {
                        noMatchingGroupsState
                    }
                }
            }
            .padding(8)
        }
    }

    private var noMatchingGroupsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(TokyoNight.textMuted)

            Text("No matching sessions")
                .font(.system(size: 14))
                .foregroundColor(TokyoNight.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyGroupsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 32))
                .foregroundColor(TokyoNight.textMuted)

            Text("No session groups yet")
                .font(.system(size: 14))
                .foregroundColor(TokyoNight.textMuted)

            Text("Select repos and enter a prompt to start")
                .font(.system(size: 12))
                .foregroundColor(TokyoNight.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Repo Sessions List View (By Repo mode)

    private var repoSessionsListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredRepoGroups) { group in
                    RepoGroupRow(
                        group: group,
                        selectedSessionId: selectedSession?.id,
                        onToggle: { discovery.toggleExpanded(group.id) },
                        onSelectSession: { session in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedSession = session
                                selectedGroupId = nil
                            }
                        }
                    )
                }

                if filteredRepoGroups.isEmpty {
                    emptyRepoSessionsState
                }
            }
            .padding(8)
        }
    }

    private var filteredRepoGroups: [RepoSessionGroup] {
        if searchText.isEmpty {
            return discovery.repoGroups
        }

        return discovery.repoGroups.compactMap { group in
            let filteredSessions = group.sessions.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.repoName.localizedCaseInsensitiveContains(searchText)
            }

            if filteredSessions.isEmpty && !group.displayName.localizedCaseInsensitiveContains(searchText) {
                return nil
            }

            var filtered = group
            if !filteredSessions.isEmpty {
                filtered.sessions = filteredSessions
            }
            return filtered
        }
    }

    private var emptyRepoSessionsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundColor(TokyoNight.textMuted)

            Text(searchText.isEmpty ? "No sessions found" : "No matching sessions")
                .font(.system(size: 14))
                .foregroundColor(TokyoNight.textMuted)

            if searchText.isEmpty {
                Text("Start a Claude Code session to see it here")
                    .font(.system(size: 12))
                    .foregroundColor(TokyoNight.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var sidebarFooter: some View {
        HStack {
            if let lastRefresh = discovery.lastRefresh {
                Circle()
                    .fill(TokyoNight.statusRunning)
                    .frame(width: 6, height: 6)
                Text("Updated \(lastRefresh, formatter: timeFormatter)")
                    .font(.system(size: 10))
                    .foregroundColor(TokyoNight.textMuted)
            }

            Spacer()

            Button(action: { discovery.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(TokyoNight.accentCyan)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch selectedTab {
        case .sessions:
            sessionsContentArea
        case .semantic:
            semanticContentArea
        case .patterns:
            patternsContentArea
        case .skills:
            skillsContentArea
        }
    }

    @ViewBuilder
    private var sessionsContentArea: some View {
        if let groupId = selectedGroupId, let group = settings.sessionGroup(for: groupId) {
            // Show terminal grid for selected group
            sessionGroupContentView(group)
        } else if let session = selectedSession {
            // Show session detail for selected individual session
            SessionDetailView(
                session: session,
                onResume: { onResumeSession(session) }
            )
        } else {
            // Show session composer (no selection)
            SessionComposerView(
                onLaunchGroup: { repoPaths, layout, prompt in
                    launchSessionGroup(repoPaths: repoPaths, layout: layout, prompt: prompt)
                }
            )
        }
    }

    @ViewBuilder
    private var semanticContentArea: some View {
        if let result = selectedSearchResult {
            searchResultDetail(result)
        } else {
            // Empty state
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "brain")
                    .font(.system(size: 48))
                    .foregroundColor(TokyoNight.textMuted)
                Text("Semantic Search")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TokyoNight.textPrimary)
                Text("Search across all your Claude Code sessions using natural language.\nEnter a query in the sidebar and press Enter to search.")
                    .font(.system(size: 14))
                    .foregroundColor(TokyoNight.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TokyoNight.backgroundPrimary)
        }
    }

    @ViewBuilder
    private var patternsContentArea: some View {
        if let pattern = selectedPattern {
            patternDetail(pattern)
        } else {
            // Empty state
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 48))
                    .foregroundColor(TokyoNight.textMuted)
                Text("Pattern Detection")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TokyoNight.textPrimary)
                Text("Detect repeated prompts across sessions and save them as reusable skills.\nSelect a pattern from the sidebar to view details.")
                    .font(.system(size: 14))
                    .foregroundColor(TokyoNight.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TokyoNight.backgroundPrimary)
        }
    }

    @ViewBuilder
    private var skillsContentArea: some View {
        if let skill = selectedSkill {
            skillDetail(skill)
        } else {
            // Empty state
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "command.square")
                    .font(.system(size: 48))
                    .foregroundColor(TokyoNight.textMuted)
                Text("Skills Management")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(TokyoNight.textPrimary)
                Text("Browse, edit, and delete your Claude Code skills (slash commands).\nSelect a skill from the sidebar to view details.")
                    .font(.system(size: 14))
                    .foregroundColor(TokyoNight.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TokyoNight.backgroundPrimary)
        }
    }

    // MARK: - Search Result Detail

    private func searchResultDetail(_ result: TranscriptSearchResult) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Similarity badge
                        Text("\(result.matchPercentage)% match")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(TokyoNight.backgroundPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(TokyoNight.accentPurple)
                            .cornerRadius(4)

                        Text(result.message.messageType == "user" ? "User Prompt" : "Assistant Response")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(TokyoNight.textSecondary)
                    }

                    HStack(spacing: 12) {
                        Label(URL(fileURLWithPath: result.message.repoPath).lastPathComponent, systemImage: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textSecondary)

                        Text("•")
                            .foregroundColor(TokyoNight.textMuted)

                        Text(formatDate(result.message.timestamp))
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textMuted)
                    }
                }

                Spacer()

                // Find session button
                Button(action: {
                    // Find and select the session
                    for group in discovery.repoGroups {
                        if let session = group.sessions.first(where: { $0.id == result.message.sessionId }) {
                            selectedSession = session
                            selectedSearchResult = nil
                            selectedTab = .sessions
                            sidebarViewMode = .byRepo
                            return
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle")
                        Text("Go to Session")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TokyoNight.accentCyan)
                    .foregroundColor(TokyoNight.backgroundPrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(TokyoNight.backgroundSecondary)

            Divider()
                .background(TokyoNight.borderColor)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Message content
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TokyoNight.textSecondary)

                        Text(result.message.content)
                            .font(.system(size: 13))
                            .foregroundColor(TokyoNight.textPrimary)
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TokyoNight.backgroundCard)
                            .cornerRadius(10)
                    }

                    // Details
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Details")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TokyoNight.textSecondary)

                        VStack(alignment: .leading, spacing: 8) {
                            DetailRow(label: "Session ID", value: result.message.sessionId)
                            DetailRow(label: "Message ID", value: result.message.messageUuid)
                            DetailRow(label: "Repository", value: result.message.repoPath)
                            DetailRow(label: "Similarity Score", value: String(format: "%.4f", result.similarity))
                        }
                        .padding(16)
                        .background(TokyoNight.backgroundCard)
                        .cornerRadius(10)
                    }

                    // Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TokyoNight.textSecondary)

                        HStack(spacing: 12) {
                            ActionButton(icon: "doc.on.doc", title: "Copy Content") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.message.content, forType: .string)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(TokyoNight.backgroundPrimary)
    }

    // MARK: - Pattern Detail

    private func patternDetail(_ pattern: DetectedPattern) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 14))
                            .foregroundColor(TokyoNight.accentPurple)

                        Text("Pattern")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(TokyoNight.textPrimary)
                    }

                    HStack(spacing: 12) {
                        Label("\(pattern.count) prompts", systemImage: "text.bubble")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textSecondary)

                        Text("•")
                            .foregroundColor(TokyoNight.textMuted)

                        Label("\(pattern.sessionCount) sessions", systemImage: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textMuted)

                        if pattern.repoCount > 1 {
                            Text("•")
                                .foregroundColor(TokyoNight.textMuted)

                            Label("\(pattern.repoCount) repos", systemImage: "externaldrive")
                                .font(.system(size: 12))
                                .foregroundColor(TokyoNight.textMuted)
                        }
                    }
                }

                Spacer()

                // Score badge
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                    Text(String(format: "%.1f", pattern.score.compositeScore))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(TokyoNight.accentPurple)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TokyoNight.accentPurple.opacity(0.15))
                .cornerRadius(6)

                // Save as Skill button
                Button(action: {
                    showSaveSkillSheet = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save as Skill")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(TokyoNight.accentCyan)
                    .foregroundColor(TokyoNight.backgroundPrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Save this pattern as a Claude Code skill")
            }
            .padding(20)
            .background(TokyoNight.backgroundSecondary)

            Divider()
                .background(TokyoNight.borderColor)

            // Pattern content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Representative prompt
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Representative Prompt")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TokyoNight.textSecondary)

                        Text(pattern.representative.content)
                            .font(.system(size: 13))
                            .foregroundColor(TokyoNight.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(TokyoNight.backgroundCard)
                            .cornerRadius(8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // All similar prompts
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Similar Prompts (\(pattern.members.count))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(TokyoNight.textSecondary)

                        VStack(spacing: 4) {
                            ForEach(pattern.members) { member in
                                HStack(alignment: .top, spacing: 12) {
                                    // Similarity badge
                                    Text("\(Int(member.similarityToRepresentative * 100))%")
                                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                                        .foregroundColor(similarityColor(member.similarityToRepresentative))
                                        .frame(width: 36)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(member.message.content)
                                            .font(.system(size: 12))
                                            .foregroundColor(TokyoNight.textPrimary)
                                            .lineLimit(2)

                                        HStack(spacing: 8) {
                                            Text(member.message.sessionId.prefix(8) + "...")
                                                .font(.system(size: 10))
                                                .foregroundColor(TokyoNight.textMuted)

                                            Text("•")
                                                .foregroundColor(TokyoNight.textMuted)
                                                .font(.system(size: 8))

                                            Text(formatPatternDate(member.message.timestamp))
                                                .font(.system(size: 10))
                                                .foregroundColor(TokyoNight.textMuted)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(TokyoNight.backgroundCard)
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(TokyoNight.backgroundPrimary)
    }

    // MARK: - Skill Detail

    private func skillDetail(_ skill: SlashCommand) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "command.square.fill")
                            .font(.system(size: 14))
                            .foregroundColor(TokyoNight.accentCyan)

                        Text("/\(skill.name)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(TokyoNight.textPrimary)

                        // Location badge
                        Text(skill.location.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(skill.location == .global ? TokyoNight.accentPurple : TokyoNight.accentCyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (skill.location == .global ? TokyoNight.accentPurple : TokyoNight.accentCyan)
                                    .opacity(0.15)
                            )
                            .cornerRadius(6)
                    }

                    if let description = skill.description {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundColor(TokyoNight.textSecondary)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: { openSkillInFinder(skill) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("Reveal")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(TokyoNight.backgroundCard)
                        .foregroundColor(TokyoNight.textPrimary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: { editSkill(skill) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(TokyoNight.accentCyan)
                        .foregroundColor(TokyoNight.backgroundPrimary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: { showDeleteSkillConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .padding(8)
                            .background(TokyoNight.statusError.opacity(0.15))
                            .foregroundColor(TokyoNight.statusError)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .background(TokyoNight.backgroundSecondary)

            Divider()
                .background(TokyoNight.borderColor)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Metadata section
                    if skill.allowedTools != nil || skill.argumentHint != nil {
                        skillMetadataSection(skill)
                    }

                    // Prompt content section
                    skillPromptSection(skill)

                    // File location section
                    skillFileSection(skill)
                }
                .padding(20)
            }
        }
        .background(TokyoNight.backgroundPrimary)
        .alert("Delete Skill", isPresented: $showDeleteSkillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSkill(skill)
            }
        } message: {
            Text("Are you sure you want to delete /\(skill.name)? This action cannot be undone.")
        }
    }

    private func skillMetadataSection(_ skill: SlashCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            HStack(spacing: 24) {
                if let allowedTools = skill.allowedTools {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed Tools")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TokyoNight.textMuted)
                        Text(allowedTools)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(TokyoNight.textSecondary)
                    }
                }

                if let argumentHint = skill.argumentHint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Argument")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TokyoNight.textMuted)
                        Text(argumentHint)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(TokyoNight.textSecondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TokyoNight.backgroundCard)
            .cornerRadius(10)
        }
    }

    private func skillPromptSection(_ skill: SlashCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt Content")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            ScrollView {
                Text(skill.prompt)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(TokyoNight.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .padding(16)
            .background(TokyoNight.backgroundCard)
            .cornerRadius(10)
        }
    }

    private func skillFileSection(_ skill: SlashCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Location")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(TokyoNight.textMuted)
                Text(skill.displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(TokyoNight.textSecondary)
                Spacer()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(skill.filePath, forType: .string)
                }
                .font(.system(size: 11))
                .foregroundColor(TokyoNight.accentCyan)
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(TokyoNight.backgroundCard)
            .cornerRadius(8)
        }
    }

    // MARK: - Skill Actions

    private func openSkillInFinder(_ skill: SlashCommand) {
        NSWorkspace.shared.selectFile(skill.filePath, inFileViewerRootedAtPath: "")
    }

    private func editSkill(_ skill: SlashCommand) {
        NSWorkspace.shared.open(URL(fileURLWithPath: skill.filePath))
    }

    private func deleteSkill(_ skill: SlashCommand) {
        commandsService.deleteCommand(skill)
        selectedSkill = nil
    }

    // MARK: - Pattern Helpers

    private func similarityColor(_ similarity: Double) -> SwiftUI.Color {
        if similarity >= 0.9 {
            return TokyoNight.statusRunning
        } else if similarity >= 0.8 {
            return TokyoNight.accentCyan
        } else if similarity >= 0.7 {
            return TokyoNight.statusWaiting
        } else {
            return TokyoNight.textMuted
        }
    }

    private func formatPatternDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func sessionGroupContentView(_ group: SessionGroup) -> some View {
        VStack(spacing: 0) {
            // Group header
            sessionGroupHeader(group)

            Divider()
                .background(TokyoNight.borderColor)

            // Terminal grid or completion state
            if group.isActive {
                // Show live terminals
                // Pass prompt only if not yet sent
                let promptToSend = group.promptSent ? nil : group.prompt
                MultiTerminalGridView(
                    groupId: group.id,
                    repositories: group.repoPaths,
                    layout: group.layout,
                    initialPrompt: promptToSend,
                    onClose: {
                        archiveGroup(group.id)
                        selectedGroupId = nil
                    }
                )
                .id(group.id)  // Force view recreation when switching groups
                .onAppear {
                    // Mark prompt as sent when the grid appears
                    if !group.promptSent {
                        settings.updateSessionGroup(id: group.id) { g in
                            g.markPromptSent()
                        }
                    }
                }
            } else {
                // Show completion state
                completedGroupView(group)
            }
        }
        .background(TokyoNight.backgroundPrimary)
    }

    private func sessionGroupHeader(_ group: SessionGroup) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SessionGroupStatusIndicator(status: group.status, size: 10)

                    Text(group.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(TokyoNight.textPrimary)
                }

                HStack(spacing: 12) {
                    Text("\(group.repoCount) repos")
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textSecondary)

                    Text("•")
                        .foregroundColor(TokyoNight.textMuted)

                    Text(group.relativeTime)
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textMuted)
                }
            }

            Spacer()

            if group.isActive {
                Button(action: { archiveGroup(group.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text("Close")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TokyoNight.backgroundCard)
                    .foregroundColor(TokyoNight.textSecondary)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(TokyoNight.backgroundSecondary)
    }

    private func completedGroupView(_ group: SessionGroup) -> some View {
        VStack(spacing: 20) {
            Image(systemName: group.status == .completed ? "checkmark.circle.fill" : "archivebox.fill")
                .font(.system(size: 48))
                .foregroundColor(group.status == .completed ? TokyoNight.statusRunning : TokyoNight.textMuted)

            Text(group.status == .completed ? "Session Completed" : "Session Archived")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(TokyoNight.textPrimary)

            if !group.prompt.isEmpty {
                Text(group.promptPreview)
                    .font(.system(size: 14))
                    .foregroundColor(TokyoNight.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            HStack(spacing: 16) {
                Button(action: {
                    // Relaunch with same settings
                    launchSessionGroup(repoPaths: group.repoPaths, layout: group.layout, prompt: group.prompt)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Relaunch")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TokyoNight.accentCyan)
                    .foregroundColor(TokyoNight.backgroundPrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    settings.deleteSessionGroup(group.id)
                    selectedGroupId = nil
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TokyoNight.backgroundCard)
                    .foregroundColor(TokyoNight.textSecondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    // MARK: - Actions

    private func launchSessionGroup(repoPaths: [String], layout: GridLayout, prompt: String) {
        // Create and save the session group
        let group = SessionGroup.create(
            prompt: prompt,
            repoPaths: repoPaths,
            layout: layout
        )
        settings.saveSessionGroup(group)

        // Add repos to recent
        for path in repoPaths {
            settings.addRecentRepository(path: path)
        }

        // Select the new group
        selectedGroupId = group.id
        selectedSession = nil

        // Note: The actual terminal launch will be handled by the MultiTerminalGridView
        // We need to integrate with TerminalSessionManager to actually launch
    }

    private func archiveGroup(_ groupId: UUID) {
        settings.archiveSessionGroup(groupId)
        terminalManager.terminateGroup(groupId)
    }

    // MARK: - Deep Linking

    func navigateToGroup(_ groupId: UUID, highlightSession sessionId: UUID? = nil) {
        selectedGroupId = groupId
        selectedSession = nil

        if let sessionId = sessionId {
            highlightSession(sessionId)
        }
    }

    func navigateToSession(_ sessionId: UUID) {
        // Find session in discovery
        for group in discovery.repoGroups {
            if let session = group.sessions.first(where: { $0.id == sessionId.uuidString }) {
                selectedSession = session
                selectedGroupId = nil
                sidebarViewMode = .byRepo
                return
            }
        }
    }

    private func highlightSession(_ sessionId: UUID) {
        highlightedSessionId = sessionId
        withAnimation(.easeIn(duration: 0.3)) {
            highlightOpacity = 1.0
        }

        // Fade after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeOut(duration: 0.5)) {
                highlightOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                highlightedSessionId = nil
            }
        }
    }
}

// MARK: - Group Section Header

struct GroupSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(TokyoNight.textMuted)
                .tracking(1)

            Text("(\(count))")
                .font(.system(size: 10))
                .foregroundColor(TokyoNight.textMuted)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}


// MARK: - Session Group Status Indicator

struct SessionGroupStatusIndicator: View {
    let status: SessionGroupStatus
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: size * 0.2)
            )
    }

    private var statusColor: SwiftUI.Color {
        switch status {
        case .active: return TokyoNight.statusRunning
        case .waiting: return TokyoNight.statusWaiting
        case .completed: return TokyoNight.statusIdle
        case .archived: return TokyoNight.textMuted
        }
    }
}

// MARK: - Session Detail View (for individual session selection)

struct SessionDetailView: View {
    let session: DiscoveredSession
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SessionStatusIndicator(status: session.status, size: 12)

                        Text(session.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(TokyoNight.textPrimary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 12) {
                        Label(session.repoName, systemImage: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textSecondary)

                        Text("•")
                            .foregroundColor(TokyoNight.textMuted)

                        Text("\(session.messageCount) messages")
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textMuted)

                        Text("•")
                            .foregroundColor(TokyoNight.textMuted)

                        Text(session.relativeTime)
                            .font(.system(size: 12))
                            .foregroundColor(TokyoNight.textMuted)
                    }
                }

                Spacer()

                Button(action: onResume) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(TokyoNight.accentCyan)
                    .foregroundColor(TokyoNight.backgroundPrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(TokyoNight.backgroundSecondary)

            Divider()
                .background(TokyoNight.borderColor)

            // Session details
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sessionInfoSection
                    actionsSection
                }
                .padding(20)
            }
        }
        .background(TokyoNight.backgroundPrimary)
    }

    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Session ID", value: session.id)
                DetailRow(label: "Repository", value: session.repoPath)
                DetailRow(label: "File", value: session.filePath)
                DetailRow(label: "Last Activity", value: formatDate(session.lastActivity))
            }
            .padding(16)
            .background(TokyoNight.backgroundCard)
            .cornerRadius(10)
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(TokyoNight.textSecondary)

            HStack(spacing: 12) {
                ActionButton(icon: "folder", title: "Open in Finder") {
                    NSWorkspace.shared.selectFile(session.filePath, inFileViewerRootedAtPath: "")
                }

                ActionButton(icon: "doc.on.doc", title: "Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TokyoNight.textMuted)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(TokyoNight.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(TokyoNight.backgroundCard)
            .foregroundColor(TokyoNight.textPrimary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(TokyoNight.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
