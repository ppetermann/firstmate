#!/usr/bin/env bash
# tests/fm-afk-inject-herdr-e2e.test.sh - real-herdr end-to-end test for the
# away-mode daemon's herdr transport (bin/fm-supervise-daemon.sh), the herdr
# counterpart of tests/fm-afk-inject-e2e.test.sh's private-socket tmux e2e.
# Mirrors tests/fm-backend-herdr-smoke.test.sh and tests/herdr-test-safety.sh's
# isolation patterns: everything runs on a throwaway, named, NEVER-default
# HERDR_SESSION, torn down with herdr_safe_stop_and_delete. Skips cleanly when
# herdr or jq is not installed.
#
# Unlike the tmux e2e (which redirects a bare `tmux` PATH shim to a private
# socket), herdr already supports named-session isolation via --session, so no
# PATH redirection is needed for the happy path - the daemon is simply pointed
# at FM_SUPERVISOR_BACKEND=herdr, FM_SUPERVISOR_TARGET="<session>:<pane-id>",
# and HERDR_SESSION="<the isolated session>". A thin herdr SHIM is still used,
# but only to simulate a swallowed Enter (Scenario B) - herdr's real CLI has no
# built-in way to drop a keystroke, so the shim intercepts exactly one
# `pane send-keys <pane> enter` call and forwards everything else to the real
# binary untouched.
#
# The "supervisor pane" is a tiny deterministic bash loop (not a real harness
# binary): it draws a bordered composer row ("│ > <buf> │") that exercises the
# bordered branch of fm_backend_herdr_composer_state, and logs every submitted
# line (hex + text + injection/user classification) - the same technique
# tests/fm-afk-inject-e2e.test.sh uses for its tmux supervisor pane, so this
# test asserts on submitted CONTENT, not pane appearance. It ALSO registers
# itself as a real herdr agent via `herdr pane report-agent` and reports an
# idle/working/idle cycle around each submission, because
# fm_backend_herdr_send_text_submit's confirmation is native agent-state
# (agent get), not composer content, since the 2026-07-07 incident fix
# (docs/herdr-backend.md "Native agent-state submit confirmation") - a pane
# that only draws composer text without being a registered agent would read
# agent_not_found forever and never confirm a submission.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SESSION="fm-lab-afk-herdr-e2e-$$"
export HERDR_SESSION="$SESSION"
STATE_DIR=
HERDR_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_TARGET=
PANE_ID=
LOOP_SCRIPT=

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
  rm -rf "${HERDR_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# --- source the daemon (for afk_enter/afk_exit/FM_INJECT_MARK) + the backend -
# shellcheck source=/dev/null
. "$DAEMON"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- build the isolated session's supervisor pane ----------------------------

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-afk-e2e-supervisor" /tmp "$SEEDED_TAB_ID") \
  || fail "create_task for the scratch supervisor pane failed"
read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
SUPERVISOR_TARGET="$SESSION:$PANE_ID"

# Herdr can return the created pane before its interactive shell is ready to
# receive Enter. Require a stable shell-owned foreground before launching the
# fixture, or the command can remain typed but unsubmitted in the shell buffer.
PANE_READY=false
READY_SAMPLES=0
for _ in $(seq 1 100); do
  PROCESS_INFO=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null || true)
  if printf '%s' "$PROCESS_INFO" | jq -e '
    .result.process_info as $process
    | ($process.foreground_processes | length == 1)
      and ($process.foreground_processes[0].pid == $process.shell_pid)
  ' >/dev/null 2>&1; then
    READY_SAMPLES=$((READY_SAMPLES + 1))
    if [ "$READY_SAMPLES" -ge 10 ]; then
      PANE_READY=true
      break
    fi
  else
    READY_SAMPLES=0
  fi
  sleep 0.1
done
[ "$PANE_READY" = true ] || fail "the supervisor pane's shell did not become ready"

# A second, independent live task tab in the same workspace, mirroring the tmux
# e2e's fake fm-fake-c1 crewmate window - not required by scan_signals (which
# only watches state/*.status mtimes, no window/pane dependency), but kept for
# parity so this test's shape matches the tmux e2e's.
FAKE_CREW_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-fake-c1" /tmp) \
  || fail "could not create the fake crewmate scratch tab"
read -r _FAKE_TAB_ID FAKE_CREW_PANE_ID <<EOF
$FAKE_CREW_IDS
EOF

# --- deterministic bare-composer loop, drawn in the scratch pane -------------
# Mirrors tests/fm-afk-inject-e2e.test.sh's supervisor-loop.sh, but draws the
# shared classifier's positively identified bare-agent shape (`❯ <buf>`). This
# remains readable under the strict blank-row posture without pretending that
# one side-bordered row is a complete composer box. ALSO registers itself as a
# real herdr agent via `herdr pane report-agent` and reports idle/working
# transitions around each
# submission: fm_backend_herdr_send_text_submit's confirmation is now native
# agent-state (agent get), not composer content (docs/herdr-backend.md
# "Native agent-state submit confirmation"), so a synthetic pane that only
# draws composer TEXT but is never registered as an agent would report
# agent_not_found forever - every confirmation attempt would read 'unknown',
# never 'empty', and the daemon would treat every injection as unconfirmed and
# keep retyping it on every housekeeping tick (the exact duplicate-send
# failure mode this whole change exists to prevent) - discovered by this very
# test regressing when the composer-only version of this fixture was run
# against the new confirmation code. `herdr pane report-agent` is herdr's own
# documented integration-protocol primitive for a non-built-in-harness process
# to report its own agent state, verified empirically against real herdr 0.7.1
# in an isolated session.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
# The single owner of the `rule` shape's frame width: the fixture draws both
# rules this wide and Scenario E refuses any pane narrower than it.
FM_RULE_COLUMNS=53
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
# <shape>: `bordered` (default) draws the single-row "│ > buf │" box; `rule`
# draws claude's RULE-DELIMITED composer - a labelled top rule, a bare `❯` row,
# and a plain `─` closing rule - pinned to fixed rows so nothing scrolls.
# <frame-row>: the absolute row the `rule` shape's TOP rule is drawn on. The
# caller derives it from the pane's MEASURED height, because a frame pinned
# below the pane's last row is clamped onto that row and the three frame rows
# overwrite each other.
# <rule-columns>: how wide both rules are drawn. The caller owns this constant
# and refuses a pane narrower than it, because a wrapped closing rule puts a
# second plain rule row on screen and completes a separator pair.
SHAPE="${2:-bare}"
FRAME_ROW="${3:-18}"
RULE_COLUMNS="${4:-53}"
AGENT_SOURCE=fm-test-supervisor
AGENT_LABEL=fm-test-supervisor
report_agent_state() {  # <idle|working>
  herdr pane report-agent "$HERDR_PANE_ID" --source "$AGENT_SOURCE" --agent "$AGENT_LABEL" --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1
}
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
report_agent_state idle
[ "$SHAPE" = rule ] && printf '\033[2J'

_buf=
# redraw: keep the composer visually pinned to ONE terminal row regardless of
# _buf's length - a realistic bordered single-line composer horizontally
# scrolls to show the tail near the cursor rather than letting the terminal
# hard-wrap a too-long line across multiple rows (which would break the
# structural border-row classifier's one-row assumption: a batched escalation
# digest easily exceeds a narrow pane's column width). A hardcoded width
# (not `tput cols`) is used deliberately: verified empirically against a real
# herdr pane launched this same way that `tput cols` inside this script's own
# process reports 80 regardless of the pane's ACTUAL width (54, confirmed via
# a separate interactively-typed `tput cols`), so trusting it here silently
# let content overflow the real width and wrap across two rows. 40 is
# comfortably under every real pane width observed on this machine.
_shown() {
  local avail=40 tail_n
  if [ "${#_buf}" -gt "$avail" ]; then
    tail_n=$((avail - 3))
    printf '...%s' "${_buf: -$tail_n}"
  else
    printf '%s' "$_buf"
  fi
}
# claude's frame, drawn at fixed rows so the composer never scrolls off and no
# other plain `─` row can appear above it to complete a separator pair by
# accident. The TOP rule carries a label exactly as claude's does once the pane
# is wide enough to inline the in-progress todo, so it is NOT a plain rule and
# the pair stays incomplete - the shape that read `unknown` and wedged every
# away-mode escalation.
RULE_LABEL=" Run tests ──"
TOP_RULE="$(printf '─%.0s' $(seq 1 $((RULE_COLUMNS - ${#RULE_LABEL}))))$RULE_LABEL"
BOT_RULE="$(printf '─%.0s' $(seq 1 "$RULE_COLUMNS"))"
redraw() {
  local shown
  shown=$(_shown)
  if [ "$SHAPE" = rule ]; then
    printf '\033[%d;1H\033[K%s' "$FRAME_ROW" "$TOP_RULE"
    printf '\033[%d;1H\033[K❯ %s' "$((FRAME_ROW + 1))" "$shown"
    printf '\033[%d;1H\033[K%s' "$((FRAME_ROW + 2))" "$BOT_RULE"
    printf '\033[%d;%dH' "$((FRAME_ROW + 1))" "$((3 + ${#shown}))"
  else
    printf '\r\033[K❯ %s' "$shown"
  fi
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  # The rule shape owns absolute rows, so it must never emit a newline: one
  # scroll would move the frame out from under the structural reader.
  [ "$SHAPE" = rule ] || printf '\r\033[K\n'
  redraw
  # Report a real idle->working->idle cycle around the submission, exactly
  # like a real harness's agent_status - this is the signal
  # fm_backend_herdr_send_text_submit now confirms against. The 0.6s "working"
  # window comfortably covers the daemon's FM_INJECT_CONFIRM_SLEEP=0.5
  # per-attempt budget used by the scenarios below.
  report_agent_state working
  sleep 0.6
  report_agent_state idle
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

fm_backend_herdr_send_text_line "$SUPERVISOR_TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the supervisor-loop script in the scratch herdr pane"
sleep 1  # let the loop start and settle

# --- herdr shim: forwards to the real binary, optionally swallows one Enter --
REAL_HERDR=$(command -v herdr)
HERDR_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-shim.XXXXXX")
cat > "$HERDR_SHIM_DIR/herdr" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "pane" ] && [ "\${2:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  found_enter=0
  for _a in "\$@"; do [ "\$_a" = "enter" ] && found_enter=1; done
  if [ "\$found_enter" = 1 ]; then
    rm -f "$STATE_DIR/.swallow-enter"
    exit 0
  fi
fi
exec "$REAL_HERDR" "\$@"
SHIM
chmod +x "$HERDR_SHIM_DIR/herdr"

wait_daemon_started() {
  local label=${1:-daemon} start_line=${2:-0} i=0 new_log
  while [ "$i" -lt 30 ]; do
    new_log=$(tail -n +"$((start_line + 1))" "$STATE_DIR/.supervise-daemon.log" 2>/dev/null || true)
    if printf '%s\n' "$new_log" | grep -q 'backend=herdr'; then
      [ -f "$STATE_DIR/.supervise-daemon.pid" ] || fail "$label startup log recorded backend=herdr but no pid file was written"
      kill -0 "$DAEMON_PID" 2>/dev/null || fail "$label exited after recording backend=herdr"
      return 0
    fi
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
      fail "$label exited before recording backend=herdr: $(cat "$STATE_DIR/.supervise-daemon.log" 2>/dev/null)"
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
  fail "$label did not record backend=herdr after 6s: $new_log"
}

start_daemon() {
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  PATH="$HERDR_SHIM_DIR:$PATH" \
  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.5 \
  FM_INJECT_CONFIRM_RETRIES=6 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started daemon "$log_start"
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify pane_input_pending (dispatched through fm_backend_composer_state for
# backend=herdr) can detect typed text in THIS real herdr environment before
# trusting the scenarios below to prove anything.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "$check_text" \
    || fail "selfcheck: could not send literal text to the scratch pane"
  sleep 0.5
  if PATH="$HERDR_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_TARGET" herdr; then
    fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
    sleep 0.5
    return 0
  fi
  echo "pane_input_pending cannot detect typed text in this real-herdr environment" >&2
  fm_backend_herdr_capture "$SUPERVISOR_TARGET" 10 | sed 's/^/    /' >&2
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  fail "pane_input_pending self-check failed against real herdr"
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "human draft text"
  sleep 0.5

  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  sleep 8

  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while the herdr pane had pending input"
  fi
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  sleep 0.5

  sleep 8

  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after the pane went idle"
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "real herdr Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  sleep 10

  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario B: digest does not start with the terminal-safe sentinel marker (hex: $digest_hex)" ;;
  esac

  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted an empty line?)"

  stop_daemon
  pass "real herdr Scenario B: swallowed Enter (via the herdr shim) produces exactly one clean digest"
}

# --- Scenario C: normal digest -----------------------------------------------

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 8

  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with the terminal-safe sentinel marker (hex: $digest_hex)" ;;
  esac

  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "real herdr Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

# --- Scenario D: max-defer alarm on a persistently non-clearing composer -----
# A pending composer that NEVER clears (every Enter attempt leaves real text
# behind) must never be silently swallowed: the daemon must alarm (write
# state/.subsuper-inject-wedged) while preserving the buffered escalation, and
# must never crash or hot-loop. Exercises fm_backend_composer_state(herdr, ...)
# reporting "pending" indefinitely through the REAL structural border reader.

test_scenario_d_max_defer() {
  reset_state
  afk_enter "$STATE_DIR"
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  # Persistent-pending composer: type real text and never submit it, so every
  # composer read is genuinely "pending" against the real herdr binary.
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "stuck-in-the-box"
  sleep 0.5

  PATH="$HERDR_SHIM_DIR:$PATH" \
  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=99999 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_MAX_DEFER_SECS=3 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=2 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started "Scenario D daemon" "$log_start"

  echo "needs-decision: pick A or B" > "$STATE_DIR/fake-c1.status"

  sleep 12

  [ -s "$STATE_DIR/.subsuper-inject-wedged" ] \
    || fail "Scenario D: a persistently pending real herdr composer never raised the max-defer wedge alarm"
  [ -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "Scenario D: the buffered escalation was lost instead of preserved during the wedge"
  if grep -q 'Supervisor escalate' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario D: a digest was somehow logged as submitted despite the composer never clearing"
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "Scenario D: the daemon process died instead of alarming and continuing"
  grep -F 'stuck-in-the-box' "$STATE_DIR/daemon.err" >/dev/null 2>&1 && : # not fatal either way

  stop_daemon
  # Clean up the stuck composer text for a tidy teardown (best-effort).
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" C-c >/dev/null 2>&1 || true
  pass "real herdr Scenario D: a persistently pending composer raises the max-defer wedge alarm, preserves the buffer, and never crashes the daemon"
}

# --- Scenario E: claude's RULE-DELIMITED composer with a labelled top rule ---
# The captain's real away-mode failure, end to end. claude delimits its composer
# with a horizontal rule above and below; once the pane is wide enough it inlines
# the in-progress todo into the TOP rule, so that rule stops being a plain `─`
# run, the separator pair never completes, and claude's own CLOSING rule sat
# below the composer as an unmatched separator. The reader took that as proof the
# composer row was stale and answered `unknown` - and because the injector
# requires an affirmative `empty`, EVERY escalation deferred to the max-defer
# wedge alarm while the pane was idle and perfectly injectable (three episodes on
# 2026-08-08 alone, 935s/2473s/1545s undelivered).
#
# This drives the real daemon over the real herdr transport against that exact
# frame. Run against the pre-fix reader it reproduces the wedge: composer_state
# stays `unknown`, no digest is ever submitted, and .subsuper-inject-wedged is
# raised. It therefore fails loudly if the structural rescue is ever lost.
test_scenario_e_rule_delimited_composer() {
  local ids _tab_id pane_id target verdict saved_target pane_layout pane_height pane_width frame_row
  reset_state

  ids=$(fm_backend_herdr_create_task "$CONTAINER" "fm-afk-e2e-rule" /tmp) \
    || fail "Scenario E: could not create the rule-delimited composer pane"
  read -r _tab_id pane_id <<EOF
$ids
EOF
  [ -n "$pane_id" ] || fail "Scenario E: create_task returned no pane id"
  target="$SESSION:$pane_id"

  local ready=false samples=0 _i
  for _i in $(seq 1 100); do
    if fm_backend_herdr_cli "$SESSION" pane process-info --pane "$pane_id" 2>/dev/null | jq -e '
      .result.process_info as $process
      | ($process.foreground_processes | length == 1)
        and ($process.foreground_processes[0].pid == $process.shell_pid)' >/dev/null 2>&1; then
      samples=$((samples + 1))
      [ "$samples" -ge 10 ] && { ready=true; break; }
    else
      samples=0
    fi
    sleep 0.1
  done
  [ "$ready" = true ] || fail "Scenario E: the rule-delimited pane's shell did not become ready"

  # The `rule` shape owns ABSOLUTE cursor rows and draws a frame FM_RULE_COLUMNS
  # wide, so BOTH pane dimensions must be measured before it is drawn, and both
  # refusals are worded in fixture/geometry terms, deliberately apart from the
  # captain's-wedge assertion, so a mis-sized pane can never be misdiagnosed as
  # the regression this scenario exists to detect.
  #   height - in a pane shorter than the frame the terminal clamps all three
  #     printf targets onto the last row and they overwrite each other, so the
  #     verdict below would read `unknown` for a fixture that never drew the
  #     shape. The frame origin is derived from the measured height.
  #   width - in a narrower pane the closing rule WRAPS, and its remainder lands
  #     on the row below as a second plain rule. That completes a separator pair
  #     around the composer row, so the reader answers from the untouched
  #     matched-pair branch and the scenario would pass green through a path the
  #     pre-fix reader handled too, proving nothing about the rescue it exists
  #     to pin.
  pane_layout=$(fm_backend_herdr_cli "$SESSION" pane layout --pane "$pane_id" 2>/dev/null \
    | jq -r --arg pane "$pane_id" \
      '.result.layout.panes[]? | select(.pane_id == $pane) | "\(.rect.height) \(.rect.width)"' 2>/dev/null | head -1)
  read -r pane_height pane_width <<EOF
$pane_layout
EOF
  case "${pane_height:-}" in ''|*[!0-9]*) pane_height=0 ;; esac
  case "${pane_width:-}" in ''|*[!0-9]*) pane_width=0 ;; esac
  [ "$pane_height" -ge 12 ] || fail \
    "Scenario E FIXTURE GEOMETRY (not a composer regression): 'herdr pane layout' reports height '$pane_height' for the lab pane, which is unreadable or too short to hold the three-row rule-delimited frame at absolute cursor rows. Repair the fixture's geometry; do not read this as the away-mode wedge."
  [ "$pane_width" -ge "$FM_RULE_COLUMNS" ] || fail \
    "Scenario E FIXTURE GEOMETRY (not a composer regression): 'herdr pane layout' reports width '$pane_width' for the lab pane, which is unreadable or narrower than the fixture's $FM_RULE_COLUMNS-column frame, so the closing rule would wrap into a second plain rule row and complete a separator pair the reader answers from without the rescue. Repair the fixture's geometry; do not read this as the away-mode wedge."
  frame_row=$((pane_height - 5))

  fm_backend_herdr_send_text_line "$target" "bash '$LOOP_SCRIPT' '$LOG_FILE' rule $frame_row $FM_RULE_COLUMNS" \
    || fail "Scenario E: could not start the rule-delimited composer fixture"
  sleep 2

  # The frame must be exactly the failing one: an idle composer that the reader
  # can now affirm as EMPTY. Asserting it here means a later delivery failure
  # cannot be mistaken for a fixture that never drew the shape.
  verdict=$(fm_backend_herdr_composer_state "$target")
  [ "$verdict" = empty ] || fail \
    "Scenario E: an idle claude-style rule-delimited composer reads '$verdict', not empty - the away-mode injector refuses to inject into anything but an affirmative empty, so every escalation would defer until the max-defer alarm (this is the captain's wedge)"

  saved_target=$SUPERVISOR_TARGET
  SUPERVISOR_TARGET=$target
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/500" > "$STATE_DIR/fake-c1.status"
  sleep 8

  local marker_count digest_line user_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario E: expected exactly 1 escalation delivered into the rule-delimited composer, got $marker_count (0 means the wedge is back: the reader could not affirm the composer empty and the daemon deferred)"
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario E: digest misclassified (expected injection): $digest_line" ;;
  esac
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario E: expected 0 user lines, got $user_count (a spurious Enter submitted an empty line?)"
  [ ! -s "$STATE_DIR/.subsuper-inject-wedged" ] \
    || fail "Scenario E: the max-defer wedge alarm was raised even though the composer was injectable"

  stop_daemon
  SUPERVISOR_TARGET=$saved_target
  fm_backend_herdr_kill "$target" 2>/dev/null || true
  pass "real herdr Scenario E: an away-mode escalation is delivered into claude's rule-delimited composer whose top rule carries an inline label"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d_max_defer
test_scenario_e_rule_delimited_composer

echo "all real-herdr afk injection e2e tests passed"

fm_backend_herdr_kill "$SUPERVISOR_TARGET" 2>/dev/null || true
fm_backend_herdr_kill "$SESSION:$FAKE_CREW_PANE_ID" 2>/dev/null || true
cleanup_all
trap - EXIT
