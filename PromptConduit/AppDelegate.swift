import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var agentPanelController: AgentPanelController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerGlobalHotkey()

        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup PTY sessions
        AgentManager.shared.terminateAllSessions()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit")
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
        menu.addItem(agentsHeader)

        // Placeholder for agents
        let noAgentsItem = NSMenuItem(title: "  No active agents", action: nil, keyEquivalent: "")
        noAgentsItem.isEnabled = false
        menu.addItem(noAgentsItem)

        menu.addItem(NSMenuItem.separator())

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

    // MARK: - Menu Actions

    @objc private func toggleMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func showNewAgentPanel() {
        if agentPanelController == nil {
            agentPanelController = AgentPanelController()
        }
        agentPanelController?.showPanel()
    }

    @objc private func showReposWindow() {
        // TODO: Implement repos window
        print("Repos window not implemented yet")
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
