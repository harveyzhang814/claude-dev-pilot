# Changelog

All notable changes to this project will be documented in this file.

## [0.0.1.0] - 2026-04-13

### Added
- **Remove hooks prompts in Settings** — two new copy-able prompt boxes in the Settings view (below each existing install-hooks prompt) let users cleanly remove Agent Pilot hooks from Claude Code (`settings.json`) and Cursor (`hooks.json`) without touching any other hooks.
- `HookInstaller.claudeCodeRemovePrompt()` and `HookInstaller.cursorAgentRemovePrompt()` static methods generate precise removal instructions scoped to Agent Pilot hook paths only.
- Unit tests covering both new methods (content, path references, and remove-vs-install distinction).

### Changed
- `.githooks/pre-commit` now allows `feat/*` branch prefixes.
- `.gitignore` excludes stray `AgentPilot.app` bundle directory.
