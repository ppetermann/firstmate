#!/usr/bin/env bash
# tests/fm-backlog-guard.test.sh - regression coverage for bin/fm-backlog-guard.sh.
#
# INCIDENT (2026-08-30): an ad-hoc script hand-edited data/backlog.md directly
# and a bad line silently dropped every Done-history entry below a marker,
# with no backup and nothing checking the result before it landed. This suite
# pins the guard's public CLI (check/apply), not its internals: a
# truncation-shaped candidate - one that still parses as valid markdown but
# drops task ids - must be refused and must never touch the live file, a
# legitimate edit (including a legitimate archive-move) must be accepted, and
# a refused apply must leave the live backlog byte-identical.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-backlog-guard.sh"

# make_home <dir>: seed a minimal FM_HOME with a small backlog fixture.
# Echoes the home dir.
make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat >"$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] task-a - doing a thing

## Queued
- [ ] task-b - queued thing

## Done
- [x] task-c - done thing (merged)
- [x] task-d - another done thing (merged)
EOF
  printf '%s\n' "$home"
}

run_guard() { # <home> <cmd> <candidate-backlog> [<candidate-archive>]
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$GUARD" "${@:2}"
}

test_valid_edit_applies() {
  local home candidate out status
  home=$(make_home "$TMP_ROOT/valid-home")
  candidate="$TMP_ROOT/valid-candidate.md"
  cp "$home/data/backlog.md" "$candidate"
  printf -- '- [x] task-e - new done thing (merged)\n' >>"$candidate"

  out=$(run_guard "$home" check "$candidate" 2>&1); status=$?
  expect_code 0 "$status" "a candidate that only adds an id should pass check"

  out=$(run_guard "$home" apply "$candidate" 2>&1); status=$?
  expect_code 0 "$status" "a candidate that only adds an id should apply cleanly"
  assert_contains "$out" "applied, backup at" "apply should report where the backup landed"
  assert_grep "task-e" "$home/data/backlog.md" "the live backlog should carry the new id after apply"
  assert_present "$home/state/.backlog-guard-backups" "apply should have created the backup directory"
  [ -n "$(find "$home/state/.backlog-guard-backups" -maxdepth 1 -name 'backlog.md.*')" ] ||
    fail "apply should have written a timestamped backup of the prior live file"

  pass "fm-backlog-guard: an id-preserving edit passes check and apply, and is backed up"
}

test_truncated_done_section_refused() {
  local home candidate before out status
  home=$(make_home "$TMP_ROOT/trunc-home")
  before=$(cat "$home/data/backlog.md")
  candidate="$TMP_ROOT/trunc-candidate.md"
  # Same shape as the 2026-08-30 incident: everything below the Done marker
  # for task-d is gone, but the file is still well-formed markdown.
  cat >"$candidate" <<'EOF'
# Backlog

## In flight
- [ ] task-a - doing a thing

## Queued
- [ ] task-b - queued thing

## Done
- [x] task-c - done thing (merged)
EOF

  out=$(run_guard "$home" check "$candidate" 2>&1); status=$?
  expect_code 1 "$status" "a truncated Done section must fail check"
  assert_contains "$out" "task id vanished: task-d" "check must name the vanished id"

  out=$(run_guard "$home" apply "$candidate" 2>&1); status=$?
  expect_code 1 "$status" "a truncated Done section must refuse apply"
  assert_contains "$out" "task id vanished: task-d" "apply must name the vanished id"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] ||
    fail "a refused apply must leave the live backlog byte-identical"
  [ ! -d "$home/state/.backlog-guard-backups" ] ||
    [ -z "$(find "$home/state/.backlog-guard-backups" -maxdepth 1 -name 'backlog.md.*')" ] ||
    fail "a refused apply must not write a backup"

  pass "fm-backlog-guard: a truncation-shaped candidate is refused and the live file is untouched"
}

test_dropped_section_header_refused() {
  local home candidate out status
  home=$(make_home "$TMP_ROOT/header-home")
  candidate="$TMP_ROOT/header-candidate.md"
  # Drops the whole "## Done" section (header and all), which also drops its
  # ids - two distinct violations should both surface.
  cat >"$candidate" <<'EOF'
# Backlog

## In flight
- [ ] task-a - doing a thing

## Queued
- [ ] task-b - queued thing
EOF

  out=$(run_guard "$home" check "$candidate" 2>&1); status=$?
  expect_code 1 "$status" "dropping the Done header must fail check"
  assert_contains "$out" "section header dropped: ## Done" "check must name the dropped header"

  pass "fm-backlog-guard: a dropped section header is refused independently of the id check"
}

test_pruned_via_archive_passes() {
  local home candidate archive out status
  home=$(make_home "$TMP_ROOT/prune-home")
  candidate="$TMP_ROOT/prune-candidate.md"
  archive="$TMP_ROOT/prune-archive.md"
  # A legitimate prune: task-d leaves backlog.md but lands in the archive
  # instead of vanishing - this is the real shape of routine Done pruning.
  cat >"$candidate" <<'EOF'
# Backlog

## In flight
- [ ] task-a - doing a thing

## Queued
- [ ] task-b - queued thing

## Done
- [x] task-c - done thing (merged)
EOF
  cat >"$archive" <<'EOF'
# Done archive

- [x] task-d - another done thing (merged)
EOF

  out=$(run_guard "$home" check "$candidate" "$archive" 2>&1); status=$?
  expect_code 0 "$status" "an id moved into the archive must not read as vanished"
  [ -z "$out" ] || fail "a clean prune-via-archive check should print nothing: $out"

  pass "fm-backlog-guard: an id moved to the archive file passes, not just an id kept in backlog.md"
}

test_backup_pruning_keeps_recent() {
  local home candidate i out status count
  home=$(make_home "$TMP_ROOT/backup-keep-home")
  candidate="$TMP_ROOT/backup-keep-candidate.md"
  cp "$home/data/backlog.md" "$candidate"

  for i in 1 2 3 4 5; do
    printf -- '- [x] task-extra-%s - filler (merged)\n' "$i" >>"$candidate"
    out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_BACKLOG_GUARD_KEEP=2 "$GUARD" apply "$candidate" 2>&1)
    status=$?
    expect_code 0 "$status" "apply #$i should succeed"
    cp "$home/data/backlog.md" "$candidate"
  done

  count=$(find "$home/state/.backlog-guard-backups" -maxdepth 1 -name 'backlog.md.*' | wc -l | tr -d '[:space:]')
  [ "$count" -le 2 ] || fail "FM_BACKLOG_GUARD_KEEP=2 should prune down to 2 backups, found $count"

  pass "fm-backlog-guard: backup pruning keeps only the configured most-recent count"
}

TMP_ROOT=$(fm_test_tmproot fm-backlog-guard)

test_valid_edit_applies
test_truncated_done_section_refused
test_dropped_section_header_refused
test_pruned_via_archive_passes
test_backup_pruning_keeps_recent
