import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var agentPanelController: AgentPanelController?
    private var cancellables = Set<AnyCancellable>()
    private var hideShowAgentsMenuItem: NSMenuItem?

    // Menu items that need dynamic updates
    private var agentsMenuItems: [NSMenuItem] = []
    private var noAgentsMenuItem: NSMenuItem?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerGlobalHotkey()
        setupNotificationObservers()
        observeAgentChanges()

        // Initialize notification service for waiting state alerts
        NotificationService.shared.setup()

        // Initialize hook notification service for CLI hook events
        HookNotificationService.shared.startListening()

        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup PTY sessions
        AgentManager.shared.terminateAllSessions()

        // Close all agent panels
        agentPanelController?.closeAllPanels()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit")
            button.image?.isTemplate = true  // System-aware (white in dark mode, black in light mode)
            button.action = #selector(toggleMenu)
            button.target = self
        }

        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        // Header
        let headerItem = NSMenuItem(title: "PromptConduit", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // Active Agents Section
        let agentsHeader = NSMenuItem(title: "Active Agents", action: nil, keyEquivalent: "")
        agentsHeader.isEnabled = false
        agentsHeader.tag = 100  // Tag to identify the header
        menu.addItem(agentsHeader)

        // Placeholder for agents (will be updated dynamically)
        let noAgentsItem = NSMenuItem(title: "  No active agents", action: nil, keyEquivalent: "")
        noAgentsItem.isEnabled = false
        noAgentsItem.tag = 101  // Tag to identify the placeholder
        menu.addItem(noAgentsItem)
        self.noAgentsMenuItem = noAgentsItem

        // Separator after agents section
        let agentsSeparator = NSMenuItem.separator()
        agentsSeparator.tag = 102  // Tag to identify where agents section ends
        menu.addItem(agentsSeparator)

        // Actions
        let newAgentItem = NSMenuItem(title: "New Agent...", action: #selector(showNewAgentPanel), keyEquivalent: "n")
        newAgentItem.keyEquivalentModifierMask = [.command, .shift]
        newAgentItem.target = self
        menu.addItem(newAgentItem)

        let reposItem = NSMenuItem(title: "Repositories...", action: #selector(showReposWindow), keyEquivalent: "r")
        reposItem.keyEquivalentModifierMask = [.command, .shift]
        reposItem.target = self
        menu.addItem(reposItem)

        let dashboardItem = NSMenuItem(title: "Sessions Dashboard...", action: #selector(showSessionsDashboard), keyEquivalent: "d")
        dashboardItem.keyEquivalentModifierMask = [.command, .shift]
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        // Hide/Show All Agents
        let hideShowTitle = SettingsService.shared.allAgentsHidden ? "Show All Agents" : "Hide All Agents"
        let hideShowItem = NSMenuItem(title: hideShowTitle, action: #selector(toggleAgentsVisibility), keyEquivalent: "h")
        hideShowItem.target = self
        menu.addItem(hideShowItem)
        hideShowAgentsMenuItem = hideShowItem

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit PromptConduit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        // Handle "New Agent" from menu bar popover
        NotificationCenter.default.publisher(for: .showNewAgentPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showNewAgentPanel()
            }
            .store(in: &cancellables)

        // Handle "Show Agent" from menu bar popover (clicking on existing agent)
        NotificationCenter.default.publisher(for: .showAgentPanel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let session = notification.object as? AgentSession {
                    self?.showAgentPanel(for: session)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Agent Change Observers

    private func observeAgentChanges() {
        // Observe managed agents (from PromptConduit)
        AgentManager.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAgentsMenu()
            }
            .store(in: &cancellables)

        // Observe terminal sessions (launched from PromptConduit)
        TerminalSessionManager.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAgentsMenu()
            }
            .store(in: &cancellables)

        // Observe external Claude processes
        ProcessDetectionService.shared.$externalProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAgentsMenu()
            }
            .store(in: &cancellables)

        // Trigger initial update
        updateAgentsMenu()
    }

    private func updateAgentsMenu() {
        guard let menu = statusItem?.menu else { return }

        // Remove existing agent menu items
        for item in agentsMenuItems {
            menu.removeItem(item)
        }
        agentsMenuItems.removeAll()

        // Find insertion point (after the "Active Agents" header, tag 100)
        guard let headerIndex = menu.items.firstIndex(where: { $0.tag == 100 }) else { return }
        var insertIndex = headerIndex + 1

        let managedSessions = AgentManager.shared.sessions
        let terminalSessions = TerminalSessionManager.shared.sessions
        let externalProcesses = ProcessDetectionService.shared.externalProcesses

        let hasAnyAgents = !managedSessions.isEmpty || !terminalSessions.isEmpty || !externalProcesses.isEmpty

        // Show/hide "No active agents" placeholder
        noAgentsMenuItem?.isHidden = hasAnyAgents

        if hasAnyAgents {
            // Add managed sessions (PTY-based print mode)
            for (index, session) in managedSessions.enumerated() {
                let title = "  \(session.status.emoji) \(session.repoName)"
                let item = NSMenuItem(title: title, action: #selector(selectManagedAgent(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
                item.target = self
                item.representedObject = session
                if index < 9 {
                    item.keyEquivalentModifierMask = .command
                }
                menu.insertItem(item, at: insertIndex)
                agentsMenuItems.append(item)
                insertIndex += 1
            }

            // Add terminal sessions (launched from PromptConduit)
            for session in terminalSessions {
                // Yellow emoji when waiting for input
                let statusEmoji: String
                if session.isWaiting {
                    statusEmoji = "🟡"
                } else if session.isRunning {
                    statusEmoji = "🟢"
                } else {
                    statusEmoji = "🔴"
                }
                let waitingLabel = session.isWaiting ? " - Waiting" : ""
                let title = "  \(statusEmoji) \(session.repoName)\(waitingLabel)"
                let item = NSMenuItem(title: title, action: #selector(selectTerminalSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session
                menu.insertItem(item, at: insertIndex)
                agentsMenuItems.append(item)
                insertIndex += 1
            }

            // Add separator between managed/terminal and external if both exist
            let hasManagedOrTerminal = !managedSessions.isEmpty || !terminalSessions.isEmpty
            if hasManagedOrTerminal && !externalProcesses.isEmpty {
                let sep = NSMenuItem.separator()
                menu.insertItem(sep, at: insertIndex)
                agentsMenuItems.append(sep)
                insertIndex += 1

                let externalHeader = NSMenuItem(title: "  External Claude Code", action: nil, keyEquivalent: "")
                externalHeader.isEnabled = false
                menu.insertItem(externalHeader, at: insertIndex)
                agentsMenuItems.append(externalHeader)
                insertIndex += 1
            }

            // Add external processes (clickable to focus parent app)
            for process in externalProcesses {
                let appSuffix = process.parentAppName.map { " (\($0))" } ?? ""
                let title = "  🟢 \(process.displayName)\(appSuffix)"
                let item = NSMenuItem(title: title, action: #selector(selectExternalProcess(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = process
                menu.insertItem(item, at: insertIndex)
                agentsMenuItems.append(item)
                insertIndex += 1
            }
        }

        // Update status icon
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let manager = AgentManager.shared
        let terminalManager = TerminalSessionManager.shared
        let terminalRunningCount = terminalManager.sessions.filter { $0.isRunning }.count
        let terminalWaitingCount = terminalManager.waitingCount
        let externalCount = ProcessDetectionService.shared.externalProcesses.count

        // Show yellow when any session is waiting for input (PTY or terminal)
        if manager.waitingCount > 0 || terminalWaitingCount > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit - Waiting")
            button.image?.isTemplate = false  // Allow color tint
            button.contentTintColor = .systemYellow
        } else if manager.runningCount > 0 || terminalRunningCount > 0 || externalCount > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit - Running")
            button.image?.isTemplate = false  // Allow color tint
            button.contentTintColor = .systemGreen
        } else {
            // Idle - use template image (system-aware: white in dark mode, black in light mode)
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        }
    }

    @objc private func selectManagedAgent(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? AgentSession else { return }
        AgentManager.shared.setActiveSession(session)
        showAgentPanel(for: session)
    }

    @objc private func selectTerminalSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSessionInfo else { return }

        // Focus the specific terminal session
        TerminalSessionManager.shared.focusSession(session.id)
    }

    @objc private func selectExternalProcess(_ sender: NSMenuItem) {
        NSLog("[PromptConduit] selectExternalProcess called!")

        guard let process = sender.representedObject as? ExternalClaudeProcess else {
            NSLog("[PromptConduit] selectExternalProcess: No process in representedObject")
            // Show alert for debugging
            let alert = NSAlert()
            alert.messageText = "Debug: No process found"
            alert.informativeText = "representedObject is nil or wrong type"
            alert.runModal()
            return
        }

        NSLog("[PromptConduit] selectExternalProcess: %@, bundleId=%@, appName=%@", process.displayName, process.parentAppBundleId ?? "nil", process.parentAppName ?? "nil")

        // Activate the parent application (Cursor, VS Code, Terminal, etc.)
        // Use AppleScript for better Spaces/multiple desktop support
        let appName = process.parentAppName ?? "Terminal"
        activateAppWithAppleScript(appName)
    }

    /// Activates an app using AppleScript, which handles Spaces better than NSRunningApplication
    private func activateAppWithAppleScript(_ appName: String) {
        let script = """
        tell application "\(appName)"
            activate
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[PromptConduit] AppleScript error: %@", error)
                // Fallback to NSRunningApplication
                if let bundleId = bundleIdForAppName(appName) {
                    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                    runningApps.first?.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }
    }

    /// Maps app names to bundle IDs for fallback activation
    private func bundleIdForAppName(_ appName: String) -> String? {
        switch appName {
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "VS Code", "Visual Studio Code": return "com.microsoft.VSCode"
        case "Terminal": return "com.apple.Terminal"
        case "iTerm", "iTerm2": return "com.googlecode.iterm2"
        case "Warp": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func showNewAgentPanel() {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        agentPanelController?.showNewAgentPanel()
    }

    private func showAgentPanel(for session: AgentSession) {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        agentPanelController?.showPanel(for: session)
    }

    @objc private func showReposWindow() {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        agentPanelController?.showRepositoriesPanel()
    }

    @objc private func showSessionsDashboard() {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        agentPanelController?.showSessionsDashboardPanel()
    }

    @objc private func toggleAgentsVisibility() {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        let isNowHidden = agentPanelController?.toggleAllPanelsVisibility() ?? false
        hideShowAgentsMenuItem?.title = isNowHidden ? "Show All Agents" : "Hide All Agents"
    }

    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey

    private func registerGlobalHotkey() {
        // Register Cmd+Shift+A global hotkey
        // Note: Requires Accessibility permissions
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Check for Cmd+Shift+A
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 0 {
                DispatchQueue.main.async {
                    self?.showNewAgentPanel()
                }
            }
        }
    }
}
