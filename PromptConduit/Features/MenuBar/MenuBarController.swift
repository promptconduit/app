import AppKit
import SwiftUI
import Combine

/// Advanced menu bar controller with dynamic agent list
class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        setupStatusItem()
        observeAgentChanges()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateStatusIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func observeAgentChanges() {
        AgentManager.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
    }

    // MARK: - Status Icon

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let manager = AgentManager.shared
        let hasActiveAgents = manager.runningCount > 0 || manager.waitingCount > 0

        // Update icon based on state
        if manager.waitingCount > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit - Waiting")
            button.image?.isTemplate = false
            button.contentTintColor = .systemYellow
        } else if manager.runningCount > 0 {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit - Running")
            button.image?.isTemplate = false
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "PromptConduit")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        }

        // Add badge if there are completed agents
        if manager.completedCount > 0 {
            // Could add a badge here in the future
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView()
        )

        self.popover = popover

        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // Monitor for clicks outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover?.close()
        popover = nil

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Popover View

struct MenuBarPopoverView: View {
    @ObservedObject private var agentManager = AgentManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("PromptConduit")
                    .font(.headline)
                Spacer()
                Text("⌘⇧A")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Agent List
            if agentManager.sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No active agents")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(agentManager.sessions.enumerated()), id: \.element.id) { index, session in
                            AgentRowView(session: session, shortcut: index + 1)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button(action: { showNewAgent() }) {
                    Label("New Agent", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                SettingsLink {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 320, height: 400)
    }

    private func showNewAgent() {
        // TODO: Open new agent panel
        NotificationCenter.default.post(name: .showNewAgentPanel, object: nil)
    }
}

// MARK: - Agent Row View

struct AgentRowView: View {
    @ObservedObject var session: AgentSession
    let shortcut: Int

    var body: some View {
        Button(action: { selectAgent() }) {
            HStack(spacing: 12) {
                // Status indicator
                Text(session.status.emoji)
                    .font(.title2)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.repoName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(session.shortPrompt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Shortcut
                if shortcut <= 9 {
                    Text("⌘\(shortcut)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func selectAgent() {
        AgentManager.shared.setActiveSession(session)
        NotificationCenter.default.post(name: .showAgentPanel, object: session)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showNewAgentPanel = Notification.Name("showNewAgentPanel")
    static let showAgentPanel = Notification.Name("showAgentPanel")
}
