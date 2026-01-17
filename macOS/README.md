# PromptConduit macOS App

Native macOS application for managing GitHub repos and AI coding agents.

## Features

- **Repo Management**: Create, clone, and organize GitHub repositories
- **Agent Orchestration**: Launch, monitor, and switch between Claude Code agents
- **Menu Bar Presence**: Always-accessible toolbar with global hotkey (⌘⇧A)
- **Floating Panels**: Agent windows that stay above other apps
- **Subscription-First**: Uses Claude Code subscription (no API credits)

## Requirements

- macOS 14.0+
- Xcode 15.0+
- XcodeGen (for project generation)
- Claude Code CLI installed

## Setup

1. Install XcodeGen if not already installed:
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   cd app
   xcodegen generate
   ```

3. Open the project in Xcode:
   ```bash
   open PromptConduit.xcodeproj
   ```

4. Build and run (⌘R)

## Architecture

### PTY-Based Claude Control

The app uses pseudo-terminal (PTY) control to interact with the Claude CLI, allowing:
- Use of Claude Code subscription (no API costs)
- Programmatic control (launch agents, send prompts)
- Real-time output capture for UI display

### Key Components

- **PTYSession**: Spawns and controls Claude CLI via pseudo-terminal
- **AppDelegate**: Menu bar item, global hotkey, app lifecycle
- **AgentPanel**: Floating panel window for agent interaction
- **TranscriptView**: Renders Claude conversation output
- **AgentManager**: Manages multiple concurrent agent sessions

## Project Structure

```
PromptConduit/
├── PromptConduitApp.swift      # App entry point
├── AppDelegate.swift           # Menu bar, lifecycle
├── Core/
│   └── PTY/
│       ├── PTYSession.swift    # Terminal control
│       └── OutputParser.swift  # ANSI parsing
├── Features/
│   ├── MenuBar/
│   │   └── MenuBarController.swift
│   └── Agent/
│       ├── AgentPanelController.swift
│       └── TranscriptView.swift
├── Models/
│   └── AgentSession.swift
├── Services/
│   └── AgentManager.swift
└── Resources/
    ├── Info.plist
    └── PromptConduit.entitlements
```

## Development

### Building

```bash
# Generate Xcode project
xcodegen generate

# Build from command line
xcodebuild -project PromptConduit.xcodeproj -scheme PromptConduit build
```

### Testing

```bash
xcodebuild -project PromptConduit.xcodeproj -scheme PromptConduit test
```

## License

Copyright © 2024 PromptConduit. All rights reserved.
