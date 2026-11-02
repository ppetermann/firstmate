#!/usr/bin/env bash
# tests/fm-watch-triage-fleet.test.sh - this fleet's own wake-triage cases for
# the watcher: verb-carrying signal and capped check payloads, stale-echo
# absorption, and the declared-pause cadence of a busy pane by agent liveness.
# They live beside upstream's tests/fm-watch-triage.test.sh, sharing its
# fixtures in tests/watch-triage-helpers.sh, so a take-in never re-resolves
# them inside upstream's suite.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-fleet-tests)

# Same two fixtures upstream's suite defines locally (see its comments): prime
# a turn-ended marker's .seen-* suppressor, and record a Pi busy event.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Signal payloads carry per-task status verbs after the path list: firstmate
# reads the queue row and knows each task's latest verb without re-reading the
# status files. The daemon's classify_signal skips the verb tokens (its
# existence check ignores them), pinned by fm-daemon.test.sh regression.
test_signal_payload_carries_verbs() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case signal-verbs); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'done: ready in branch fm/x\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a done signal"
  grep -Eq "signal:.*\\.status [|] task=done" "$out" \
    || fail "signal wake does not carry the done verb suffix: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the done signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -Eq "\\.status \\| task=done" \
    || fail "queued signal row does not carry the verb suffix"

  dir=$(make_case signal-verbs-needs-decision); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'needs-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a needs-decision signal"
  grep -Eq "signal:.*\\.status [|] task=needs-decision" "$out" \
    || fail "signal wake does not carry the needs-decision verb suffix: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the needs-decision signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -Eq "\\.status \\| task=needs-decision" \
    || fail "queued needs-decision row does not carry the verb suffix"
  pass "signal payloads carry per-task status verbs after the path list"
}

# Check payloads are capped with a durable sidecar: the queue row stays bounded
# while the full output survives on disk, named in the truncation marker.
test_check_payload_capped_with_sidecar() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check-cap); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
head -c 200 /dev/zero | tr '\0' 'x'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register the capped custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_CHECK_PAYLOAD_MAX=64 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for the capped check output"
  grep -Eq 'x{64} \[truncated; full output: '"$state"'/\.check-out-task\]' "$out" \
    || fail "capped check wake does not end with the truncation marker: $(cat "$out")"
  [ "$(wc -c < "$state/.check-out-task" | tr -d ' ')" -ge 200 ] \
    || fail "the sidecar does not hold the full output bytes"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the capped check failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F '[truncated; full output:' >/dev/null \
    || fail "queued check row does not carry the truncation marker"

  # A small output stays byte-untouched and writes no sidecar.
  dir=$(make_case check-uncapped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  check_file="$state/small.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/2\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" small >/dev/null \
    || fail "could not register the small custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_CHECK_PAYLOAD_MAX=64 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for the small check output"
  grep -F "check: $check_file: merged: https://example.test/pr/2" "$out" >/dev/null \
    || fail "small check output was altered: $(cat "$out")"
  [ ! -e "$state/.check-out-small" ] || fail "a small check output must not write a sidecar"
  pass "check payloads are capped with a durable sidecar; small outputs stay untouched"
}

# --- stale echo: a repainted pane over an ALREADY-SURFACED terminal status ---------
# The terminal-stale surface path writes the surfaced marker (mark_surfaced), the
# same marker the away-daemon reads to dedupe terminal statuses. When the pane
# repaints with a NEW hash while the status log still ends in the exact line that
# was already surfaced (clock, token counter, idle prompt), the echo check
# absorbs the stale on the bounded re-surface cadence instead of waking firstmate
# again for the same fact.
test_stale_echo_absorbed_after_surface() {
  local dir state fakebin out capture_file window key sig pid pane_hash2
  dir=$(make_case stale-echo-absorbed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-echo"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/echo.meta"
  printf 'done: PR https://example.test/pr/7 checks green\n' > "$state/echo.status"
  sig=$(seen_sig "$state/echo.status"); printf '%s' "$sig" > "$state/.seen-echo_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Phase A: first sighting of the terminal stale surfaces (queue row + exit) and
  # records the surfaced marker over the exact last line.
  printf 'finished, awaiting review' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for the first terminal stale surface"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "first sighting did not print the stale wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-echo" "$state/echo.status")" = \
    "$(size_of "$state/echo.status")" ] \
    || fail "terminal stale surface did not record the surfaced marker through its end"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-A watcher stop"

  # Phase B: repaint the pane (new hash, same terminal status line), crew state
  # done. The marker match absorbs the echo: the watcher survives a full poll,
  # no new queue row appears, and the triage log names the absorb.
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  : > "$out"
  printf 'finished, awaiting review (clock 12:01)' > "$capture_file"
  pane_hash2=$(hash_text "finished, awaiting review (clock 12:01)")
  printf '%s' "$pane_hash2" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 60; then
    reap "$pid"; fail "watcher exited on a repaint over an already-surfaced terminal status: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the absorbed stale echo enqueued a wake"
  grep -F "absorbed stale echo" "$state/.watch-triage.log" >/dev/null || fail "no absorbed-stale-echo triage line"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash2" ] || fail "echo absorb did not advance the stale suppressor"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-B watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "a repainted pane over an already-surfaced terminal status is absorbed as a stale echo"
}

# Past the bounded cadence the absorbed echo re-surfaces once per window, so a
# wedged post-done harness cannot rot invisibly behind echo suppression.
test_stale_echo_resurfaces_past_cadence() {
  local dir state fakebin out drain_out capture_file window key sig pid
  dir=$(make_case stale-echo-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-echore"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/echore.meta"
  printf 'done: PR https://example.test/pr/8 checks green\n' > "$state/echore.status"
  sig=$(seen_sig "$state/echore.status"); printf '%s' "$sig" > "$state/.seen-echore_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Phase A: surface the terminal status once.
  printf 'finished, awaiting review' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for the first terminal stale surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-A watcher stop"

  # Phase B: a repaint is absorbed as an echo, starting the echo clock.
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  : > "$out"
  printf 'finished, awaiting review (clock 12:01)' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review (clock 12:01)")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 60; then
    reap "$pid"; fail "watcher exited on the first repaint under absorb: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the first repaint was not absorbed as an echo"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-B watcher stop"

  # Phase C: age the echo clock past the cadence, then repaint again - the
  # bounded re-surface fires with the echo reason text.
  set_mtime "$(( $(date +%s) - 5 ))" "$state/.stale-echo-since-$key"
  : > "$out"
  printf 'finished, awaiting review (clock 12:02)' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review (clock 12:02)")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a stale echo past the cadence"
  grep -F "terminal status already surfaced" "$out" >/dev/null || fail "re-surface did not use the echo reason text"
  grep -F "possible wedge" "$out" >/dev/null && fail "an absorbed echo re-surface was mislabeled a possible wedge"
  [ -e "$state/.stale-echo-resurfaced-$key" ] || fail "the echo re-surface throttle marker was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the echo re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "echo re-surface was not queued"
  unset FM_FAKE_CREW_STATE
  pass "an absorbed stale echo re-surfaces on the long cadence so a wedged post-done pane stays visible"
}

# A GENUINELY new captain-relevant terminal line beats echo suppression: the
# marker holds the previously surfaced line, so a different last line surfaces
# immediately and restarts the echo clock for the new line.
test_stale_new_terminal_line_surfaces_after_echo() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case stale-echo-newline); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-echonew"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/echonew.meta"
  statusf="$state/echonew.status"
  printf 'done: PR https://example.test/pr/9 checks green\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-echonew_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')

  # Phase A: surface the terminal status once.
  printf 'finished, awaiting review' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for the first terminal stale surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-A watcher stop"

  # Phase B: a repaint is absorbed as an echo over the surfaced done: line.
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  : > "$out"
  printf 'finished, awaiting review (clock 12:01)' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review (clock 12:01)")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" 60; then
    reap "$pid"; fail "watcher exited on the repaint under absorb: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the repaint was not absorbed as an echo"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-B watcher stop"

  # Phase C: append a genuinely new terminal line, re-prime the signal suppressor
  # so only the stale path speaks, and repaint - the marker mismatch surfaces.
  printf 'blocked: waiting on the captain\n' >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-echonew_status"
  : > "$out"
  printf 'finished, awaiting review (clock 12:02)' > "$capture_file"
  printf '%s' "$(hash_text "finished, awaiting review (clock 12:02)")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a new terminal line after an absorbed echo"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the new terminal line did not print a plain stale wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-echonew" "$statusf")" = "$(size_of "$statusf")" ] \
    || fail "the fresh surface did not move the marker through the new terminal line"
  unset FM_FAKE_CREW_STATE
  pass "a new terminal line after an absorbed echo surfaces immediately (marker mismatch beats echo suppression)"
}

# --- busy pane duration bound meets a declared pause -------------------------
# The 2026-08-14 second incident in the 8b42731 class: a crew polling an
# external wait INSIDE one long busy turn (spinner churning the pane hash, so
# the busy branch runs every poll) kept busy classification past
# BUSY_TURN_MAX_SECS, and the busy path called wedge_timer_check directly
# without ever consulting pause_state_class - so a legitimately paused-and-busy
# crew wedge-escalated every STALE_ESCALATE_SECS with the generic possible-wedge
# message and the .paused-* markers were never set. The busy-turn route now
# applies the same contract the stale path applies: a declared pause with a
# live agent absorbs on the bounded PAUSE_RESURFACE_SECS cadence, while a
# confidently dead agent under the pause still falls back to working so
# genuine wedge escalation resumes.
test_busy_pane_declared_pause_live_agent_holds_pause_cadence() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid
  dir=$(make_case busy-paused-live-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  statusf="$state/busy-paused-live.status"; window="test:fm-busy-paused-live"
  printf 'Working... (420.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-paused-live.meta"
  record_pi_busy "$state" busy-paused-live
  printf 'paused: external rate-limit window; polling the API inside one long turn\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-busy-paused-live_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-paused-live.turn-ended"
  prime_turnend_seen "$state/busy-paused-live.turn-ended"
  # The incident's exact evidence: the pane is authoritatively busy while the
  # agent itself is alive (the foreground is the external-wait poller, so the
  # liveness probe reads unknown, never confidently dead).
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy footer (busy)'

  # Phase A: the pane is busy past the turn-age bound with a declared pause and
  # a live agent - and a wedge escalation already mid-flight, as if several
  # over-age polls already ran. The pause must engage and disarm the wedge.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=node \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a paused live busy crew wedge-escalated on the short cadence: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a paused live busy crew printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a paused live busy crew enqueued a wake"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "a paused live busy crew never recorded the pause marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "a paused live busy crew kept a wedge timer armed"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a paused live busy crew kept its escalation counter armed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the phase-A busy pause engagement"

  # Phase B: age the declaration past the pause re-surface threshold - the one
  # wake is the bounded paused recheck, never a possible-wedge escalation.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-busy-paused-live_status"
  printf 'Working... (421.2s)' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=node \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a paused live busy crew did not re-surface past the pause cadence"
  grep -F "awaiting external" "$out" >/dev/null || fail "busy-path pause re-surface was not the paused recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a paused live busy crew was mislabeled a wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the busy-path re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "the busy-path paused recheck used the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the busy-path paused recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "busy-path paused recheck was not queued"
  ack_stopped_cycle "$state" || fail "could not acknowledge the busy-path paused recheck"

  # Phase C: repeated unchanged polls - the throttle holds, no wedge, no rewake.
  printf 'Working... (422.3s)' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=node \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an unchanged paused busy crew rewoke off the pause cadence: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "an unchanged paused busy crew printed a wake reason: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "an unchanged paused busy crew lost its pause marker"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the silent busy pause round"
  unset FM_FAKE_CREW_STATE
  pass "a busy crew past the turn-age bound under a declared pause with a live agent absorbs on the pause cadence instead of wedge-escalating"
}

# Dead-agent control for the busy-path pause route: the detector is not blunted
# by the new pause awareness. A crew whose agent is confidently dead while its
# pane still shows busy (an orphaned foreground behind an exited worker) must
# fall back to working and resume wedge escalation exactly as before, including
# continuing the existing escalation counter.
test_busy_pane_declared_pause_dead_agent_resumes_wedge() {
  local dir state fakebin out capture_file window key sig pid back
  dir=$(make_case busy-paused-dead-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-paused-dead"
  printf 'Working... (420.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-paused-dead.meta"
  record_pi_busy "$state" busy-paused-dead
  printf 'paused: external rate-limit window; polling the API inside one long turn\n' > "$state/busy-paused-dead.status"
  sig=$(seen_sig "$state/busy-paused-dead.status"); printf '%s' "$sig" > "$state/.seen-busy-paused-dead_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-paused-dead.turn-ended"
  prime_turnend_seen "$state/busy-paused-dead.turn-ended"
  # A pause was engaged earlier while the agent lived; the agent has since
  # exited (foreground is a plain shell) and the verdict cache has expired, so
  # this poll must re-read crew state rather than trust the stale engagement.
  : > "$state/.paused-$key"
  back=$(( $(date +%s) - 500 ))
  printf '%s\n' "$back" > "$state/.paused-rechecked-$key"
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/.paused-rechecked-$key"
  else touch -m -d "@$back" "$state/.paused-rechecked-$key"; fi
  # A wedge escalation already mid-flight from earlier over-age polls.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: pane · busy footer (busy)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a confidently dead agent under a busy-path declared pause did not wedge-escalate"
  grep -F "possible wedge" "$out" >/dev/null || fail "dead-agent busy-path escalation omitted its reason: $(cat "$out")"
  grep -F "escalation 2" "$out" >/dev/null || fail "dead-agent busy-path escalation did not continue the counter: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "a dead agent under a busy-path declared pause was absorbed as paused"
  [ ! -e "$state/.paused-$key" ] || fail "dead agent under a busy-path declared pause retained paused mode"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after the dead-agent busy-path escalation"
  unset FM_FAKE_CREW_STATE
  pass "a confidently dead agent under a busy-path declared pause resumes wedge escalation with its counter intact"
}

fm_test_run \
  test_signal_payload_carries_verbs \
  test_check_payload_capped_with_sidecar \
  test_stale_echo_absorbed_after_surface \
  test_stale_echo_resurfaces_past_cadence \
  test_stale_new_terminal_line_surfaces_after_echo \
  test_busy_pane_declared_pause_live_agent_holds_pause_cadence \
  test_busy_pane_declared_pause_dead_agent_resumes_wedge
