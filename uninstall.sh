#!/usr/bin/env bash
# tmux-task uninstaller
#
# Removes:
#   1. tmux-task CLI from /usr/local/bin/
#   2. Hook scripts from ~/.claude/hooks/
#   3. Hook entries from Claude Code settings.json
#
# Does NOT remove ~/.tmux-tasks state directory (may contain running tasks).

set -euo pipefail

echo "Removing tmux-task CLI..."
rm -f /usr/local/bin/tmux-task

echo "Removing hook scripts..."
rm -f "$HOME/.claude/hooks/tmux-task-stop.sh"
rm -f "$HOME/.claude/hooks/tmux-task-notify.sh"

SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]] && command -v python3 &>/dev/null; then
  echo "Removing hooks from Claude Code settings..."
  python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
scripts = ["tmux-task-stop.sh", "tmux-task-notify.sh"]

for hook_type in list(hooks.keys()):
    groups = hooks[hook_type]
    hooks[hook_type] = [
        g for g in groups
        if not any(
            any(s in h.get("command", "") for s in scripts)
            for h in g.get("hooks", [])
        )
    ]
    if not hooks[hook_type]:
        del hooks[hook_type]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("  Done.")
PYEOF
fi

echo ""
echo "Uninstalled. State directory ~/.tmux-tasks/ was preserved."
echo "Remove it manually if you want: rm -rf ~/.tmux-tasks"
