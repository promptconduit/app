# PromptConduit macOS

See the [root README](../README.md) for full documentation.

## Quick Reference

```bash
# Generate Xcode project (requires xcodegen)
cd .. && xcodegen generate

# Build
xcodebuild -scheme PromptConduit -configuration Debug build

# Run
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app

# Test
xcodebuild test -scheme PromptConduit -destination 'platform=macOS'
```
