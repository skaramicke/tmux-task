#!/usr/bin/env bash
# tmux-task installer for Claude Code
#
# Installs:
#   1. tmux-task CLI to /usr/local/bin/
#   2. Hook scripts to ~/.claude/hooks/
#   3. Configures Claude Code settings.json with the required hooks
#
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Pre-checks ---
if ! command -v tmux &>/dev/null; then
  echo "Error: tmux is required but not installed." >&2
  echo "  macOS:  brew install tmux" >&2
  echo "  Linux:  sudo apt install tmux  (or your distro's package manager)" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required (used by the stop hook for JSON output)." >&2
  exit 1
fi

# --- Install CLI ---
echo "Installing tmux-task to /usr/local/bin/..."
cp "$SCRIPT_DIR/bin/tmux-task" /usr/local/bin/tmux-task
chmod +x /usr/local/bin/tmux-task

# --- Install hooks ---
HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"

echo "Installing hooks to $HOOKS_DIR/..."
cp "$SCRIPT_DIR/hooks/tmux-task-stop.sh" "$HOOKS_DIR/tmux-task-stop.sh"
cp "$SCRIPT_DIR/hooks/tmux-task-notify.sh" "$HOOKS_DIR/tmux-task-notify.sh"
chmod +x "$HOOKS_DIR/tmux-task-stop.sh" "$HOOKS_DIR/tmux-task-notify.sh"

# --- Configure Claude Code settings ---
SETTINGS_FILE="$HOME/.claude/settings.json"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "Creating $SETTINGS_FILE..."
  echo '{}' > "$SETTINGS_FILE"
fi

echo "Configuring Claude Code hooks in $SETTINGS_FILE..."

python3 << 'PYEOF'
import json, sys, os

settings_path = os.path.expanduser("~/.claude/settings.json")

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

hook_configs = {
    "Stop": {
        "command": "bash ~/.claude/hooks/tmux-task-stop.sh",
        "type": "command"
    },
    "UserPromptSubmit": {
        "command": "bash ~/.claude/hooks/tmux-task-notify.sh",
        "type": "command"
    },
    "PreToolUse": {
        "command": "bash ~/.claude/hooks/tmux-task-notify.sh",
        "type": "command"
    }
}

changed = False
for hook_type, hook_entry in hook_configs.items():
    existing = hooks.get(hook_type, [])
    # Check if already registered
    already_exists = any(
        any(h.get("command") == hook_entry["command"] for h in group.get("hooks", []))
        for group in existing
    )
    if not already_exists:
        existing.append({"hooks": [hook_entry], "matcher": ""})
        hooks[hook_type] = existing
        changed = True

if changed:
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print("  Hooks configured successfully.")
else:
    print("  Hooks already configured.")
PYEOF

# --- Create state directory ---
mkdir -p "$HOME/.tmux-tasks/pending"

echo ""
echo "Installation complete!"
echo ""
echo "Add the following to your CLAUDE.md (global or per-project) to teach"
echo "Claude how to use tmux-task:"
echo ""
echo '  See: https://github.com/skaramicke/tmux-task#claude-code-instructions'
echo ""
