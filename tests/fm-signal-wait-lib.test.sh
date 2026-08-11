#!/usr/bin/env bash
# tests/fm-signal-wait-lib.test.sh - the signal-responsive waiting primitives
# (bin/fm-signal-wait-lib.sh) that bound away-mode shutdown.
#
# These pin the one property the library exists for: a trapped signal is handled
# WHEN IT ARRIVES, not when the current wait would have ended. A plain foreground
# `sleep` cannot do that - bash defers the trap until the sleep returns - and the
# away-mode daemon parked in exactly such sleeps is what made
# bin/fm-afk-launch.sh stop report that the daemon did not exit after SIGTERM.
#
# Every case runs real processes and real signals, because the deferral being
# asserted is a property of bash's signal handling, not of any function's return
# value. Latency assertions are one-sided and generous (a wait that should be
# interrupted at once is allowed a second; the uninterrupted control is a
# multiple of that), so a loaded machine cannot make them flap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-signal-wait-lib.sh"
TMP=$(fm_test_tmproot fm-signal-wait)

# Run <body> in a child bash that traps TERM, signal it once it is parked, and
# echo the whole-second latency between the signal and the child's exit.
#
# The subject records HOW it ended, and this refuses to measure a subject that
# was not still parked when the signal landed. Without both guards a body that
# never reaches its wait at all - a missing primitive, a typo - would exit
# instantly and read as a perfect zero-latency interrupt, turning every case
# below into a vacuous pass.
term_latency() {  # <body> -> echoes "<how-it-ended> <elapsed-seconds>"
  local body=$1 script parked verdict pid start
  script="$TMP/subject.sh"
  parked="$TMP/parked"
  verdict="$TMP/verdict"
  rm -f "$parked" "$verdict"
  cat > "$script" <<SUBJECT
set -u
. "$LIB"
trap 'printf trapped > "$verdict"; exit 0' TERM
: > "$parked"
$body
printf 'ran-to-completion' > "$verdict"
SUBJECT
  bash "$script" &
  pid=$!
  while [ ! -e "$parked" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      printf 'never-parked 0'
      return 0
    fi
    sleep 0.05
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    printf 'exited-before-signal 0'
    return 0
  fi
  start=$SECONDS
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf '%s %s' "$(cat "$verdict" 2>/dev/null || printf 'no-verdict')" "$((SECONDS - start))"
}

# --- the control: a plain foreground sleep defers the trap ------------------
# This is the pre-fix behavior, asserted so the library's value cannot silently
# become a no-op if a future bash changed this. If this case ever stops
# deferring, the interrupted-at-once assertions below prove nothing on their own.
read -r verdict elapsed <<<"$(term_latency 'sleep 20')"
[ "$verdict" = trapped ] \
  || fail "the control subject ended as '$verdict' instead of through its TERM trap"
[ "$elapsed" -ge 5 ] \
  || fail "a plain foreground sleep answered SIGTERM in ${elapsed}s; the deferral this library works around is gone, so these tests no longer prove anything"
pass "control: a plain foreground sleep defers a trapped SIGTERM until it ends"

# --- fm_signal_sleep is interrupted at once ---------------------------------
read -r verdict elapsed <<<"$(term_latency 'fm_signal_sleep 20')"
[ "$verdict" = trapped ] \
  || fail "fm_signal_sleep's subject ended as '$verdict' instead of through its TERM trap"
[ "$elapsed" -le 1 ] \
  || fail "fm_signal_sleep held a trapped SIGTERM for ${elapsed}s; it must be interruptible"
pass "fm_signal_sleep: a trapped SIGTERM is handled immediately, not when the sleep ends"

# --- fm_signal_wait is interrupted at once ----------------------------------
read -r verdict elapsed <<<"$(term_latency 'sleep 20 & fm_signal_wait $!')"
[ "$verdict" = trapped ] \
  || fail "fm_signal_wait's subject ended as '$verdict' instead of through its TERM trap"
[ "$elapsed" -le 1 ] \
  || fail "fm_signal_wait held a trapped SIGTERM for ${elapsed}s; it must be interruptible"
pass "fm_signal_wait: a trapped SIGTERM interrupts the wait on a background child"

# --- an uninterrupted wait still waits, and reports the child's status ------
(
  # shellcheck source=bin/fm-signal-wait-lib.sh
  . "$LIB"
  start=$SECONDS
  fm_signal_sleep 1
  [ $((SECONDS - start)) -ge 1 ] || exit 1
  sleep 0.1 &
  child=$!
  fm_signal_wait "$child" || exit 1
  ( exit 7 ) &
  child=$!
  fm_signal_wait "$child" && exit 1
  exit 0
) || fail "an uninterrupted fm_signal_sleep/fm_signal_wait must still wait and return the child's status"
pass "fm_signal_sleep/fm_signal_wait: an uninterrupted wait keeps its duration and its exit status"

# --- fm_signal_wait_reap leaves no sleep child behind -----------------------
# The shutdown handler's job: the interrupted wait never reaped its child, so the
# handler must. Assert on the child itself, not on a return value.
CHILD_FILE="$TMP/reap-child"
cat > "$TMP/reap.sh" <<SUBJECT
set -u
. "$LIB"
reap() { fm_signal_wait_reap; exit 0; }
trap reap TERM
sleep 300 &
child=\$!
printf '%s' "\$child" > "$CHILD_FILE"
fm_signal_wait "\$child"
SUBJECT
bash "$TMP/reap.sh" &
REAP_PID=$!
while [ ! -s "$CHILD_FILE" ]; do
  kill -0 "$REAP_PID" 2>/dev/null || fail "reap subject exited before parking"
  sleep 0.05
done
REAP_CHILD=$(cat "$CHILD_FILE")
# The marker is written one statement before the wait begins; settle so the
# signal lands inside that wait rather than in the gap before it.
sleep 0.2
kill -TERM "$REAP_PID" 2>/dev/null || true
wait "$REAP_PID" 2>/dev/null || true
if kill -0 "$REAP_CHILD" 2>/dev/null; then
  kill -KILL "$REAP_CHILD" 2>/dev/null || true
  fail "fm_signal_wait_reap left the interrupted wait's child running (pid $REAP_CHILD)"
fi
pass "fm_signal_wait_reap: the child an interrupted wait left running is terminated and reaped"

# --- fm_signal_stop_child: SIGTERM is enough -------------------------------
sleep 300 &
STOPPABLE=$!
# shellcheck source=bin/fm-signal-wait-lib.sh
. "$LIB"
START=$SECONDS
fm_signal_stop_child "$STOPPABLE" 5 || fail "a TERM-responsive child was reported as needing the kill backstop"
[ $((SECONDS - START)) -le 2 ] || fail "stopping a TERM-responsive child took $((SECONDS - START))s"
kill -0 "$STOPPABLE" 2>/dev/null && fail "fm_signal_stop_child left a TERM-responsive child running"
pass "fm_signal_stop_child: a child that honors SIGTERM is stopped and reaped without the kill backstop"

# --- fm_signal_stop_child: a TERM-deaf child cannot hold shutdown open ------
# The bound that keeps daemon shutdown deterministic when the CHILD is the slow
# party: this child ignores SIGTERM entirely.
DEAF_INNER="$TMP/deaf-inner"
cat > "$TMP/deaf.sh" <<SUBJECT
trap '' TERM
sleep 300 &
printf '%s' "\$!" > "$DEAF_INNER"
wait
SUBJECT
bash "$TMP/deaf.sh" &
DEAF=$!
while [ ! -s "$DEAF_INNER" ]; do
  kill -0 "$DEAF" 2>/dev/null || fail "the TERM-deaf subject exited before it could be stopped"
  sleep 0.05
done
START=$SECONDS
fm_signal_stop_child "$DEAF" 1 && fail "a TERM-deaf child was reported as having exited on SIGTERM"
ELAPSED=$((SECONDS - START))
[ "$ELAPSED" -le 3 ] || fail "a TERM-deaf child held fm_signal_stop_child for ${ELAPSED}s past its 1s grace"
kill -0 "$DEAF" 2>/dev/null && fail "fm_signal_stop_child left a TERM-deaf child running"
# The kill backstop cannot reach a grandchild, so this test cleans up the one it
# deliberately created rather than leaving a 300s sleep behind.
kill -KILL "$(cat "$DEAF_INNER")" 2>/dev/null || true
pass "fm_signal_stop_child: a TERM-deaf child is killed within its grace and reported as the kill backstop"
