#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's brief-content preflight
# (bin/fm-brief-content-lib.sh's fm_brief_has_content, plus the
# fm-operational-input.sh delivery-encode proof) - the fix for
# data/fm-spawn-empty-prompt/report.md: a brief that still carries the
# unreplaced {TASK} placeholder, or is otherwise empty, previously reached a
# harness launch template unnoticed and booted the harness with a genuinely
# empty prompt. Both checks are reached right after the existing
# "no brief at" existence check, before any tmux/treehouse side effect, so
# these tests create no windows or worktrees (same style as
# tests/fm-spawn-batch.test.sh's test_projects_path_scoping). The full
# successful-spawn path (real brief content reaching a real launch command) is
# already covered end to end by tests/fm-spawn-dispatch-profile.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-content)

# make_probe_home <id> <brief-content> -> echoes "<home>|<projects>"
make_probe_home() {
  local id=$1 content=$2 home projects
  home="$TMP_ROOT/$id home"
  projects="$TMP_ROOT/$id projects"
  mkdir -p "$home/data/$id" "$projects/alpha"
  printf '%s' "$content" > "$home/data/$id/brief.md"
  printf '%s|%s' "$home" "$projects"
}

run_probe_spawn() {  # <home> <projects> <id> [extra spawn args...]
  local home=$1 projects=$2 id=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" projects/alpha codex --mode direct-PR --yolo off "$@" 2>&1
}

test_unfilled_placeholder_brief_refuses() {
  local id=nope-placeholder-z1 rec home projects out status
  rec=$(make_probe_home "$id" '# brief

{TASK}

## Rules
')
  home=${rec%%|*}; projects=${rec#*|}
  out=$(run_probe_spawn "$home" "$projects" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unfilled {TASK} placeholder must refuse the spawn"
  printf '%s\n' "$out" | grep -F 'has no real instructions' >/dev/null \
    || fail "refusal did not name the missing instructions"
  printf '%s\n' "$out" | grep -F 'error: no brief at' >/dev/null \
    && fail "an existing-but-unfilled brief must not be reported as missing"
  pass "fm-spawn refuses a brief whose {TASK} placeholder was never replaced"
}

test_whitespace_only_brief_refuses() {
  local id=nope-whitespace-z2 rec home projects out status
  rec=$(make_probe_home "$id" '

')
  home=${rec%%|*}; projects=${rec#*|}
  out=$(run_probe_spawn "$home" "$projects" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a whitespace-only brief must refuse the spawn"
  printf '%s\n' "$out" | grep -F 'has no real instructions' >/dev/null \
    || fail "refusal did not name the missing instructions"
  pass "fm-spawn refuses a whitespace-only brief"
}

test_unfilled_placeholder_brief_refuses
test_whitespace_only_brief_refuses
