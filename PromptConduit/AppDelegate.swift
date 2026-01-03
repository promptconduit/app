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
        let externalProcesses = ProcessDetectionService.shared.externalProcesses

        let hasAnyAgents = !managedSessions.isEmpty || !externalProcesses.isEmpty

        // Show/hide "No active agents" placeholder
        noAgentsMenuItem?.isHidden = hasAnyAgents

        if hasAnyAgents {
            // Add managed sessions
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

            // Add separator between managed and external if both exist
            if !managedSessions.isEmpty && !externalProcesses.isEmpty {
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

            // Add external processes (clickable to focus terminal)
            for process in externalProcesses {
                let title = "  🟢 \(process.displayName)"
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
        let externalCount = ProcessDetectionService.shared.externalProcesses.count

        if manager.waitingCount > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit - Waiting")
            button.image?.isTemplate = false  // Allow color tint
            button.contentTintColor = .systemYellow
        } else if manager.runningCount > 0 || externalCount > 0 {
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

    @objc private func selectExternalProcess(_ sender: NSMenuItem) {
        guard let process = sender.representedObject as? ExternalClaudeProcess else { return }

        // Use AppleScript to activate Terminal and focus window with matching directory
        let escapedDir = process.workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedName = process.displayName.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            set targetDir to "\(escapedDir)"
            set targetName to "\(escapedName)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabTitle to custom title of t
                        if tabTitle contains targetDir or tabTitle contains targetName then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            // Even if AppleScript fails, Terminal is already activated
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
