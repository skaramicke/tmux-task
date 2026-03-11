#!/usr/bin/env bash
# Stop hook: deliver pending tmux-task notifications by blocking Claude from stopping.

STATE_DIR="$HOME/.tmux-tasks"
PENDING_DIR="$STATE_DIR/pending"
LOG="$STATE_DIR/stop-hook.log"

scope=$(echo "$PWD" | sed 's|^/||; s|/|-|g; s| |_|g')
scope_dir="$PENDING_DIR/$scope"

echo "[$(date '+%H:%M:%S')] Stop hook fired. scope=$scope scope_dir_exists=$(test -d "$scope_dir" && echo y || echo n)" >> "$LOG"

# Find shortest interval among tasks with status=running in this scope
interval=""
for d in "$STATE_DIR"/*/; do
  [[ -d "$d" ]] || continue
  [[ "$(cat "$d/scope" 2>/dev/null)" == "$scope" ]] || continue
  [[ "$(cat "$d/status" 2>/dev/null)" == "running" ]] || continue
  i=$(cat "$d/interval" 2>/dev/null || echo 30)
  if [[ -z "$interval" || "$i" -lt "$interval" ]]; then
    interval=$i
  fi
done

echo "[$(date '+%H:%M:%S')] active interval=$interval" >> "$LOG"

# No running tasks — check for any pending notifications (e.g. FINISHED)
# before letting Claude stop
if [[ -z "$interval" ]]; then
  notif_files=()
  while IFS= read -r f; do
    notif_files+=("$f")
  done < <(find "$scope_dir" -maxdepth 1 -name "*.notif" 2>/dev/null | sort)

  if [[ ${#notif_files[@]} -gt 0 ]]; then
    content=""
    for f in "${notif_files[@]}"; do
      [[ -f "$f" ]] || continue
      content+="$(cat "$f")"$'\n'
      rm -f "$f"
    done
    if [[ -n "$content" ]]; then
      echo "[$(date '+%H:%M:%S')] Delivering ${#notif_files[@]} pending notif(s) (no running tasks)" >> "$LOG"
      python3 -c "
import json, sys
text = sys.stdin.read().rstrip()
print(json.dumps({'decision': 'block', 'reason': text}))
" <<< "$content"
      exit 0
    fi
  fi

  exit 0
fi

max_wait=$interval
elapsed=0

while [[ $elapsed -le $max_wait ]]; do
  notif_files=()
  while IFS= read -r f; do
    notif_files+=("$f")
  done < <(find "$scope_dir" -maxdepth 1 -name "*.notif" 2>/dev/null | sort)

  if [[ ${#notif_files[@]} -gt 0 ]]; then
    content=""
    for f in "${notif_files[@]}"; do
      [[ -f "$f" ]] || continue
      content+="$(cat "$f")"$'\n'
      rm -f "$f"
    done
    echo "[$(date '+%H:%M:%S')] Injecting notification (${#notif_files[@]} files)" >> "$LOG"
    python3 -c "
import json, sys
text = sys.stdin.read().rstrip()
print(json.dumps({'decision': 'block', 'reason': text}))
" <<< "$content"
    exit 0
  fi

  sleep 1
  elapsed=$(( elapsed + 1 ))
done

echo "[$(date '+%H:%M:%S')] Timed out after ${max_wait}s, no notifications" >> "$LOG"
exit 0
