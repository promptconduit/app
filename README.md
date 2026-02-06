# PromptConduit for macOS

A native macOS menu bar app for managing Claude Code sessions, discovering patterns in your AI workflows, and building reusable skills.

## What It Does

PromptConduit sits in your menu bar and watches your Claude Code sessions in real-time. It indexes your conversation transcripts, detects repeated workflows, and helps you turn them into reusable slash commands.

**Key capabilities:**

- **Sessions Dashboard** — Browse all Claude Code sessions grouped by repository, with live status indicators (running, waiting, idle)
- **Semantic Search** — Search across all your transcripts using natural language, powered by vector embeddings
- **Pattern Detection** — Automatically clusters repeated prompts across sessions and scores them by frequency, diversity, and complexity
- **Skills Management** — Browse, edit, and create Claude Code slash commands (`~/.claude/commands/`). Convert detected patterns into reusable skills with one click
- **Embedded Terminals** — Launch and monitor multiple Claude Code sessions in a grid view with broadcast mode

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed

## Getting Started

```bash
# Install XcodeGen
brew install xcodegen

# Clone and generate project
git clone https://github.com/promptconduit/app.git
cd app
xcodegen generate

# Open in Xcode and run (Cmd+R)
open macOS/PromptConduit.xcodeproj
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

For real-time notifications, PromptConduit integrates with Claude Code's hook system. Hooks fire on session start, prompt submission, and tool execution, giving the app instant updates without polling.

### Pattern Detection

The pattern engine clusters similar prompts across your sessions using text similarity. It scores patterns by:
- **Frequency** — How often you repeat the prompt
- **Diversity** — Whether it appears across different repositories
- **Recency** — When it was last used
- **Complexity** — Length and sophistication of the prompt

High-scoring patterns are candidates for conversion into reusable skills.

### Semantic Search

Transcripts are indexed with vector embeddings stored in a local SQLite database. This enables natural language search across all your Claude Code conversations — find that debugging session from last week by describing what you were working on.

## Architecture

```
PromptConduit/
├── Core/
│   └── PTY/                    # Pseudo-terminal for Claude CLI control
├── Features/
│   ├── Dashboard/              # 4-tab UI (Sessions, Semantic, Patterns, Skills)
│   ├── MenuBar/                # Menu bar controller with global hotkey
│   ├── Terminal/               # Embedded terminal grid with broadcast mode
│   ├── Agent/                  # Agent panel and transcript rendering
│   └── Settings/               # App preferences
├── Models/                     # AgentSession, SessionGroup, SessionHistory
├── Services/                   # 21 services (see below)
└── Resources/                  # Info.plist, entitlements
```

Key services:

| Service | Purpose |
|---------|---------|
| `ClaudeSessionDiscovery` | Monitors JSONL session files, tracks live status |
| `TranscriptIndexService` | Indexes transcripts with embeddings for search |
| `PatternDetectionService` | Clusters repeated prompts across sessions |
| `PatternSkillService` | Converts detected patterns into slash commands |
| `SlashCommandsService` | Loads and manages skills from disk |
| `TerminalSessionManager` | Manages embedded terminal sessions |
| `HookNotificationService` | Receives real-time events from Claude Code hooks |

## Development

Swift changes require a full rebuild and app restart — there is no hot reload.

```bash
# Build
xcodebuild -scheme PromptConduit -configuration Debug build

# Run tests
xcodebuild test -scheme PromptConduit -destination 'platform=macOS'
```

### Permissions

The app is **not sandboxed** — it needs to:
- Spawn Claude CLI processes via PTY
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
