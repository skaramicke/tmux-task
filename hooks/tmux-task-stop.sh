#!/usr/bin/env bash
# Stop hook: deliver pending tmux-task notifications by blocking Claude from stopping.
#
# Scope is derived from $PWD, but a session at the project root also owns tasks
# started in subdirectories (and vice-versa) — see `tmux-task related-scopes`.
# This is the fix for the "silent orphan" bug: previously the hook matched only
# the exact session scope, so a task started from a subdir wrote its completion
# notif into a scope the hook never looked at, and the signal was lost.

STATE_DIR="$HOME/.tmux-tasks"
PENDING_DIR="$STATE_DIR/pending"
LOG="$STATE_DIR/stop-hook.log"

# Max total bytes to inject into conversation per stop-hook invocation
INJECT_MAX_BYTES=8192

# Sanitize text: strip invalid UTF-8 and null bytes (keeps python3 json.dumps happy).
_sanitize_utf8() {
  iconv -f utf-8 -t utf-8 -c 2>/dev/null | tr -d '\0' || cat
}

# Scopes this session owns (exact + descendant/ancestor by real path).
related=$(tmux-task related-scopes "$PWD")

echo "[$(date '+%H:%M:%S')] Stop hook fired. pwd=$PWD related=[$(printf '%s ' $related)]" >> "$LOG"

# True if scope token $1 is one this session owns.
_in_related() {
  local x="$1" r
  while IFS= read -r r; do
    [[ "$r" == "$x" ]] && return 0
  done <<< "$related"
  return 1
}

# Echo deliverable notif file paths across all related scopes, ordered by their
# millis filename prefix (sort on basename, not full path).
_collect_notifs() {
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    d="$PENDING_DIR/$s"
    [[ -d "$d" ]] && find "$d" -maxdepth 1 -name "*.notif" 2>/dev/null
  done <<< "$related" | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
}

# Block-and-deliver if any notifs are pending. Returns 0 if it delivered.
_deliver() {
  local notif_files=() f content="" orphans
  while IFS= read -r f; do
    [[ -n "$f" ]] && notif_files+=("$f")
  done < <(_collect_notifs)

  [[ ${#notif_files[@]} -eq 0 ]] && return 1

  for f in "${notif_files[@]}"; do
    [[ -f "$f" ]] || continue
    content+="$(cat "$f")"$'\n'
    rm -f "$f"
  done
  [[ -z "$content" ]] && return 1

  # Sanitize + cap the delivered notif body before it becomes the block reason.
  content=$(printf '%s' "$content" | _sanitize_utf8 | head -c "$INJECT_MAX_BYTES")

  # Piggyback an orphan warning onto a real delivery (never block solely for
  # orphans — that would nag every turn since they can't be auto-drained).
  orphans=$(tmux-task orphan-scopes "$PWD")
  if [[ -n "$orphans" ]]; then
    content+=$'\n⚠ tmux-task: unattributable pending notif scope(s) under this project: '"$(printf '%s ' $orphans)"$'(drain manually: cat ~/.tmux-tasks/pending/<scope>/*.notif)\n'
  fi

  echo "[$(date '+%H:%M:%S')] Delivering ${#notif_files[@]} notif(s)" >> "$LOG"
  python3 -c "
import json, sys
text = sys.stdin.read().rstrip()
print(json.dumps({'decision': 'block', 'reason': text}))
" <<< "$content"
  return 0
}

# Find shortest interval among running tasks in related scopes
interval=""
for d in "$STATE_DIR"/*/; do
  [[ -d "$d" ]] || continue
  ts=$(cat "$d/scope" 2>/dev/null) || continue
  _in_related "$ts" || continue
  [[ "$(cat "$d/status" 2>/dev/null)" == "running" ]] || continue
  i=$(cat "$d/interval" 2>/dev/null || echo 30)
  if [[ -z "$interval" || "$i" -lt "$interval" ]]; then
    interval=$i
  fi
done

echo "[$(date '+%H:%M:%S')] active interval=$interval" >> "$LOG"

# No running tasks — deliver any pending notifs (e.g. a FINISHED that arrived
# after the watcher exited) before letting Claude stop.
if [[ -z "$interval" ]]; then
  _deliver && exit 0
  exit 0
fi

# Running tasks — wait up to the shortest interval for a notification.
max_wait=$interval
elapsed=0
while [[ $elapsed -le $max_wait ]]; do
  _deliver && exit 0
  sleep 1
  elapsed=$(( elapsed + 1 ))
done

echo "[$(date '+%H:%M:%S')] Timed out after ${max_wait}s, no notifications" >> "$LOG"
exit 0
