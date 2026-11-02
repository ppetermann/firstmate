#!/usr/bin/env bash
# tests/fm-watch-checkpoint-fleet.test.sh - this fleet's own bounded watcher
# checkpoint case: a registered check killed at its time limit notifies once
# per episode. It lives beside upstream's tests/fm-watch-checkpoint.test.sh so
# a take-in never re-resolves it inside that file.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint-fleet)

# The same home fixture upstream's suite defines.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_registered_check() {  # <home> <id> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/state/$2.check.sh"
  chmod 0700 "$1/state/$2.check.sh"
  FM_HOME="$1" "$ROOT/bin/fm-check-register.sh" "$2" >/dev/null \
    || fail "could not register custom check $2"
}

timeout_rows() {  # <home> - durable time-limit notifications queued so far
  awk -F '\t' '$3 == "check" && $4 == "check-timeout-slow.check.sh" { count++ } END { print count + 0 }' \
    "$1/state/.wake-queue"
}

test_timed_out_check_notifies_once_per_episode() {
  local home out err status
  home=$(make_home check-timeout)
  out="$home/out.txt"
  err="$home/err.txt"
  write_registered_check "$home" slow 'sleep 5'
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=1 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 6 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "timed-out check checkpoint exit"
  assert_contains "$(cat "$out")" "check: state checks timed out: $home/state/slow.check.sh" \
    "a check killed at its time limit was not surfaced"
  grep -F "$(printf '\tcheck-timeout-slow.check.sh\tcheck: %s/state/slow.check.sh: timed out after 1s with no output' "$home")" \
    "$home/state/.wake-queue" >/dev/null || fail "the time-limit notification was not queued durably"
  status=0
  FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=1 \
    FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 4 >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail "a repeat timeout in one episode surfaced a wake: $(cat "$out")"
  assert_not_contains "$(cat "$out")" "timed out" "a repeat timeout in one episode was surfaced again"
  [ "$(timeout_rows "$home")" = 1 ] || fail "one time-limit episode queued $(timeout_rows "$home") notifications"
  write_registered_check "$home" slow 'exit 0'
  status=0
  FM_HOME="$home" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=1 \
    FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 2 >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail "a check finishing inside its bound surfaced a wake: $(cat "$out")"
  assert_absent "$home/state/.check-timeout-slow" "a run inside the bound did not end the time-limit episode"
  pass "a check killed at its time limit notifies once per episode and a run inside the bound ends it"
}

test_timed_out_check_notifies_once_per_episode
