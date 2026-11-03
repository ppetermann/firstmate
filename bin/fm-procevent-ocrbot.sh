#!/usr/bin/env bash
# OCR review bot poll process-event adapter (this fleet's own built-in).
#
# Usage:
#   fm-procevent-ocrbot.sh arm [--interval <secs>]
#   fm-procevent-ocrbot.sh poll --interval <secs>
#   fm-procevent-ocrbot.sh relisten
#   fm-procevent-ocrbot.sh silent <result-file>
#   fm-procevent-ocrbot.sh terminal <result-file>
#   fm-procevent-ocrbot.sh self-announcing
#   fm-procevent-ocrbot.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-ocrbot.sh classify <result-file>
#   fm-procevent-ocrbot.sh source-id
#   fm-procevent-ocrbot.sh retire
#
# arm        Register the recurring bin/fm-ocrbot-poll.sh run as the source
#            `ocrbot-poll` through `bin/fm-procevent.sh register`. Needs gh and
#            jq on PATH and a config/ocr-bot directory. The interval defaults to
#            FM_OCRBOT_CHECK_INTERVAL, else 60 seconds. Re-arming with the same
#            interval is adopted by a live runner, so arm is idempotent.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. One poll per invocation: it first waits until
#            <secs> have passed since state/.last-ocrbot-check, stamps it, and
#            runs bin/fm-ocrbot-poll.sh under a 30-second bound
#            (FM_OCRBOT_POLL_TIMEOUT). Output is
#            printed and exits 0; no output exits 75 so the runner polls again
#            in the same process (`relisten`). With config/ocr-bot absent or a
#            symlink it prints nothing and exits 0, which `terminal` ends.
# relisten   Always 0: keep polling in the same runner.
# silent     0 for an empty result: nothing to announce.
# terminal   0 only once config/ocr-bot is absent or a symlink, so an opt-out
#            retires the registration by itself.
# self-announcing
#            Always 1: the runner's own `procevent` row is what rings the
#            session, because the watcher surfaces only `procevent:*` keys.
# autohandle Queue one `check` wake per result line, keyed per PR by
#            ocrbot_wake_key under the label ocrbot_wake_label names, with the
#            payload `check: <label>: <line>`, then acknowledge the capture
#            with `bin/fm-procevent.sh handled`. These rows are byte-identical
#            to the ones bin/fm-pr-flip.sh queues, so a flip and a poll for one
#            PR head collapse in the drain.
# classify   Print ocr-pr, ocrbot-error, or unknown for the first result line.
# source-id  Print `ocrbot-poll`.
# retire     Retire the `ocrbot-poll` registration.
#
# bin/fm-ocrbot-poll.sh owns the seen-state, ETag, error-dedupe, and GitHub
# request budget; this adapter only schedules it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-ocrbot-lib.sh
. "$SCRIPT_DIR/fm-ocrbot-lib.sh"

SOURCE_ID=ocrbot-poll
POLL_TIMEOUT=${FM_OCRBOT_POLL_TIMEOUT:-30}
case "$POLL_TIMEOUT" in ''|*[!0-9]*|0) POLL_TIMEOUT=30 ;; esac

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

opted_in() { [ -d "$CONFIG/ocr-bot" ] && [ ! -L "$CONFIG/ocr-bot" ]; }

interval_arg() {  # <args...> -> prints the validated interval
  local interval=${FM_OCRBOT_CHECK_INTERVAL:-60}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*|0) die "--interval needs a positive whole number of seconds" ;; esac
  printf '%s\n' "$((10#$interval))"
}

stamp_age() {  # <file> - seconds since its mtime; a large number when absent
  local m
  [ -e "$1" ] || { printf '999999999\n'; return 0; }
  if [ "$(uname)" = Darwin ]; then m=$(stat -f %m "$1"); else m=$(stat -c %Y "$1"); fi
  printf '%s\n' "$(( $(date +%s) - m ))"
}

cmd_arm() {
  local interval tool
  interval=$(interval_arg "$@") || exit 1
  opted_in || die "config/ocr-bot is absent; the OCR review bot is not opted in"
  for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required on PATH"
  done
  "$SCRIPT_DIR/fm-procevent.sh" register ocrbot "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-ocrbot.sh" poll --interval "$interval"
}

cmd_poll() {
  local interval age out
  interval=$(interval_arg "$@") || exit 1
  opted_in || exit 0
  mkdir -p "$STATE"
  age=$(stamp_age "$STATE/.last-ocrbot-check")
  [ "$age" -ge "$interval" ] || sleep "$((interval - age))"
  opted_in || exit 0
  touch "$STATE/.last-ocrbot-check"
  out=$(fm_run_timed "$POLL_TIMEOUT" "$SCRIPT_DIR/fm-ocrbot-poll.sh" </dev/null 2>/dev/null) || :
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
  fi
  # Nothing to announce, or a cut or failed run that printed nothing: the
  # next interval polls again.
  exit 75
}

cmd_autohandle() {
  local sid=${1:-} seq=${2:-} result=${3:-} label line
  [ "$sid" = "$SOURCE_ID" ] || die "not the OCR review bot source: $sid"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file is unavailable"
  label=$(ocrbot_wake_label "$STATE")
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    line=${line:0:4096}
    fm_wake_append check "$(ocrbot_wake_key "$label" "$line")" "check: $label: $line" || return 1
  done < "$result"
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null
}

cmd_classify() {
  local first
  first=$(sed -n '1{s/ .*//;p;}' "$1" 2>/dev/null)
  case "$first" in
    ocr-pr|ocrbot-error) printf '%s\n' "$first" ;;
    *) printf 'unknown\n' ;;
  esac
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  relisten) shift; [ "$#" -eq 0 ] || usage; exit 0 ;;
  silent) shift; [ "$#" -eq 1 ] || usage; [ ! -s "$1" ] ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; ! opted_in ;;
  self-announcing) shift; [ "$#" -eq 0 ] || usage; exit 1 ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; cmd_classify "$1" ;;
  source-id) shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID" ;;
  retire) shift; [ "$#" -eq 0 ] || usage; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  *) usage ;;
esac
