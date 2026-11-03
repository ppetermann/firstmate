#!/usr/bin/env bash
# maia notification follow process-event adapter (this fleet's own built-in).
#
# Usage:
#   fm-procevent-maia-notify.sh arm [--interval <secs>]
#   fm-procevent-maia-notify.sh poll --interval <secs>
#   fm-procevent-maia-notify.sh relisten
#   fm-procevent-maia-notify.sh silent <result-file>
#   fm-procevent-maia-notify.sh terminal <result-file>
#   fm-procevent-maia-notify.sh source-id
#   fm-procevent-maia-notify.sh retire
#
# arm        Register the recurring `bin/fm-maia-notify.sh follow` run as the
#            source `maia-notify` through `bin/fm-procevent.sh register`. Needs
#            config/maia-notify. The interval defaults to 15 seconds, the
#            watcher's default poll cycle. Re-arming with the same interval is
#            adopted by a live runner, so arm is idempotent; the registration
#            persists, so one arm after opting in is enough.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. With config/maia-notify present it runs one
#            `fm-maia-notify.sh follow` (its own locks make an overlap safe and
#            its transport and forge reads are bounded), sleeps <secs>, and
#            exits 75 with no output so the runner polls again in the same
#            process (`relisten`). With config/maia-notify absent it prints
#            nothing and exits 0, which `terminal` ends.
# relisten   Always 0: keep polling in the same runner.
# silent     0 for an empty result. This source never prints while opted in,
#            so it never wakes anyone.
# terminal   0 only once config/maia-notify is absent, so an opt-out retires
#            the registration by itself.
# source-id  Print `maia-notify`.
# retire     Retire the `maia-notify` registration.
#
# bin/fm-maia-notify.sh owns what is sent, the merge-ready scan's own 300 s
# throttle, the spool, and its retry cadence; this adapter only schedules
# follow.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

SOURCE_ID=maia-notify

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

opted_in() { [ -e "$CONFIG/maia-notify" ]; }

interval_arg() {  # <args...> -> prints the validated interval
  local interval=15
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*|0) die "--interval needs a positive whole number of seconds" ;; esac
  printf '%s\n' "$((10#$interval))"
}

cmd_arm() {
  local interval
  interval=$(interval_arg "$@") || exit 1
  opted_in || die "config/maia-notify is absent; maia notifications are not opted in"
  "$SCRIPT_DIR/fm-procevent.sh" register maia-notify "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-maia-notify.sh" poll --interval "$interval"
}

cmd_poll() {
  local interval
  interval=$(interval_arg "$@") || exit 1
  opted_in || exit 0
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-maia-notify.sh" follow </dev/null >/dev/null 2>&1 || :
  sleep "$interval"
  exit 75
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  relisten) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  silent) shift; [ "$#" -eq 1 ] || usage; [ ! -s "$1" ] ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; ! opted_in ;;
  source-id) shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID" ;;
  retire) shift; [ "$#" -eq 0 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  *) usage ;;
esac
