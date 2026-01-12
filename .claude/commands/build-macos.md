---
description: Build, run, and debug the PromptConduit macOS app
---

# Build macOS App Workflow

Execute the following workflow to build, run, and debug the PromptConduit macOS app.

## Available Actions

This skill supports multiple actions based on what the user needs:

### 1. Build Only (`build`)

Build the app without running it:

```bash
cd /Users/scotthavird/Documents/GitHub/promptconduit/app
xcodebuild -scheme PromptConduit -configuration Debug build 2>&1
```

Check the output for:
- **BUILD SUCCEEDED** - Report success
- Any **error:** lines - Report the specific errors with file and line numbers
- Any **warning:** lines - Summarize warnings

### 2. Build and Run (`run`)

Build the app and launch it:

```bash
cd /Users/scotthavird/Documents/GitHub/promptconduit/app

# Build first
xcodebuild -scheme PromptConduit -configuration Debug build 2>&1

# If build succeeds, find and run the app
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app
```

After launching, inform the user:
- The app is now running in the menu bar
- They can interact with it normally
- Use the `logs` action to monitor runtime behavior

### 3. Monitor Logs (`logs`)

Stream logs from the running app:

```bash
# Stream PromptConduit logs in real-time (run in background)
log stream --predicate 'subsystem == "com.promptconduit" OR process == "PromptConduit"' --level debug
```

Note: This is a streaming command. Use `run_in_background: true` and monitor with TaskOutput.

### 4. Check Crash Reports (`crashes`)

Look for recent crash reports:

```bash
# List recent crash reports
ls -lt ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i promptconduit | head -10

# If crashes exist, read the most recent one
cat "$(ls -t ~/Library/Logs/DiagnosticReports/PromptConduit* 2>/dev/null | head -1)" 2>/dev/null || echo "No crash reports found"
```

Analyze crash reports for:
- **Exception Type** - What kind of crash
- **Crashed Thread** - Which thread crashed
- **Thread N Crashed** section - The actual stack trace
- Look for PromptConduit frames in the stack

### 5. Clean Build (`clean`)

Clean derived data and rebuild:

```bash
cd /Users/scotthavird/Documents/GitHub/promptconduit/app

# Clean build artifacts
xcodebuild -scheme PromptConduit clean 2>&1

# Remove derived data for fresh build
rm -rf ~/Library/Developer/Xcode/DerivedData/PromptConduit-*

# Rebuild
xcodebuild -scheme PromptConduit -configuration Debug build 2>&1
```

### 6. Kill Running App (`kill`)

Stop the running app:

```bash
pkill -f "PromptConduit.app" 2>/dev/null || echo "App not running"
```

## Default Behavior

If no specific action is requested:
1. Build the app
2. Report build status (success/failure with details)
3. If successful and user seems to want to test, offer to run it

## Debugging Tips

When investigating issues:

1. **For crashes**: Use `crashes` action to find crash reports
2. **For hangs**: Use `log stream` to watch for stuck operations
3. **For UI issues**: The app uses SwiftUI - check for view lifecycle problems
4. **For terminal issues**: Check SwiftTerm delegate methods in EmbeddedTerminalView.swift

## Project Structure Reference

Key files for debugging:
- `PromptConduit/AppDelegate.swift` - App lifecycle
- `PromptConduit/Features/Agent/AgentPanelController.swift` - Window management
- `PromptConduit/Features/Terminal/MultiTerminalGridView.swift` - Multi-terminal grid
- `PromptConduit/Services/TerminalSessionManager.swift` - Session lifecycle
