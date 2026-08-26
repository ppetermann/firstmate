#!/usr/bin/env bash
# fm-dispatch-facts.sh - one stamped line of dispatch facts (fork-only).
#
# Prints ONE line of measured facts for a dispatch-intake note: the local and
# Beijing clocks, the Z.AI peak-window verdict, zai's worst reserve window,
# claude's five-hour window, per-scope spendPriority, and quota freshness.
# Pure producer: no route recommendation (quota-array-dispatch owns the
# choice); the dated stamp exists so a stale quota snapshot can never be
# pasted into a dispatch note as if it were current.
#
# Peak-window config: optional config/zai-peak-window, one line
#   HH:MM-HH:MM <Days>       e.g. `14:00-18:00 Mon-Fri`
# interpreted in Asia/Shanghai; an absent file means exactly `14:00-18:00
# Mon-Fri`. The window is a config value because the policy source is
# data/captain.md: when the captain changes the rule, the config file
# changes, no code edit. A malformed file is an error naming the file
# (exit 2), never a silent fallback to the default.
#
# Dependencies: jq and quota-axi at the fm-quota-axi-lib.sh floor; either
# missing or incompatible exits 1 with a one-line error so the intake falls
# back to the manual procedure (fail closed, never guess).
#
# Output, one line (spend lists every effectiveAvailability scope per
# provider in array order, all_models printed as `all`; a provider or field
# without data prints unavailable or unknown):
#   dispatch-facts at=<local ISO8601> beijing=<HH:MM>-<Day> peak=<yes|no>
#     zai_worst=<windowid>:<pct>%:reserve=<pp>pp claude_5h=<pct>%
#     spend=claude/all:<sp>,...,zai/all:<sp> quota_age=<secs>s[ quota_stale=yes]
#
# FM_DISPATCH_FACTS_NOW=<epoch-seconds> overrides the clock (tests only).
# Usage: fm-dispatch-facts.sh (no arguments; --help prints this contract)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  sed -n '2,31{s/^# \{0,1\}//;p;}' "$0"
}

malformed_window() {
  echo "fm-dispatch-facts.sh: malformed $window_file (expected one line: HH:MM-HH:MM <Days>, e.g. 14:00-18:00 Mon-Fri)" >&2
  exit 2
}

# Portable epoch-seconds -> formatted string (BSD date -r, GNU date -d @).
fmt_epoch() {  # <epoch> <date-format>
  local epoch=$1 fmt=$2 out
  if out=$(LC_ALL=C date -r "$epoch" "$fmt" 2>/dev/null); then
    printf '%s\n' "$out"
  else
    LC_ALL=C date -d "@$epoch" "$fmt"
  fi
}

day_num() {  # <Mon..Sun> -> 1..7
  case $1 in
    Mon) echo 1 ;; Tue) echo 2 ;; Wed) echo 3 ;; Thu) echo 4 ;;
    Fri) echo 5 ;; Sat) echo 6 ;; Sun) echo 7 ;; *) return 1 ;;
  esac
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ $# -ne 0 ]; then
  echo "fm-dispatch-facts.sh: no arguments expected ( --help for the contract )" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "fm-dispatch-facts.sh: jq is required for the dispatch stamp; use the manual dispatch procedure" >&2
  exit 1
}
fm_quota_axi_compatible || {
  echo "fm-dispatch-facts.sh: quota-axi is missing or below the ${FM_QUOTA_AXI_MIN} floor; use the manual dispatch procedure" >&2
  exit 1
}
JSON=$(quota-axi --json 2>/dev/null) || {
  echo "fm-dispatch-facts.sh: quota-axi --json failed; use the manual dispatch procedure" >&2
  exit 1
}
printf '%s' "$JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || {
  echo "fm-dispatch-facts.sh: quota-axi --json did not return a JSON object; use the manual dispatch procedure" >&2
  exit 1
}

now=${FM_DISPATCH_FACTS_NOW:-$(date +%s)}
case $now in
  ''|*[!0-9]*)
    echo "fm-dispatch-facts.sh: FM_DISPATCH_FACTS_NOW must be epoch seconds" >&2
    exit 2
    ;;
esac

# Peak window: config file when present, otherwise the encoded default.
window_file="$CONFIG/zai-peak-window"
spec='14:00-18:00 Mon-Fri'
if [ -f "$window_file" ]; then
  spec=$(sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' -e '/^$/d' "$window_file")
  [ "$(printf '%s\n' "$spec" | sed -n '/./p' | wc -l | tr -d ' ')" = "1" ] || malformed_window
fi
if [[ $spec =~ ^([0-9]{2}):([0-9]{2})-([0-9]{2}):([0-9]{2})\ (.+)$ ]]; then
  wh1=${BASH_REMATCH[1]} wm1=${BASH_REMATCH[2]} wh2=${BASH_REMATCH[3]} wm2=${BASH_REMATCH[4]}
  days_spec=${BASH_REMATCH[5]}
else
  malformed_window
fi
[ $((10#$wh1)) -lt 24 ] && [ $((10#$wm1)) -lt 60 ] || malformed_window
[ $((10#$wh2)) -lt 24 ] && [ $((10#$wm2)) -lt 60 ] || malformed_window
w_start=$((10#$wh1 * 100 + 10#$wm1))
w_end=$((10#$wh2 * 100 + 10#$wm2))
[ "$w_start" -lt "$w_end" ] || malformed_window

days_set=" "
tok_list=${days_spec//,/ }
for tok in $tok_list; do
  if [[ $tok =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)-(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]; then
    a=$(day_num "${BASH_REMATCH[1]}") || malformed_window
    b=$(day_num "${BASH_REMATCH[2]}") || malformed_window
    i=$a
    guard=0
    while :; do
      days_set="$days_set$i "
      guard=$((guard + 1))
      [ "$guard" -gt 8 ] && malformed_window
      [ "$i" = "$b" ] && break
      i=$(( i % 7 + 1 ))
    done
  else
    a=$(day_num "$tok") || malformed_window
    days_set="$days_set$a "
  fi
done
[ -n "${days_set// /}" ] || malformed_window

at=$(fmt_epoch "$now" +%Y-%m-%dT%H:%M:%S%z)
b_hm=$(TZ=Asia/Shanghai fmt_epoch "$now" +%H:%M)
b_day=$(TZ=Asia/Shanghai fmt_epoch "$now" +%a)
b_num=$(TZ=Asia/Shanghai fmt_epoch "$now" +%u)
b_hhmm=$((10#$(TZ=Asia/Shanghai fmt_epoch "$now" +%H%M)))
case $days_set in
  *" $b_num "*) in_set=1 ;;
  *) in_set=0 ;;
esac
if [ "$in_set" = 1 ] && [ "$b_hhmm" -ge "$w_start" ] && [ "$b_hhmm" -lt "$w_end" ]; then
  peak=yes
else
  peak=no
fi

zai_entry=$(printf '%s' "$JSON" | jq -c \
  '[.providers[] | select(.provider == "zai") | .quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")] | first // empty')
zai_worst=unavailable
if [ -n "$zai_entry" ]; then
  z_wr=$(printf '%s' "$zai_entry" | jq -r '.pace.worstReserveWindowId // empty')
  z_eff=$(printf '%s' "$zai_entry" | jq -r '.effectivePercentRemaining // empty')
  z_pp=$(printf '%s' "$zai_entry" | jq -r '.pace.worstReservePercentPoints // empty')
  if [ -n "$z_wr" ] && [ -n "$z_eff" ] && [ -n "$z_pp" ]; then
    zai_worst="$z_wr:${z_eff}%:reserve=${z_pp}pp"
  fi
fi

c5=$(printf '%s' "$JSON" | jq -r \
  'first(.providers[] | select(.provider == "claude") | .windows[]? | select(.id == "five_hour") | .percentRemaining | tostring) // empty')
if [ -n "$c5" ]; then
  claude_5h="${c5}%"
else
  claude_5h=unavailable
fi

spend=$(printf '%s' "$JSON" | jq -r '
  [ (["claude","zai"][]) as $p
    | ([ (first(.providers[] | select(.provider == $p)) // null) as $prov
        | select($prov != null)
        | $prov.quotaSemantics.effectiveAvailability[]?
        | "\($p)/\(if .scope == "all_models" then "all" else .scope end):\((.selection.spendPriority // "unknown") | tostring)" ]) as $es
    | if ($es|length) == 0 then "\($p)/all:unknown" else $es[] end ]
  | join(",")')

gen_epoch=$(printf '%s' "$JSON" | jq -r '
  .generatedAt as $g
  | if ($g | type) == "string"
    then ($g | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null)
    else null end')
stale_suffix=
case $gen_epoch in
  ''|null|*[!0-9-]*)
    quota_age=unknown
    ;;
  *)
    age=$((now - gen_epoch))
    quota_age="${age}s"
    [ "$age" -gt 600 ] && stale_suffix=" quota_stale=yes"
    ;;
esac

printf 'dispatch-facts at=%s beijing=%s-%s peak=%s zai_worst=%s claude_5h=%s spend=%s quota_age=%s%s\n' \
  "$at" "$b_hm" "$b_day" "$peak" "$zai_worst" "$claude_5h" "$spend" "$quota_age" "$stale_suffix"
