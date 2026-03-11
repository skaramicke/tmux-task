#!/usr/bin/env bash
# UserPromptSubmit + PreToolUse hook: flush pending tmux-task notifications
# into Claude's conversation context.
#
# UserPromptSubmit: plain stdout is injected (confirmed to reach Claude).
# PreToolUse: stdout only visible in verbose mode; additionalContext JSON
#             is the documented path to Claude's context, but results vary.
#
# Notifications are scoped to $PWD (matches tmux-task start scoping).
# Compatible with bash 3.2 (macOS system bash).

PENDING_DIR="$HOME/.tmux-tasks/pending"

# Derive scope from current working directory (must match _scope_for_dir in tmux-task)
scope=$(echo "$PWD" | sed 's|^/||; s|/|-|g; s| |_|g')
scope_dir="$PENDING_DIR/$scope"

[[ -d "$scope_dir" ]] || exit 0

# Collect sorted notification files (bash 3.2 compatible — no mapfile)
notif_files=()
while IFS= read -r f; do
  notif_files+=("$f")
done < <(find "$scope_dir" -maxdepth 1 -name "*.notif" | sort)

[[ ${#notif_files[@]} -eq 0 ]] && exit 0

# Accumulate notification text
content=""
for f in "${notif_files[@]}"; do
  [[ -f "$f" ]] || continue
  content+="$(cat "$f")"$'\n'
  content+=$'──────────────────────────────────────────\n'
  rm -f "$f"
done

[[ -z "$content" ]] && exit 0

header=$'╔══════════════════════════════════════════╗\n║         tmux-task background updates      ║\n╚══════════════════════════════════════════╝\n'

# Plain stdout — works for UserPromptSubmit (confirmed to reach Claude)
printf '%s%s' "$header" "$content"
