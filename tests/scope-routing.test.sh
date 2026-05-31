#!/usr/bin/env bash
# Tests for tmux-task notification scope routing.
#
# Regression coverage for the "silent orphan" bug: a task started from a
# subdirectory writes its notifs into a descendant scope dir, but the Stop /
# notify hooks derive their scope from the SESSION's PWD (the project root).
# The exact-match scope lookup misses the descendant scope and the completion
# signal is lost with zero feedback.
#
# bash 3.2 compatible (macOS system bash). No external test framework.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  ok:   $1"; PASS=$((PASS + 1)); }

# Fresh sandbox HOME + project tree per test. Echoes paths via globals.
setup() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export PATH="$REPO/bin:$PATH"
  PROJ="$SANDBOX/proj"
  SUB="$PROJ/web"
  mkdir -p "$HOME" "$SUB" "$HOME/.tmux-tasks/pending"
}

teardown() {
  [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

# Place a pending notif in the scope dir for $1 (a directory path).
# Faithful to production: `tmux-task start` records the originating absolute
# cwd in .scopedir alongside the notifs, so descendant detection works on real
# paths (scope tokens are lossy — see test_sibling_scope_does_not_leak).
seed_notif() {
  local dir="$1" body="$2" scope notif_dir
  scope="$(tmux-task scope "$dir")"
  notif_dir="$HOME/.tmux-tasks/pending/$scope"
  mkdir -p "$notif_dir"
  printf '%s' "$dir" > "$notif_dir/.scopedir"
  printf '%s\n' "$body" > "$notif_dir/100-fe-done.notif"
}

# Place a pending notif WITHOUT a .scopedir — simulates a notif left by a
# pre-fix tmux-task (unattributable origin). Must never be silently dropped.
seed_legacy_notif() {
  local dir="$1" body="$2" scope notif_dir
  scope="$(tmux-task scope "$dir")"
  notif_dir="$HOME/.tmux-tasks/pending/$scope"
  mkdir -p "$notif_dir"
  printf '%s\n' "$body" > "$notif_dir/100-fe-done.notif"
}

# ---------------------------------------------------------------------------
# Stop hook: notif written from a SUBDIR scope must be delivered when the hook
# fires from the PARENT (session) dir.
# ---------------------------------------------------------------------------
test_stop_hook_delivers_subdir_notif() {
  setup
  seed_notif "$SUB" "[tmux-task 'fe'] FINISHED. build-succeeded-marker"
  local out
  out="$(cd "$PROJ" && bash "$REPO/hooks/tmux-task-stop.sh" 2>/dev/null)"
  if echo "$out" | grep -q "build-succeeded-marker"; then
    pass "stop hook delivers subdir notif from parent dir"
  else
    fail "stop hook did NOT deliver subdir notif (orphaned). out=[$out]"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# notify hook (UserPromptSubmit): same descendant-scope delivery, plain stdout.
# ---------------------------------------------------------------------------
test_notify_hook_delivers_subdir_notif() {
  setup
  seed_notif "$SUB" "[tmux-task 'fe'] output-marker-xyz"
  local out
  out="$(cd "$PROJ" && bash "$REPO/hooks/tmux-task-notify.sh" 2>/dev/null)"
  if echo "$out" | grep -q "output-marker-xyz"; then
    pass "notify hook delivers subdir notif from parent dir"
  else
    fail "notify hook did NOT deliver subdir notif (orphaned). out=[$out]"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# Exact-scope delivery must still work (no regression).
# ---------------------------------------------------------------------------
test_stop_hook_delivers_exact_scope_notif() {
  setup
  seed_notif "$PROJ" "exact-scope-marker"
  local out
  out="$(cd "$PROJ" && bash "$REPO/hooks/tmux-task-stop.sh" 2>/dev/null)"
  if echo "$out" | grep -q "exact-scope-marker"; then
    pass "stop hook delivers exact-scope notif"
  else
    fail "stop hook dropped exact-scope notif. out=[$out]"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# A SIBLING project scope must NOT leak in (prefix-boundary check). A dir whose
# scope shares a textual prefix but is not an ancestor/descendant must be
# ignored.
# ---------------------------------------------------------------------------
test_sibling_scope_does_not_leak() {
  setup
  # "$PROJ-other" sanitizes to "<projscope>-other"; that is NOT a descendant of
  # "<projscope>" via a path boundary — it must be excluded.
  local sibling="$SANDBOX/proj-other"
  mkdir -p "$sibling"
  seed_notif "$sibling" "sibling-leak-marker"
  local out
  out="$(cd "$PROJ" && bash "$REPO/hooks/tmux-task-stop.sh" 2>/dev/null)"
  if echo "$out" | grep -q "sibling-leak-marker"; then
    fail "sibling scope leaked into parent delivery. out=[$out]"
  else
    pass "sibling scope correctly excluded"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# related-scopes subcommand: lists self + descendants + ancestors, excludes siblings.
# ---------------------------------------------------------------------------
test_related_scopes_subcommand() {
  setup
  local sibling="$SANDBOX/proj-other"
  mkdir -p "$sibling"
  # Create pending scope dirs for: self, descendant, sibling — each with a
  # .scopedir recording its real origin (as `start` does).
  seed_notif "$PROJ"    "self"
  seed_notif "$SUB"     "descendant"
  seed_notif "$sibling" "sibling"

  local related
  related="$(tmux-task related-scopes "$PROJ")"
  local self_s sub_s sib_s
  self_s="$(tmux-task scope "$PROJ")"
  sub_s="$(tmux-task scope "$SUB")"
  sib_s="$(tmux-task scope "$sibling")"

  if echo "$related" | grep -qx "$self_s" \
     && echo "$related" | grep -qx "$sub_s" \
     && ! echo "$related" | grep -qx "$sib_s"; then
    pass "related-scopes lists self + descendant, excludes sibling"
  else
    fail "related-scopes wrong. got=[$related] self=$self_s sub=$sub_s sib=$sib_s"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# A legacy notif (no .scopedir) in a textual-descendant scope is unattributable
# — it can't be safely auto-delivered (indistinguishable from a sibling), but
# it must NOT be silently dropped. The notify hook surfaces a warning naming
# the orphaned scope, and leaves the file in place for manual draining.
# ---------------------------------------------------------------------------
test_notify_hook_warns_on_legacy_orphan() {
  setup
  seed_legacy_notif "$SUB" "legacy-orphan-body"
  local scope notif_file out
  scope="$(tmux-task scope "$SUB")"
  notif_file="$HOME/.tmux-tasks/pending/$scope/100-fe-done.notif"
  out="$(cd "$PROJ" && bash "$REPO/hooks/tmux-task-notify.sh" 2>/dev/null)"
  if echo "$out" | grep -qi "pending" && [[ -f "$notif_file" ]]; then
    pass "notify hook warns about legacy orphan, leaves file for draining"
  else
    fail "legacy orphan not surfaced or file removed. out=[$out] file_exists=$([[ -f $notif_file ]] && echo y || echo n)"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# Scope derivation must rewrite '.' and ':' to '_' (grit-bwa3o) — tmux silently
# rewrites them in session names, so writer and reader must agree.
# ---------------------------------------------------------------------------
test_scope_rewrites_dots_and_colons() {
  setup
  local s
  s="$(tmux-task scope "/Volumes/Projects/samspela.se/web")"
  if [[ "$s" != *"."* && "$s" != *":"* && "$s" == *"samspela_se"* ]]; then
    pass "scope rewrites . and : (got $s)"
  else
    fail "scope did not sanitize dots/colons: $s"
  fi
  teardown
}

# ---------------------------------------------------------------------------
# Task state is keyed by <scope>__<id> (grit-g245d / hojt-ny9g3): the same id in
# two different project dirs must not collide on one state dir.
# ---------------------------------------------------------------------------
test_task_key_isolates_by_cwd() {
  setup
  local a="$SANDBOX/projA" b="$SANDBOX/projB"
  mkdir -p "$a" "$b"
  ( cd "$a" && tmux-task start e2e 60 bash -c "echo AAA; sleep 2" ) >/dev/null
  ( cd "$b" && tmux-task start e2e 60 bash -c "echo BBB; sleep 2" ) >/dev/null
  local na nb
  na=$(find "$HOME/.tmux-tasks" -maxdepth 1 -type d -name "*__e2e" | wc -l | tr -d ' ')
  # status from A must show A's command, not B's
  local sa
  sa=$(cd "$a" && tmux-task status e2e 2>/dev/null)
  ( cd "$a" && tmux-task kill e2e ) >/dev/null 2>&1
  ( cd "$b" && tmux-task kill e2e ) >/dev/null 2>&1
  if [[ "$na" -eq 2 ]] && echo "$sa" | grep -q "AAA"; then
    pass "task key isolates same id across two project dirs"
  else
    fail "task-key isolation broken: dirs=$na statusA=[$sa]"
  fi
  teardown
}

echo "== scope-routing tests =="
test_stop_hook_delivers_subdir_notif
test_notify_hook_delivers_subdir_notif
test_stop_hook_delivers_exact_scope_notif
test_sibling_scope_does_not_leak
test_related_scopes_subcommand
test_notify_hook_warns_on_legacy_orphan
test_scope_rewrites_dots_and_colons
test_task_key_isolates_by_cwd

echo ""
echo "== $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
