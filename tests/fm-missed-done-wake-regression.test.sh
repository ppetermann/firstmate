#!/usr/bin/env bash
# tests/fm-missed-done-wake-regression.test.sh - regression pin for the
# 2026-08-30 missed-done-wake incident (task fm-missed-done-wake).
#
# Root cause (confirmed by a separate, parallel fix task tracked as upstream
# commit 4eb587d / PR #3268, "prevent routine updates from hiding actionable
# status"): a worker's `done:` completion never woke firstmate because a
# routine `working:` note landed in the SAME signal-grace batch, after the
# done: line, while the crew was provably working (an active run-step).
# bin/fm-classify-lib.sh's classification only ever inspected the LAST status
# line (last_status_line + status_is_captain_relevant): the routine line
# masked the done: underneath it, so signal_reason_is_actionable saw only
# "working: ..." (never captain-relevant) and signal_crew_provably_working
# reported the crew as working, and the watcher absorbed the whole batch
# instead of surfacing the done:. The heartbeat fleet-scan backstop
# (scan_captain_relevant_statuses) shares the identical last-line-only defect,
# so it cannot rescue what the primary path drops either - both safety nets
# fail together, matching the incident (the completion was found only by the
# captain reading the pane directly, never through any automated path).
#
# This file deliberately sits OUTSIDE tests/fm-watch-triage.test.sh: this
# framework's fail() exits the whole script on the first failure
# (tests/lib.sh), so a permanently-red test placed inside that ~90-test file
# would silently stop every test after it from running until the upstream fix
# lands. Kept isolated here, only this dedicated file is red in the interim
# (bin/fm-test-run.sh runs each tests/*.test.sh independently and treats an
# unmapped basename as normal - see its family_for_basename header comment).
#
# These tests pin the drop through the public interface (status append ->
# bin/fm-watch.sh -> bin/fm-wake-drain.sh); do not "fix" a future regression
# here by weakening the assertions or by teaching them about the old
# last-line behavior. Both now pass: the first once upstream #3268 landed
# status_span_first_actionable, the second once the heartbeat backstop
# (bin/fm-watch.sh's heartbeat_scan_finds_actionable) started naming the
# buried captain-relevant line in its wake reason instead of only signaling
# that it found one - see FM_HEARTBEAT_ACTIONABLE_ROWS at its definition.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-missed-done-wake-regression-tests)

# Common watcher knobs, duplicated from tests/fm-watch-triage.test.sh's own
# watch_bg rather than shared, so this pinned regression file has no import
# dependency on the file most likely to be touched by the upstream fix.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Write a <status-file>'s .seen-* marker as though the signal path already
# classified it through its current end - the v2 presentation-marker format
# fm-classify-lib.sh's status_presentation_marker_commit owns (a raw stat
# signature, this file's pre-#3268 format, no longer parses as current and
# would leave the signal path treating the file as still-pending).
mark_status_seen() {  # <status-file> <seen-marker-path>
  local f=$1 marker=$2 record size ident
  record=$(status_span_first_actionable_record "$f" 0)
  size=${record%%$'\t'*}
  ident=${record#*$'\t'}; ident=${ident%%$'\t'*}
  status_presentation_marker_commit "$marker" "$f" "$size" "$ident"
}

test_masked_done_behind_trailing_routine_note_surfaces() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case masked-done-trailing-note); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: implementing\ndone: ready in branch fm/example\nworking: cleaning up scratch files\n' > "$status_file"
  # Positive working evidence (an active run-step) is exactly the condition
  # that let the trailing routine note absorb the whole batch in the incident.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "watcher absorbed a done: event masked by a later routine note (the 2026-08-30 missed-wake drop)"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "watcher did not print a signal for the masked done: event"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the masked done: event failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "masked done: event was not queued"
  pass "a done: event behind a later routine note still surfaces"
}

test_masked_done_behind_trailing_routine_note_backstop_also_surfaces() {
  local dir state fakebin out pid
  dir=$(make_case masked-done-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'working: implementing\ndone: ready in branch fm/example\nworking: cleaning up scratch files\n' > "$state/miss.status"
  # Simulate the per-wake path already having looked at (and absorbed) this
  # exact content, so only the heartbeat fleet-scan backstop is under test.
  mark_status_seen "$state/miss.status" "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "heartbeat backstop did not rescue a done: event buried behind a trailing routine note"
  grep -F 'done: ready in branch fm/example' "$out" >/dev/null \
    || fail "backstop wake did not name the buried done: line: $(cat "$out")"
  pass "the heartbeat backstop also rescues a done: event buried behind a trailing routine note"
}

test_masked_done_behind_trailing_routine_note_surfaces
test_masked_done_behind_trailing_routine_note_backstop_also_surfaces
