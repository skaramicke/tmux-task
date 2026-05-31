#!/usr/bin/env bash
# UserPromptSubmit + PreToolUse hook: flush pending tmux-task notifications
# into Claude's conversation context.
#
# UserPromptSubmit: plain stdout is injected (confirmed to reach Claude).
# PreToolUse: stdout only visible in verbose mode; additionalContext JSON
#             is the documented path to Claude's context, but results vary.
#
# Notifications are scoped to $PWD, but a session at the project root also
# drains notifs from tasks started in subdirectories (and vice-versa) — see
# `tmux-task related-scopes`. Notifs left by a pre-fix tmux-task (no recorded
# origin) can't be safely attributed; they are surfaced as a warning rather
# than dropped silently.
# Compatible with bash 3.2 (macOS system bash).

PENDING_DIR="$HOME/.tmux-tasks/pending"

# Max total bytes to inject into conversation
INJECT_MAX_BYTES=8192

# Sanitize text: strip invalid UTF-8 and null bytes.
_sanitize_utf8() {
  iconv -f utf-8 -t utf-8 -c 2>/dev/null | tr -d '\0' || cat
}

# Scopes this session owns (exact + descendant/ancestor by real path).
related=$(tmux-task related-scopes "$PWD")

# Collect notif files across all related scopes, ordered by their millis
# filename prefix (sort on basename, not full path).
notif_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && notif_files+=("$f")
done < <(
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    d="$PENDING_DIR/$s"
    [[ -d "$d" ]] && find "$d" -maxdepth 1 -name "*.notif"
  done <<< "$related" | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
)

# Accumulate deliverable notification text
content=""
for f in "${notif_files[@]}"; do
  [[ -f "$f" ]] || continue
  content+="$(cat "$f")"$'\n'
  content+=$'──────────────────────────────────────────\n'
  rm -f "$f"
done

# Surface unattributable orphans (never delivered, never dropped silently)
orphans=$(tmux-task orphan-scopes "$PWD")
warn=""
if [[ -n "$orphans" ]]; then
  n=$(printf '%s\n' "$orphans" | grep -c .)
  warn="⚠ tmux-task: ${n} pending notification scope(s) under this project could not be attributed (started before the scope-routing fix, or unknown origin): $(printf '%s ' $orphans). Drain manually: cat ~/.tmux-tasks/pending/<scope>/*.notif"$'\n'
fi

[[ -z "$content" && -z "$warn" ]] && exit 0

header=$'╔══════════════════════════════════════════╗\n║         tmux-task background updates      ║\n╚══════════════════════════════════════════╝\n'

# Sanitize and cap the delivered notif body before injection (the warning is
# our own text — appended after the cap so it is never truncated away).
content=$(printf '%s' "$content" | _sanitize_utf8 | head -c "$INJECT_MAX_BYTES")

# Plain stdout — works for UserPromptSubmit (confirmed to reach Claude)
printf '%s%s%s' "$header" "$content" "$warn"
