#!/usr/bin/env bash
# tests/fm-task-inbox-fleet.test.sh - this fleet's own steering-inbox cases
# (bin/fm-task-inbox-lib.sh): a doorbell left sitting in the composer is
# reported rather than counted as rung, and an escalated, unacknowledged
# message never parks the ladder for a later one, including the zero-ring
# dead-endpoint escalation. They live beside upstream's
# tests/fm-task-inbox.test.sh so a take-in never re-resolves them inside it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-inbox-fleet)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# The fixture helpers below are copies of upstream's suite's, except that
# make_watch_stubs' fake tmux also honors FM_FAKE_TMUX_CAPTURE_AFTER.
# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable. With
# FM_FAKE_TMUX_AGENT set, the inventory lists window fm-t1 and its
# #{pane_current_command} answers with that value, so `zsh` makes
# fm_backend_tmux_agent_state read the pane as a dead bare shell. With
# FM_FAKE_TMUX_CAPTURE_AFTER set, the first literal send switches the replayed
# capture to that file, which models a harness that accepted the typed line and
# then swallowed the Enter.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    if [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ]; then
      printf 'send failed\n' >> "${FM_SEND_LOG:-/dev/null}"
      exit 1
    fi
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
      # A swallowed Enter: the typed line lands in the composer and stays
      # there, so every capture from here on renders a pending composer.
      if [ -n "${FM_FAKE_TMUX_CAPTURE_AFTER:-}" ] && [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
        cp "$FM_FAKE_TMUX_CAPTURE_AFTER" "$FM_FAKE_TMUX_CAPTURE"
      fi
      # A concurrent fire-and-forget send marking its newer record mid-ring.
      if [ -n "${FM_RING_MARKS_RETRY:-}" ]; then
        printf '%s\n' "${FM_RING_MARKS_RETRY##*/}" > "${FM_RING_MARKS_RETRY%/*}/.retry-ring"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
        *pane_tty*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '\n'; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

# A doorbell that is typed and then NOT submitted delivered nothing, however
# healthy the pane looks. Two shapes, because they fail through different
# layers: on an idle pane the submit verdict itself reads `pending`, while on a
# busy pane the adapter's queued-Enter policy legitimately converts that same
# proven-pending composer into `empty` (a harness that queues a busy Enter),
# which is exactly why the ring reads the pane after submitting instead of
# trusting the verdict. Both must reach the caller as the distinct
# not-submitted code, never as a successful ring.
test_ring_reports_a_doorbell_that_never_left_the_composer() {
  local dir state rec log rc pending empty
  dir="$TMP_ROOT/ring-unsubmitted"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  empty="$dir/composer-empty.txt"
  pending="$dir/composer-pending.txt"
  printf '\u256d\u2500\u2500\u2500\u2500\u256e\n\u2502    \u2502\n\u2570\u2500\u2500\u2500\u2500\u256f\n' > "$empty"
  printf '\u256d\u2500\u2500\u2500\u2500\u256e\n\u2502 hi \u2502\n\u2570\u2500\u2500\u2500\u2500\u256f\n' > "$pending"

  # Sanity: the two captures really do drive the classifier apart, so neither
  # half of this case can go quietly vacuous.
  cp "$empty" "$dir/live.txt"
  [ "$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_AGENT=claude \
      inbox_lib "$state" fm_backend_composer_state tmux sess:fm-t1 fm-t1)" = empty ] \
    || fail "the empty-composer fixture should classify empty"
  cp "$pending" "$dir/live.txt"
  [ "$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_AGENT=claude \
      inbox_lib "$state" fm_backend_composer_state tmux sess:fm-t1 fm-t1)" = pending ] \
    || fail "the pending-composer fixture should classify pending"

  # And that the two panes really do drive the SUBMIT VERDICT apart, which is
  # the whole reason the ring reads the pane afterwards: on the busy pane the
  # queued-Enter policy reports the same swallowed Enter as a clean `empty`.
  cp "$empty" "$dir/live.txt"
  [ "$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_AGENT=claude \
      FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_CAPTURE_AFTER="$pending" \
      inbox_lib "$state" fm_backend_send_text_submit tmux sess:fm-t1 doorbell 1 0 0 fm-t1)" = pending ] \
    || fail "an idle pane's swallowed Enter should report a pending verdict"
  cp "$empty" "$dir/live.txt"
  [ "$(PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_AGENT=claude FM_BUSY_REGEX='hi' \
      FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_CAPTURE_AFTER="$pending" \
      inbox_lib "$state" fm_backend_send_text_submit tmux sess:fm-t1 doorbell 1 0 0 fm-t1)" = empty ] \
    || fail "a busy pane's swallowed Enter should be converted to an empty verdict, which is what hides it"

  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  log="$dir/send.log"

  # Idle pane: the composer holds the typed line after our Enter.
  cp "$empty" "$dir/live.txt"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_CAPTURE_AFTER="$pending" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 4 ] || fail "an unsubmitted doorbell on an idle pane should return 4, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" \
    || fail "the doorbell should still have been typed before the failure was detected"
  [ -f "$rec" ] || fail "a failed ring must leave the durable record in place"

  # Busy pane: the queued-Enter policy converts the verdict to `empty`, so only
  # the post-submit pane read can still tell that nothing was delivered.
  cp "$empty" "$dir/live.txt"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_CAPTURE_AFTER="$pending" \
    FM_BUSY_REGEX='hi' \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 4 ] || fail "an unsubmitted doorbell on a busy pane should return 4, got $rc"
  [ -f "$rec" ] || fail "a failed busy-pane ring must leave the durable record in place"

  # The counterfactual: same fixtures, but the composer clears after the
  # submit, which is an ordinary successful ring.
  cp "$empty" "$dir/live.txt"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    FM_FAKE_TMUX_CAPTURE="$dir/live.txt" FM_FAKE_TMUX_CAPTURE_AFTER="$empty" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "a submitted doorbell should still ring successfully, got $rc"
  pass "inbox: a doorbell left sitting in the composer is reported, not counted as rung"
}

# Finding B, data/fm-steer-stall-diagnosis/report.md: test_ring_ladder_policy
# above is strictly serial (escalate, THEN acknowledge, THEN write the next
# message), so it can never observe a message written WHILE an earlier one is
# still escalated and unacknowledged - exactly the ordinary situation ("a
# steer sent while the worker is momentarily gone") that parked the whole
# task's ladder forever before this fix. Both parking paths are covered: the
# ordinary ring-budget escalation, and the dead-or-missing-endpoint escalation
# that parks with zero ring attempts (fm_task_inbox_record_escalated called
# directly, mirroring inbox_steer_escalate_unavailable in bin/fm-watch.sh).
test_ring_ladder_survives_a_parked_escalation() {
  local state rec1 rec2 rec3 action
  state="$TMP_ROOT/ladder-parked/state"; mkdir -p "$state"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  age_path "$rec1"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec1"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec1 3" ] || fail "a spent ring budget should escalate, got: $action"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec1"
  # The missing assertion test_ring_ladder_policy's own comment says is the
  # boundary it never tests: with 001 escalated and STILL unacknowledged, a
  # brand-new 002 must still get its own delivery attempt.
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second, written while 001 is still parked")
  age_path "$rec2"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec2" ] \
    || fail "a message written while an older one is parked, unacknowledged, must still ring, got: $action"
  # A third message must not disturb 002's own ladder while it is active.
  rec3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  age_path "$rec3"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec2" ] \
    || fail "a still-active ladder subject must not be displaced by a newer message, got: $action"
  # Acknowledging ONLY the parked 001 changes nothing about 002's own ladder;
  # it simply stops being the reason a redirect is needed.
  mv "$rec1" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec2" ] \
    || fail "acknowledging the parked message should not disturb the active ladder subject, got: $action"
  # 002 can independently escalate too, without 001's earlier escalation
  # marker being clobbered or reused for a message it was never about.
  printf '002.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec2 3" ] || fail "002 should escalate independently of 001, got: $action"
  pass "inbox: a message written while an earlier one is parked, unacknowledged, still starts its own ladder"
}

# The dead-or-missing-endpoint path (inbox_steer_escalate_unavailable in
# bin/fm-watch.sh) writes the escalation marker immediately, with zero ring
# attempts - reachable the instant a steer lands while the worker's agent is
# momentarily gone. That is ordinary and frequent, so it must park only the
# one record it named, never the whole task.
test_dead_endpoint_escalation_parks_only_its_own_record() {
  local state rec1 rec2 action
  state="$TMP_ROOT/ladder-dead-endpoint/state"; mkdir -p "$state"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "sent while the agent was gone")
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec1"
  [ ! -e "$state/t1.inbox/.ring-state" ] \
    || fail "a dead-endpoint escalation must not have rung, so no ring-state should exist"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "the zero-ring-escalated record alone should stay parked, got: $action"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "worker recovered; firstmate steers again")
  age_path "$rec2"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec2" ] \
    || fail "a steer sent after the worker recovers must still ring, got: $action"
  pass "inbox: a zero-ring dead-endpoint escalation parks only its own record"
}

test_ring_reports_a_doorbell_that_never_left_the_composer
test_ring_ladder_survives_a_parked_escalation
test_dead_endpoint_escalation_parks_only_its_own_record
