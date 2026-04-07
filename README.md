# PromptConduit for macOS

A native macOS menu bar app that tracks your Claude Code sessions and manages your skills library.

## What It Does

PromptConduit sits in your menu bar and watches your Claude Code sessions in real-time. It gives you visibility into your coding activity and a central place to manage reusable slash commands.

**Key capabilities:**

- **Sessions Dashboard** — Browse all Claude Code sessions grouped by repository, with live status indicators (running, waiting, idle)
- **Skills Management** — Browse, edit, and create Claude Code slash commands (`~/.claude/commands/`). Global and project-scoped skills in one place.

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Zig](https://ziglang.org/) (required to build the GhosttyKit terminal framework)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed

## Getting Started

```bash
# Install prerequisites
brew install xcodegen zig

# Clone and set up
git clone https://github.com/promptconduit/app.git
cd app
./scripts/setup.sh        # builds GhosttyKit.xcframework (~5 min first time)

# Generate Xcode project and open
cd macOS
xcodegen generate
open PromptConduit.xcodeproj
```

Or build from the command line:

```bash
cd macOS
xcodebuild -scheme PromptConduit -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app
```

The app runs in your menu bar — look for the PromptConduit icon after launching.

## How It Works

### Session Discovery

PromptConduit monitors `~/.claude/projects/` for JSONL transcript files that Claude Code writes during sessions. It parses these files to extract conversation history, session metadata, and status.

### Hook Integration

For real-time updates, PromptConduit integrates with Claude Code's hook system. Hooks fire on session start, prompt submission, and tool execution, giving the app instant status changes without polling.

### Skills Management

Skills are markdown files with YAML frontmatter loaded from two locations:
- **Global:** `~/.claude/commands/` — available in all projects
- **Project:** `[repo]/.claude/commands/` — project-specific, committable to git

The app lets you browse, edit, and create skills without leaving your workflow.

## Architecture

```
PromptConduit/
├── Features/
│   ├── Dashboard/              # Sessions + Skills UI
│   ├── MenuBar/                # Menu bar controller with global hotkey
│   ├── Agent/                  # Session transcript rendering
│   └── Settings/               # App preferences
├── Models/                     # AgentSession, SessionGroup, SessionHistory
├── Services/                   # Core services
└── Resources/                  # Info.plist, entitlements
```

Key services:

| Service | Purpose |
|---------|---------|
| `ClaudeSessionDiscovery` | Monitors JSONL session files, tracks live status |
| `SlashCommandsService` | Loads and manages skills from disk |
| `HookNotificationService` | Receives real-time events from Claude Code hooks |

## Development

Swift changes require a full rebuild and app restart — there is no hot reload.

```bash
# Build
cd macOS
xcodegen generate
xcodebuild -scheme PromptConduit -configuration Debug build

# Run tests
xcodebuild test -scheme PromptConduit -destination 'platform=macOS'
```

### Permissions

The app is **not sandboxed** — it needs to:
- Monitor file system for session transcripts
- Send Apple Events for automation

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Commit your changes
4. Push and open a PR

## License

[MIT](LICENSE) — Copyright (c) 2025 PromptConduit
