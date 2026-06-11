# QuotaGlass

A native macOS menu-bar quota monitor for AI coding subscriptions. The first build focuses on a glassmorphism quota popover with colorful progress bars for Codex and Claude Code.

## Current scope

- macOS menu-bar app, accessory mode, no Dock icon
- Transparent glass popover using native `NSVisualEffectView`
- Large quota percentage cards
- Colorful gradient progress bars for 5-hour and weekly windows
- Manual refresh button
- Reads the local Ryan/Hermes usage checker when present:
  - `/Users/ansel/.hermes/hermes-agent/venv/bin/python`
  - `/Users/ansel/.claude/skills/claude-usage/scripts/check.py`
- Falls back to demo data if the checker is unavailable

## Run in development

```bash
cd /Users/ansel/code/QuotaGlass
swift run QuotaGlass
```

## Build

```bash
cd /Users/ansel/code/QuotaGlass
swift build
```

The built executable lives under `.build/debug/QuotaGlass`.

## Product direction

This is intentionally not Ryan-specific in the UI. The long-term generic direction is:

1. Native Codex quota client reading `~/.codex/auth.json`
2. Native Claude Code quota client reading `~/.claude/.credentials.json` or Keychain
3. Multiple accounts
4. Low-quota notifications
5. Optional desktop floating HUD
6. Signed `.app` bundle packaging

