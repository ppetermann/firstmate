#!/usr/bin/env bash
# fm-signal-wait-lib.sh - the single owner of signal-responsive waiting.
#
# Sourced, never executed. Bash runs a trapped signal handler only after the
# current FOREGROUND command finishes, so a long-lived supervision loop parked in
# a plain `sleep 30` answers SIGTERM up to 30 seconds late even though its trap
# is installed and correct. The `wait` builtin is the documented exception: a
# trapped signal makes it return immediately and the handler runs at once. Every
# long wait on a supervision shutdown path therefore goes through this library
# instead of blocking in a foreground child, so shutdown latency is bounded by
# the handler rather than by whatever the loop happened to be waiting on.
#
#   fm_signal_sleep <seconds>
#       Sleep that a trapped signal can interrupt. Always returns 0.
#
#   fm_signal_wait <pid>
#       Wait for one background child the same way. Returns the child's exit
#       status; that status is meaningful only when the wait was not interrupted,
#       because an interrupting handler runs before the caller can read it.
#
#   fm_signal_wait_reap
#       Called from a shutdown handler: terminate and reap the child an
#       interrupted wait left running. A no-op when no wait is outstanding.
#
#   fm_signal_stop_child <pid> <grace-seconds>
#       Bounded child shutdown: SIGTERM, wait up to <grace-seconds>, then
#       SIGKILL, reaping either way. Returns 0 when SIGTERM was enough and 1 when
#       the kill backstop was needed, so the caller can log that escalation.
#       This is what keeps a shutdown bounded when the CHILD is the slow party.
set -u

# The child an outstanding fm_signal_sleep/fm_signal_wait is parked on, empty
# otherwise. An interrupted wait never reaps its child, so while this is set the
# pid still names that exact child and cannot have been reused.
FM_SIGNAL_WAIT_PID=""

fm_signal_wait() {  # <pid>
  local pid=$1 rc=0
  FM_SIGNAL_WAIT_PID=$pid
  wait "$pid" 2>/dev/null || rc=$?
  FM_SIGNAL_WAIT_PID=""
  return "$rc"
}

fm_signal_sleep() {  # <seconds>
  local pid
  sleep "$1" &
  pid=$!
  fm_signal_wait "$pid" || true
  return 0
}

fm_signal_wait_reap() {
  local pid=${FM_SIGNAL_WAIT_PID:-}
  [ -n "$pid" ] || return 0
  FM_SIGNAL_WAIT_PID=""
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Reaped wait status of the child the last fm_signal_stop_child call stopped.
# A caller that records the stopped child's outcome (a cycle ledger, a log line)
# reads this instead of a second wait, because the reap already happened here.
FM_SIGNAL_STOP_STATUS=

fm_signal_stop_child() {  # <pid> <grace-seconds>
  local pid=$1 grace=$2 ticks=0 limit
  FM_SIGNAL_STOP_STATUS=
  case "$grace" in
    ''|*[!0-9]*) grace=1 ;;
  esac
  [ "$grace" -gt 0 ] || grace=1
  limit=$((grace * 20))  # 50ms ticks
  if ! kill -0 "$pid" 2>/dev/null; then
    fm_signal_reap_status "$pid"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  # kill -0 still succeeds for a child that exited but has not been reaped yet.
  # Bash reaps its own background jobs on SIGCHLD, so that window closes well
  # inside one tick; at worst it costs one extra tick before the wait below.
  while [ "$ticks" -lt "$limit" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fm_signal_reap_status "$pid"
    return 1
  fi
  fm_signal_reap_status "$pid"
  return 0
}

# shellcheck disable=SC2034 # FM_SIGNAL_STOP_STATUS is read by the separately linted callers of fm_signal_stop_child.
fm_signal_reap_status() {  # <pid>
  if wait "$1" 2>/dev/null; then
    FM_SIGNAL_STOP_STATUS=0
  else
    FM_SIGNAL_STOP_STATUS=$?
  fi
}
