# tmux-task

Background task manager for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs long commands (builds, tests, servers) in detached tmux sessions and automatically delivers output notifications back to Claude via hooks.

## Why?

Claude Code blocks while waiting for shell commands to finish. Long-running tasks like test suites, builds, or dev servers tie up the conversation. tmux-task runs them in the background and notifies Claude of progress and completion automatically — no polling required.

## Requirements

- **tmux** — `brew install tmux` (macOS) or `sudo apt install tmux` (Linux)
- **python3** — used by the stop hook for JSON output
- **Claude Code** — the Anthropic CLI

## Installation

```bash
git clone https://github.com/skaramicke/tmux-task.git
cd tmux-task
bash install.sh
```

This installs:
1. `tmux-task` CLI to `/usr/local/bin/`
2. Hook scripts to `~/.claude/hooks/`
3. Configures Claude Code `settings.json` with the required hooks

To uninstall: `bash uninstall.sh`

## How it works

1. `tmux-task start` launches your command in a detached tmux session with a background watcher process
2. The watcher writes `.notif` files to `~/.tmux-tasks/pending/<scope>/` at configurable intervals
3. Claude Code's **Stop hook** (`tmux-task-stop.sh`) checks for pending notifications before letting Claude stop — if one exists, it blocks Claude and injects the notification as context
4. The **UserPromptSubmit/PreToolUse hook** (`tmux-task-notify.sh`) flushes any pending notifications when you send a message

Notifications are **scoped to the working directory**, so each Claude project session only sees notifications from its own tasks. A task started from a **subdirectory** (e.g. `cd web && tmux-task start build …` while the session sits at the project root) is still delivered: `start` records the originating absolute path in `~/.tmux-tasks/pending/<scope>/.scopedir`, and the hooks drain every scope whose recorded origin is the session's directory, a descendant, or an ancestor (`tmux-task related-scopes`). Notifs left by an older version with no recorded origin can't be safely attributed, so rather than being dropped silently they are surfaced as a warning naming the scope to drain (`tmux-task orphan-scopes`).

## Usage

```bash
# Start a task — runs in a detached tmux session
tmux-task start <id> <interval_secs> [--lines N] <command...>

# Examples:
tmux-task start e2e 60 --lines 5 ./scripts/e2e-test.sh
tmux-task start build 120 npm run build
tmux-task start server 30 npm run dev

# Check output manually (usually not needed — notifications are automatic)
tmux-task status <id>

# Send input to a running task (e.g. answer an interactive prompt)
tmux-task send <id> y

# Change the notification interval live
tmux-task interval <id> 10

# Change the lines trigger live (0 = disable)
tmux-task lines <id> 3

# List all tasks
tmux-task list

# Kill a task
tmux-task kill <id>

# Remove completed/killed task records
tmux-task clean
```

### Notification triggers

Two independent triggers control when notifications are sent:

| Trigger | Description |
|---------|-------------|
| `interval_secs` | Max seconds between notifications. Always fires, even with no new output — so you know the task is still alive. |
| `--lines N` | Also notify when N or more new lines appear since the last notification. Checked every second. Good for bursty output like test runners. |

Whichever fires first wins. Both reset the timer so they don't double-fire.

## Claude Code instructions

Add the following to your `CLAUDE.md` (global `~/.claude/CLAUDE.md` or per-project) so Claude knows how to use tmux-task:

````markdown
## Background Tasks — tmux-task

For any long-running shell command (tests, builds, servers), use `tmux-task` instead of
running directly. The task runs in a detached tmux session and notifies you automatically.

```bash
# Start a task — runs in a detached tmux session
# interval_secs: maximum time between notifications (required)
# --lines N: also notify whenever N new lines appear (for bursty tasks)
tmux-task start <id> <interval_secs> [--lines N] <command...>

# Examples:
tmux-task start e2e 60 --lines 5 ./scripts/e2e-test.sh --project=journey
tmux-task start build 120 npm run build

# Only use status if you have a specific reason to check immediately
tmux-task status <id>

# Send input to a running task (e.g. answer an interactive prompt)
tmux-task send <id> y

# Change the notification interval live
tmux-task interval <id> 10

# Change the lines trigger live (0 = disable)
tmux-task lines <id> 3

# List all tasks and their state
tmux-task list

# Kill a task
tmux-task kill <id>
```

### How notifications are delivered
The `Stop` hook fires when Claude finishes a turn. If a tmux-task is running in this
project scope, it polls for up to `interval` seconds for a `.notif` file. When one arrives,
it injects the content as a `reason` that blocks Claude from stopping — Claude sees it as
context and continues the conversation with the notification.

This means: after starting a task with interval=5, Claude will appear to "pause" for up to
5 seconds at the end of each turn while waiting for the next notification. That pause IS the
notification delivery mechanism. It's not a bug.

If no notification arrives within `interval` seconds, Claude stops normally. The
`UserPromptSubmit` hook then delivers any queued notifications on the next user message.

### After starting a task: just stop
Start the task, tell the user what you started, and stop. Notifications arrive automatically
at the end of each turn — no polling, no sleep-and-check, no manual status calls.

### Receiving notifications
Messages starting with `[tmux-task '...']` are injected automatically by the watcher —
they are not user input. Treat them as background notifications:
- Acknowledge briefly if the task is still running ("still going, will update when done")
- Report to the user and summarise output when FINISHED arrives
- Do not ask the user to confirm or reply to notifications

### When to use it
- Any command expected to take more than ~10 seconds
- E2E test suites, builds, long npm installs
- Any command that might need interactive input mid-run (`tmux-task send`)
- Any time you would otherwise block on a `sleep N` waiting for something to finish
````

## Architecture

```
~/.tmux-tasks/
├── pending/
│   └── <scope>/           # One dir per working directory
│       └── *.notif        # Pending notification files
├── <task-id>/
│   ├── session            # tmux session name
│   ├── command            # Original command
│   ├── output.log         # Full stdout+stderr
│   ├── interval           # Current notification interval
│   ├── lines_trigger      # Current lines trigger threshold
│   ├── scope              # Working directory scope token
│   ├── status             # running | done | killed
│   ├── notif_pos          # Byte offset for watcher notifications
│   ├── read_pos           # Byte offset for status command
│   ├── run.sh             # Wrapper script run by tmux
│   └── watcher.pid        # Background watcher PID
```

## License

MIT
