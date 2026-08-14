#!/usr/bin/env bash
# tests/fm-afk-shutdown-e2e.test.sh - away mode stops deterministically, from
# every state the daemon can be parked in when the captain returns.
#
# The bug this pins: `bin/fm-afk-launch.sh stop` SIGTERMs the daemon and waits a
# fixed budget for it to exit. Bash runs a trapped handler only after the current
# FOREGROUND command finishes, so a daemon parked in a long wait - or blocking on
# a watcher child parked in one - answered that SIGTERM long after the budget and
# stop reported "away-mode daemon did not exit after SIGTERM; preserving
# lifecycle state". It was intermittent because the latency was a race against
# where both processes happened to sit in their cycles.
#
# Each scenario drives the daemon into one parked state through real production
# paths and documented env knobs, then asserts the operator-visible contract:
# stop succeeds, the daemon is gone, and away mode is actually cleared. The
# captain-return route is covered by the same assertions, because
# bin/fm-afk-return.sh stops away mode through this exact stop path.
#
# The stop-path evidence contract is pinned too: shutdown must never SIGKILL
# the watcher out of the exit cleanup that persists its downtime recovery
# marker, while the detached kill backstop still bounds a watcher that never
# finishes.
#
# Isolation: a private tmux server (tmux -L), a tmux shim first on PATH so the
# daemon's bare `tmux` calls reach it, a throwaway state dir, and the test pane
# as the supervisor target. Nothing touches the live fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
REAL_TMUX=$(command -v tmux)
TMP=$(fm_test_tmproot fm-afk-shutdown)
SOCKET="fm-afk-shutdown-$$"
SHIM="$TMP/shim"
mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

DAEMON_PID=
HOLDER_PID=
STOPCASE_WATCHER_PID=
shutdown_cleanup() {
  [ -z "$DAEMON_PID" ] || kill -KILL "$DAEMON_PID" 2>/dev/null || true
  [ -z "$HOLDER_PID" ] || kill -KILL "$HOLDER_PID" 2>/dev/null || true
  if [ -n "$STOPCASE_WATCHER_PID" ]; then
    kill -CONT "$STOPCASE_WATCHER_PID" 2>/dev/null || true
    kill -KILL "$STOPCASE_WATCHER_PID" 2>/dev/null || true
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap shutdown_cleanup EXIT INT TERM

# The budget bin/fm-afk-launch.sh stop allows the daemon. Asserting against the
# operator contract itself keeps these cases tolerant of machine load: every
# scenario below overran it before the fix and finishes in well under a second
# after it, so nothing here depends on a tight timing margin.
STOP_BUDGET_SECS=10

# True when the watcher pid is gone or an unreaped orphan zombie: the daemon
# exits before a slow-exiting watcher, so nothing is left to reap it and
# kill -0 alone keeps succeeding on a process that is done.
watcher_finished() {  # <pid>
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 0
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 0 ;;
  esac
  return 1
}

make_case() {  # <name> -> echoes the case dir with state/ and a supervisor pane
  local name=$1 dir
  dir="$TMP/$name"
  mkdir -p "$dir/state"
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$name" -x 200 -y 50
  "$REAL_TMUX" -L "$SOCKET" display-message -p -t "$name" '#{pane_id}' > "$dir/pane"
  date '+%s' > "$dir/state/.afk"
  # The daemon runs as a harness-native background job here, which is the
  # `start-native` lifecycle record: no terminal of its own to close.
  printf 'none\t-\tnative\n' > "$dir/state/.afk-daemon-terminal"
  printf '%s' "$dir"
}

start_daemon() {  # <dir> [extra env assignments...]
  local dir=$1
  shift
  PATH="$SHIM:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_SUPERVISOR_TARGET="$(cat "$dir/pane")" FM_SUPERVISOR_BACKEND=tmux \
    env FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$@" "$DAEMON" &
  DAEMON_PID=$!
  # The daemon records its own lock; stop resolves the pid from it.
  local waited=0
  while [ ! -s "$dir/state/.supervise-daemon.lock/pid" ]; do
    kill -0 "$DAEMON_PID" 2>/dev/null || fail "the away-mode daemon exited during startup"
    [ "$waited" -lt 200 ] || fail "the away-mode daemon never took its lock"
    sleep 0.05
    waited=$((waited + 1))
  done
}

# Wait until the daemon's own log proves it reached <marker>, so each scenario
# signals a daemon that is actually parked where the scenario intends.
await_log() {  # <dir> <grep-pattern> <what>
  local dir=$1 pattern=$2 what=$3 waited=0
  while ! grep -q "$pattern" "$dir/state/.supervise-daemon.log" 2>/dev/null; do
    [ "$waited" -lt 300 ] || fail "the daemon never reached $what"
    sleep 0.1
    waited=$((waited + 1))
  done
}

# The watcher touches its liveness beacon at the top of every cycle and reaches
# its terminal wait shortly after, so this parks each scenario's signal inside
# that wait rather than racing the watcher's startup.
await_watcher_cycle() {  # <dir>
  local dir=$1 waited=0
  while [ ! -e "$dir/state/.last-watcher-beat" ]; do
    [ "$waited" -lt 300 ] || fail "the watcher never started a supervision cycle"
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 2
}

run_stop() {  # <dir> -> echoes "<rc> <elapsed-seconds>", stop output in <dir>/stop.out
  local dir=$1 start rc
  start=$SECONDS
  PATH="$SHIM:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$LAUNCH" stop > "$dir/stop.out" 2>&1
  rc=$?
  printf '%s %s' "$rc" "$((SECONDS - start))"
}

assert_stopped_cleanly() {  # <dir> <label>
  local dir=$1 label=$2 rc elapsed
  read -r rc elapsed <<<"$(run_stop "$dir")"
  [ "$rc" -eq 0 ] \
    || fail "$label: stop failed (rc=$rc after ${elapsed}s): $(cat "$dir/stop.out")"
  [ "$elapsed" -lt "$STOP_BUDGET_SECS" ] \
    || fail "$label: stop took ${elapsed}s, at or past its ${STOP_BUDGET_SECS}s budget"
  kill -0 "$DAEMON_PID" 2>/dev/null \
    && fail "$label: the daemon survived a successful stop"
  assert_absent "$dir/state/.afk" "$label: away mode was not cleared"
  assert_absent "$dir/state/.afk-daemon-terminal" "$label: the lifecycle record was not cleared"
  assert_absent "$dir/state/.supervise-daemon.pid" "$label: the daemon pidfile was left behind"
  assert_grep 'daemon shutting down' "$dir/state/.supervise-daemon.log" \
    "$label: the daemon did not run its shutdown cleanup"
  DAEMON_PID=
}

# --- Scenario A: the watcher is parked in its long signal-grace wait ---------
# A changed crew status makes the watcher linger a grace period before
# classifying. Shutdown reaps that child, so before the fix the daemon could not
# exit until the grace elapsed - the reported failure.
dir=$(make_case grace)
printf 'working: building\n' > "$dir/state/task-g1.status"
start_daemon "$dir" FM_POLL=15 FM_SIGNAL_GRACE=25
await_log "$dir" 'daemon starting' "startup"
await_watcher_cycle "$dir"
assert_stopped_cleanly "$dir" "watcher in its signal-grace wait"
pass "stop is deterministic while the watcher child is parked in a long signal-grace wait"

# --- Scenario B: the daemon is parked in its crash-restart backoff -----------
# A singleton lock held by a live process with a stale heartbeat makes every
# watcher launch refuse and exit non-zero, so the daemon sits in its restart
# backoff - the "mid-restart-loop" state of the reported recurrence.
dir=$(make_case backoff)
# Detached from this shell's job table so killing it later prints no job notice.
( sleep 900 & printf '%s' "$!" > "$dir/holder.pid" )
HOLDER_PID=$(cat "$dir/holder.pid")
mkdir -p "$dir/state/.watch.lock"
printf '%s' "$HOLDER_PID" > "$dir/state/.watch.lock/pid"
fm_test_pid_identity "$HOLDER_PID" > "$dir/state/.watch.lock/pid-identity"
touch -t "$(date -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || date -v-1H '+%Y%m%d%H%M')" \
  "$dir/state/.last-watcher-beat"
start_daemon "$dir" FM_POLL=15 FM_WATCHER_STALE_GRACE=1 FM_CRASH_NORMAL_SLEEP=25
await_log "$dir" 'restarting after 25s' "its restart backoff"
assert_stopped_cleanly "$dir" "daemon in its restart backoff"
kill -KILL "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=
pass "stop is deterministic while the daemon is parked mid-restart-loop in its crash backoff"

# --- Scenario C: the ordinary path still works end to end -------------------
# Signal-responsive waits replaced the loop's plain sleeps, so this also proves
# the loop still reaps its watcher and classifies the wake reason it exited with
# before asserting the clean stop.
dir=$(make_case ordinary)
printf 'done: PR https://example.test/pr/1 checks green\n' > "$dir/state/task-o1.status"
start_daemon "$dir" FM_POLL=2 FM_SIGNAL_GRACE=1
await_log "$dir" 'wake: signal: ' "a wake from the crew status"
assert_stopped_cleanly "$dir" "ordinary running fleet"
pass "the loop still reaps its watcher and routes a wake, then stops deterministically"

read -r rc _ <<<"$(run_stop "$dir")"
[ "$rc" -eq 0 ] || fail "a second stop attempt failed (rc=$rc): $(cat "$dir/stop.out")"
assert_absent "$dir/state/.afk" "a second stop attempt re-created the away-mode flag"
pass "a second stop attempt after a completed stop is safe and idempotent"

# --- Scenario D: shutdown never discards undeliverable escalation state ------
# The supervisor pane here is a bare shell, which the composer classifier refuses
# as an injection target, so the shutdown flush cannot deliver. The buffered
# escalation must survive for the return catch-up rather than be dropped.
dir=$(make_case buffer)
printf 'needs-decision: pick A or B\n' > "$dir/state/.subsuper-escalations"
date '+%s' > "$dir/state/.subsuper-escalations.since"
start_daemon "$dir" FM_POLL=15 FM_ESCALATE_BATCH_SECS=0
await_log "$dir" 'daemon starting' "startup"
sleep 2
assert_stopped_cleanly "$dir" "with an undeliverable buffered escalation"
assert_grep 'needs-decision: pick A or B' "$dir/state/.subsuper-escalations" \
  "shutdown discarded a buffered escalation it could not deliver"
pass "an undeliverable buffered escalation survives shutdown for the return catch-up"

# --- Scenario E: shutdown never SIGKILLs the watcher out of its exit cleanup --
# A watcher frozen mid-cycle (SIGSTOP) holds SIGTERM pending until it resumes,
# the same deferral a foreground sleep or backend call produces. The daemon's
# stop must stay inside its budget WITHOUT killing the child: the downtime
# recovery marker is written by the watcher's own exit cleanup, so a premature
# SIGKILL destroys durable recovery evidence. The detached kill backstop waits
# out the durable-safe grace instead, and the resumed watcher persists the
# marker and exits on its own.
dir=$(make_case stopped-watcher-marker)
start_daemon "$dir" FM_POLL=15 FM_SIGNAL_GRACE=25
await_log "$dir" 'daemon starting' "startup"
await_watcher_cycle "$dir"
STOPCASE_WATCHER_PID=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
kill -STOP "$STOPCASE_WATCHER_PID" 2>/dev/null || fail "could not freeze the daemon's watcher"
assert_stopped_cleanly "$dir" "watcher frozen mid-cycle"
kill -CONT "$STOPCASE_WATCHER_PID" 2>/dev/null || true
i=0
while [ "$i" -lt 300 ]; do
  case "$(cat "$dir/state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$(cat "$dir/state/.watcher-down" 2>/dev/null || true)" in
  pending:downtime:*) ;;
  *) fail "shutdown destroyed the watcher's durable downtime recovery evidence" ;;
esac
watcher_finished "$STOPCASE_WATCHER_PID" \
  || fail "the resumed watcher never exited after persisting its downtime marker"
STOPCASE_WATCHER_PID=
pass "shutdown spares a slow-exiting watcher's downtime recovery evidence"

# --- Scenario F: the detached kill backstop still bounds a wedged watcher -----
# A watcher that stays frozen past the durable-safe grace must still be killed:
# the backstop moved out of the daemon's synchronous path, it did not
# disappear. FM_WATCHER_STOP_GRACE_SECS shortens the grace so the case runs in
# seconds; the daemon's own stop stays inside its budget throughout.
dir=$(make_case stopped-watcher-backstop)
start_daemon "$dir" FM_POLL=15 FM_SIGNAL_GRACE=25 FM_WATCHER_STOP_GRACE_SECS=2
await_log "$dir" 'daemon starting' "startup"
await_watcher_cycle "$dir"
STOPCASE_WATCHER_PID=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
kill -STOP "$STOPCASE_WATCHER_PID" 2>/dev/null || fail "could not freeze the daemon's watcher"
assert_stopped_cleanly "$dir" "watcher frozen past its grace"
i=0
while [ "$i" -lt 80 ] && ! watcher_finished "$STOPCASE_WATCHER_PID"; do
  sleep 0.1
  i=$((i + 1))
done
watcher_finished "$STOPCASE_WATCHER_PID" \
  || fail "the detached kill backstop never bounded the wedged watcher"
STOPCASE_WATCHER_PID=
pass "the detached kill backstop still bounds a watcher frozen past its grace"
