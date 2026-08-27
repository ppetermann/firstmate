#!/usr/bin/env bash
# Bookkeeping verbs for the /stow startup-memory pass.
# Usage:
#   fm-stow-plan.sh plan
#   fm-stow-plan.sh stamp <file> <line-no> <a|p> <YYYY-MM-DD> [passes]
#   fm-stow-plan.sh archive <file> <line-no> [reason]
#   fm-stow-plan.sh check-destination <path>
#   fm-stow-plan.sh receipt
#
# This script owns measurement, marker encodings, and date/token arithmetic.
# The internal stow skill keeps tier meaning, the evidence rule, and every
# curation judgement; nothing here reinforces, retiers, or evicts on its own.
# FM_STOW_PLAN_TODAY=YYYY-MM-DD overrides the clock (tests only).
#
# Marker encodings (single owner; trailing HTML comments on list lines):
#   <!--a:YYYY-MM-DD-->  aging entry; the date is its last-reinforced date
#   <!--p:YYYY-MM-DD-->  perishable entry; the date is its last-reinforced date
#   <!--a:...-->/N or <!--p:...-->/N  only in a home with the
#     config/stow-pass-horizon flag: N counts passes that evaluated the entry
#     without reinforcing it; an absent /N means zero; a home without the flag
#     never writes or reads a counter
#   <!--P-->  explicitly pinned in a file whose default tier is not pinned
#   <!--g-->  migration-only legacy grace marker; no date (grace is not
#     reinforcement)
#
# Clocks and arithmetic (single owner):
#   age-days is today minus the last-reinforced date in whole days
#   an aging entry is stale when age-days reaches 30
#   a perishable entry is stale when age-days reaches 7
#   with config/stow-pass-horizon: an aging entry is stale at 10 unreinforced
#     passes and a perishable one at 3, whichever horizon is reached first
#   estimated tokens are ceil(UTF-8 bytes / 3) per entry line, marker bytes
#     included, through fm-startup-memory-budget-lib.sh
#   the offload sweep's fat-enough floor is roughly 50 estimated tokens,
#     handled largest-first
#
# Verbs:
#   plan            one TSV row per marker-bearing or unmarked list line in
#                   each memory file (file, line-no, tier a|p|P|g|unmarked,
#                   reinforced date, age-days, passes, est-tokens, class
#                   fresh|stale|grace|pinned|unmarked), then per-file totals,
#                   the effective budget with headroom or must_shed, and the
#                   eviction pool: stale dated aging entries from editable
#                   files, oldest-reinforced-first, with cumulative est-tokens
#                   and a converges=yes|no verdict for whether shedding the
#                   whole pool reaches the budget. An unmarked row reports the
#                   marker state; the file's default tier stays a skill
#                   judgement. plan also records the receipt baseline snapshot.
#   stamp           idempotent trailing-marker rewrite on exactly one list
#                   line: replaces an existing trailing marker or appends one.
#                   Refuses a non-list line, a bad date or tier, a bad passes
#                   value, or any passes value without the pass-horizon flag;
#                   the line's other content never changes.
#   archive         atomic move (write-then-rename per file) of one list line
#                   to data/memory-archive.md under today's dated pass heading
#                   with the provenance line
#                   "- (from <file>, tier: <tier>, reinforced: <date>) <text>
#                   [archived: <reason>]". Derived reason when omitted:
#                   legacy-unvalidated for a g entry; unreinforced <N>p only
#                   when the pass horizon made a counter-carrying entry stale;
#                   unreinforced <age>d when the date clock made it stale;
#                   budget oldest-first otherwise.
#   check-destination  the ordered git safety battery for a prospective
#                   destination path under the home root ($FM_HOME when set,
#                   else the code root): inside a git work tree, under that
#                   root, absent from the index, absent from the filesystem,
#                   and ignored through the repository-local exclude file.
#                   Prints `safe` or the failing check name.
#   receipt         re-measure every memory file against the last plan
#                   snapshot and print per-file and total before/after
#                   estimated-token deltas; before reads `unavailable` when no
#                   plan snapshot exists.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="$FM_HOME/state"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

MEMORY_FILES="captain.md captain-shared.md learnings.md"

usage() {
  sed -n '2,72{s/^# \{0,1\}//;p;}' "$0"
}

fm_stow_plan_die() {  # <message>
  printf 'fm-stow-plan: %s\n' "$1" >&2
  exit 1
}

fm_stow_plan_refuse() {  # <message>; leaves files untouched
  printf 'fm-stow-plan: %s\n' "$1" >&2
  exit 2
}

# Gregorian day number (days_from_civil). Pure arithmetic so the clocks never
# depend on the host date(1) dialect.
fm_stow_plan_days_from_civil() {  # <yyyy> <mm> <dd>
  local y=$1 m=$2 d=$3 era yoe mp doy doe
  y=$((10#$y))
  m=$((10#$m))
  d=$((10#$d))
  if [ "$m" -le 2 ]; then
    y=$((y - 1))
  fi
  if [ "$y" -ge 0 ]; then
    era=$((y / 400))
  else
    era=$(((y - 399) / 400))
  fi
  yoe=$((y - era * 400))
  mp=$(((m + 9) % 12))
  doy=$(((153 * mp + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s\n' $((era * 146097 + doe - 719468))
}

fm_stow_plan_date_valid() {  # <YYYY-MM-DD>
  local d=$1 y m dd
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  y=${d%%-*}
  m=${d#*-}
  dd=${m#*-}
  m=${m%-*}
  [ "$((10#$m))" -ge 1 ] && [ "$((10#$m))" -le 12 ] || return 1
  [ "$((10#$dd))" -ge 1 ] && [ "$((10#$dd))" -le 31 ] || return 1
  return 0
}

fm_stow_plan_today() {
  if [ -n "${FM_STOW_PLAN_TODAY:-}" ]; then
    fm_stow_plan_date_valid "$FM_STOW_PLAN_TODAY" \
      || fm_stow_plan_die "FM_STOW_PLAN_TODAY must be YYYY-MM-DD"
    printf '%s\n' "$FM_STOW_PLAN_TODAY"
  else
    date +%Y-%m-%d
  fi
}

fm_stow_plan_today_days() {  # <today YYYY-MM-DD>
  fm_stow_plan_days_from_civil "${1:0:4}" "${1:5:2}" "${1:8:2}"
}

fm_stow_plan_pass_horizon_on() {
  [ -e "$CONFIG/stow-pass-horizon" ]
}

fm_stow_plan_role() {
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    printf '%s\n' secondmate
  else
    printf '%s\n' primary
  fi
}

fm_stow_plan_list_line() {  # <line>
  [[ $1 =~ ^[[:space:]]*[-*][[:space:]]+ ]]
}

# Sets ENTRY_TIER (a|p|P|g|unmarked), ENTRY_DATE (may be empty), ENTRY_PASSES
# (0 when absent), and ENTRY_BASE (the line without its trailing marker).
fm_stow_plan_parse_line() {  # <line>
  local line=$1 re
  ENTRY_TIER=unmarked
  ENTRY_DATE=
  ENTRY_PASSES=0
  ENTRY_BASE=$line
  re='^(.*)<!--([aPpg])(:([0-9]{4}-[0-9]{2}-[0-9]{2})(/([0-9]+))?)?-->[[:space:]]*$'
  if [[ $line =~ $re ]]; then
    ENTRY_BASE=${BASH_REMATCH[1]}
    ENTRY_TIER=${BASH_REMATCH[2]}
    ENTRY_DATE=${BASH_REMATCH[4]:-}
    ENTRY_PASSES=${BASH_REMATCH[6]:-0}
  fi
}

fm_stow_plan_date_age_days() {  # <reinforced-date> <today-days>; empty output when no date
  local date=$1 today_days=$2
  [ -n "$date" ] || return 0
  printf '%s\n' $((today_days - $(fm_stow_plan_days_from_civil "${date:0:4}" "${date:5:2}" "${date:8:2}")))
}

# Tier clock in days: aging 30, perishable 7.
fm_stow_plan_tier_clock_days() {  # <a|p>
  if [ "$1" = p ]; then printf '%s\n' 7; else printf '%s\n' 30; fi
}

# Tier clock in unreinforced passes (pass horizon only): aging 10, perishable 3.
fm_stow_plan_tier_clock_passes() {  # <a|p>
  if [ "$1" = p ]; then printf '%s\n' 3; else printf '%s\n' 10; fi
}

# Sets ENTRY_CLASS (fresh|stale|grace|pinned|unmarked) from ENTRY_* fields.
fm_stow_plan_entry_class() {  # <today-days>
  local today_days=$1 age clock
  case "$ENTRY_TIER" in
    P) ENTRY_CLASS=pinned ;;
    g) ENTRY_CLASS=grace ;;
    unmarked) ENTRY_CLASS=unmarked ;;
    a|p)
      ENTRY_CLASS=fresh
      age=$(fm_stow_plan_date_age_days "$ENTRY_DATE" "$today_days")
      if [ -n "$age" ]; then
        clock=$(fm_stow_plan_tier_clock_days "$ENTRY_TIER")
        if [ "$age" -ge "$clock" ]; then
          ENTRY_CLASS=stale
        fi
      fi
      if [ "$ENTRY_CLASS" != stale ] && fm_stow_plan_pass_horizon_on; then
        clock=$(fm_stow_plan_tier_clock_passes "$ENTRY_TIER")
        if [ "$ENTRY_PASSES" -ge "$clock" ]; then
          ENTRY_CLASS=stale
        fi
      fi
      ;;
  esac
}

fm_stow_plan_line_tokens() {  # <line>
  local bytes
  bytes=$(LC_ALL=C wc -c < <(printf '%s' "$1"))
  bytes=${bytes//[[:space:]]/}
  fm_startup_memory_estimated_tokens_for_bytes "$bytes"
}

fm_stow_plan_resolve_memory_file() {  # <file-arg>
  local arg=$1 name
  case "$arg" in
    */*)
      case "$arg" in
        "$DATA"/*) arg=${arg#"$DATA"/} ;;
        *) fm_stow_plan_refuse "unknown memory file: $1" ;;
      esac
      ;;
  esac
  for name in $MEMORY_FILES; do
    if [ "$arg" = "$name" ]; then
      printf '%s\n' "$DATA/$name"
      return 0
    fi
  done
  fm_stow_plan_refuse "unknown memory file: $1"
}

# Reads one memory file into the LINES array, one element per line.
fm_stow_plan_read_lines() {  # <path>
  local line
  LINES=()
  while IFS= read -r line || [ -n "$line" ]; do
    LINES+=("$line")
  done < "$1"
}

fm_stow_plan_write_lines_atomic() {  # <path> ; writes LINES, empty array writes an empty file
  local path=$1 tmp i
  tmp=$(mktemp "${path}.XXXXXX") || fm_stow_plan_die "could not create temporary file beside $path"
  : > "$tmp" || { rm -f "$tmp"; fm_stow_plan_die "could not write temporary file beside $path"; }
  for i in "${!LINES[@]}"; do
    printf '%s\n' "${LINES[$i]}" >> "$tmp" \
      || { rm -f "$tmp"; fm_stow_plan_die "could not write temporary file beside $path"; }
  done
  mv "$tmp" "$path" || { rm -f "$tmp"; fm_stow_plan_die "could not replace $path"; }
}

cmd_plan() {
  local budget today today_days role file path lineno line tokens
  local total=0 entries pool="" pool_total=0 sorted cum f l d t age
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    fm_stow_plan_die "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
  budget=$FM_STARTUP_MEMORY_BUDGET_VALUE
  today=$(fm_stow_plan_today)
  today_days=$(fm_stow_plan_today_days "$today")
  role=$(fm_stow_plan_role)
  if fm_stow_plan_pass_horizon_on; then
    printf 'plan today=%s horizon=on role=%s\n' "$today" "$role"
  else
    printf 'plan today=%s horizon=off role=%s\n' "$today" "$role"
  fi
  for file in $MEMORY_FILES; do
    path="$DATA/$file"
    fm_startup_memory_measure_file "$path" >/dev/null \
      || fm_stow_plan_die "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    total=$((total + FM_STARTUP_MEMORY_MEASURE_TOKENS))
    entries=0
    if [ "$FM_STARTUP_MEMORY_MEASURE_PRESENCE" = present ]; then
      lineno=0
      while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        fm_stow_plan_list_line "$line" || continue
        entries=$((entries + 1))
        fm_stow_plan_parse_line "$line"
        fm_stow_plan_entry_class "$today_days"
        tokens=$(fm_stow_plan_line_tokens "$line")
        age=$(fm_stow_plan_date_age_days "$ENTRY_DATE" "$today_days")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$file" "$lineno" "$ENTRY_TIER" "${ENTRY_DATE:--}" \
          "${age:--}" \
          "$ENTRY_PASSES" "$tokens" "$ENTRY_CLASS"
        if [ "$ENTRY_TIER" = a ] && [ "$ENTRY_CLASS" = stale ] && [ -n "$ENTRY_DATE" ]; then
          if [ "$role" != secondmate ] || [ "$file" != captain-shared.md ]; then
            pool="${pool}${file}$(printf '\t')${lineno}$(printf '\t')${ENTRY_DATE}$(printf '\t')${tokens}
"
          fi
        fi
      done < "$path"
    fi
    printf 'file=%s entries=%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$entries" "$FM_STARTUP_MEMORY_MEASURE_BYTES" \
      "$FM_STARTUP_MEMORY_MEASURE_TOKENS" "$FM_STARTUP_MEMORY_MEASURE_PRESENCE"
  done
  printf 'budget_tokens=%s\n' "$budget"
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'headroom_tokens=%s\n' $((budget - total))
  else
    printf 'must_shed_tokens=%s\n' $((total - budget))
  fi
  printf 'eviction_pool oldest-first: file line reinforced est_tokens cumulative\n'
  if [ -n "$pool" ]; then
    sorted=$(printf '%s' "$pool" | LC_ALL=C sort -t"$(printf '\t')" -k3,3 -k1,1 -k2,2n)
    cum=0
    while IFS="$(printf '\t')" read -r f l d t; do
      [ -n "$f" ] || continue
      cum=$((cum + t))
      printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$l" "$d" "$t" "$cum"
    done <<EOF2
$sorted
EOF2
    pool_total=$cum
  fi
  printf 'pool_total_tokens=%s\n' "$pool_total"
  if fm_startup_memory_decimal_le $((total - pool_total)) "$budget"; then
    printf 'converges=yes\n'
  else
    printf 'converges=no\n'
  fi
  mkdir -p "$STATE" || fm_stow_plan_die "could not create $STATE"
  {
    printf 'today=%s\n' "$today"
    for file in $MEMORY_FILES; do
      if fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
        printf 'file=%s estimated_tokens=%s\n' "$file" "$FM_STARTUP_MEMORY_MEASURE_TOKENS"
      fi
    done
    printf 'total_estimated_tokens=%s\n' "$total"
  } > "$STATE/.stow-plan-baseline.tmp" || fm_stow_plan_die "could not stage the receipt baseline"
  mv "$STATE/.stow-plan-baseline.tmp" "$STATE/.stow-plan-baseline" \
    || fm_stow_plan_die "could not publish the receipt baseline"
}

cmd_stamp() {
  local filearg=$1 lineno=$2 tier=$3 date=$4 passes=$5 path line base new_marker new_line
  [ "$tier" = a ] || [ "$tier" = p ] || fm_stow_plan_refuse "tier must be a or p"
  fm_stow_plan_date_valid "$date" || fm_stow_plan_refuse "date must be YYYY-MM-DD: $date"
  if [ -n "$passes" ]; then
    case "$passes" in
      *[!0-9]*|0|'') fm_stow_plan_refuse "passes must be a positive integer: $passes" ;;
    esac
    fm_stow_plan_pass_horizon_on \
      || fm_stow_plan_refuse "passes requires config/stow-pass-horizon"
  fi
  case "$lineno" in
    *[!0-9]*|0|'') fm_stow_plan_refuse "line-no must be a positive integer: $lineno" ;;
  esac
  path=$(fm_stow_plan_resolve_memory_file "$filearg")
  [ -f "$path" ] || fm_stow_plan_refuse "memory file is absent: $path"
  fm_stow_plan_read_lines "$path"
  [ "$lineno" -le "${#LINES[@]}" ] || fm_stow_plan_refuse "line $lineno is past the end of $filearg"
  line=${LINES[$((lineno - 1))]}
  fm_stow_plan_list_line "$line" || fm_stow_plan_refuse "line $lineno of $filearg is not a list line"
  fm_stow_plan_parse_line "$line"
  base=${ENTRY_BASE%"${ENTRY_BASE##*[![:space:]]}"}
  new_marker="<!--${tier}:${date}"
  [ -z "$passes" ] || new_marker="${new_marker}/${passes}"
  new_marker="${new_marker}-->"
  new_line="${base} ${new_marker}"
  if [ "$new_line" != "$line" ]; then
    LINES[lineno - 1]=$new_line
    fm_stow_plan_write_lines_atomic "$path"
  fi
  printf 'stamped %s:%s %s\n' "${path##*/}" "$lineno" "$new_marker"
}

fm_stow_plan_tier_name() {  # <marker-tier>
  case "$1" in
    a) printf '%s\n' aging ;;
    p) printf '%s\n' perishable ;;
    P) printf '%s\n' pinned ;;
    g) printf '%s\n' grace ;;
    *) printf '%s\n' unmarked ;;
  esac
}

# Derives the archive reason from ENTRY_* fields and ENTRY_CLASS.
fm_stow_plan_derive_reason() {
  local age clock today_days
  if [ "$ENTRY_TIER" = g ]; then
    printf '%s\n' 'legacy-unvalidated'
    return 0
  fi
  case "$ENTRY_TIER" in
    a|p)
      if [ "$ENTRY_CLASS" = stale ]; then
        today_days=$(fm_stow_plan_today_days "$(fm_stow_plan_today)")
        age=$(fm_stow_plan_date_age_days "$ENTRY_DATE" "$today_days")
        clock=$(fm_stow_plan_tier_clock_days "$ENTRY_TIER")
        if [ -n "$age" ] && [ "$age" -ge "$clock" ]; then
          printf 'unreinforced %sd\n' "$age"
          return 0
        fi
        if fm_stow_plan_pass_horizon_on; then
          clock=$(fm_stow_plan_tier_clock_passes "$ENTRY_TIER")
          if [ "$ENTRY_PASSES" -ge "$clock" ]; then
            printf 'unreinforced %sp\n' "$ENTRY_PASSES"
            return 0
          fi
        fi
      fi
      ;;
  esac
  printf '%s\n' 'budget oldest-first'
}

cmd_archive() {
  local filearg=$1 lineno=$2 reason=$3 path line text tier_name archive heading
  local archive_tmp
  case "$lineno" in
    *[!0-9]*|0|'') fm_stow_plan_refuse "line-no must be a positive integer: $lineno" ;;
  esac
  path=$(fm_stow_plan_resolve_memory_file "$filearg")
  [ -f "$path" ] || fm_stow_plan_refuse "memory file is absent: $path"
  fm_stow_plan_read_lines "$path"
  [ "$lineno" -le "${#LINES[@]}" ] || fm_stow_plan_refuse "line $lineno is past the end of $filearg"
  line=${LINES[$((lineno - 1))]}
  fm_stow_plan_list_line "$line" || fm_stow_plan_refuse "line $lineno of $filearg is not a list line"
  fm_stow_plan_parse_line "$line"
  fm_stow_plan_entry_class "$(fm_stow_plan_today_days "$(fm_stow_plan_today)")"
  reason=$(fm_stow_plan_reason_or_derive "$reason")
  tier_name=$(fm_stow_plan_tier_name "$ENTRY_TIER")
  text=$ENTRY_BASE
  text=${text#"${text%%[![:space:]]*}"}
  text=${text#[-*]}
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  archive="$DATA/memory-archive.md"
  heading="## $(fm_stow_plan_today) stow"
  archive_tmp=$(mktemp "${archive}.XXXXXX") || fm_stow_plan_die "could not create temporary file beside $archive"
  {
    if [ -f "$archive" ]; then
      cat "$archive"
      if ! grep -qxF "$heading" "$archive"; then
        if [ "$(tail -c 1 "$archive")" = "" ]; then
          printf '%s\n' "$heading"
        else
          printf '\n%s\n' "$heading"
        fi
      fi
    else
      printf '%s\n' "$heading"
    fi
    printf -- '- (from %s, tier: %s, reinforced: %s) %s [archived: %s]\n' \
      "${path##*/}" "$tier_name" "${ENTRY_DATE:--}" "$text" "$reason"
  } > "$archive_tmp" || { rm -f "$archive_tmp"; fm_stow_plan_die "could not stage archive update"; }
  # The archive lands first: a failure between the two writes duplicates the
  # entry rather than losing it, which is the safe direction for a cold tier.
  mv "$archive_tmp" "$archive" || { rm -f "$archive_tmp"; fm_stow_plan_die "could not replace $archive"; }
  unset "LINES[$((lineno - 1))]"
  fm_stow_plan_write_lines_atomic "$path"
  printf 'archived %s:%s -> data/memory-archive.md [archived: %s]\n' \
    "${path##*/}" "$lineno" "$reason"
}

fm_stow_plan_reason_or_derive() {  # <explicit-reason>
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
  else
    fm_stow_plan_derive_reason
  fi
}

cmd_check_destination() {
  local dest=$1 home_root rel
  home_root=${FM_HOME:-$FM_ROOT}
  git -C "$home_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf '%s\n' not-a-work-tree; exit 1; }
  case "$dest" in
    /*)
      case "$dest" in
        "$home_root"/*) rel=${dest#"$home_root"/} ;;
        *) printf '%s\n' outside-home-root; exit 1 ;;
      esac
      ;;
    *) rel=$dest ;;
  esac
  if [ -n "$(git -C "$home_root" ls-files -- "$rel")" ]; then
    printf '%s\n' tracked-in-index
    exit 1
  fi
  if [ -e "$home_root/$rel" ]; then
    printf '%s\n' filesystem-collision
    exit 1
  fi
  git -C "$home_root" check-ignore -q -- "$rel" || { printf '%s\n' not-ignored; exit 1; }
  printf '%s\n' safe
}

cmd_receipt() {
  local snap="$STATE/.stow-plan-baseline" file before after b_total
  local b_captain='' b_shared='' b_learn='' total_after=0 have_total=0
  if [ -r "$snap" ]; then
    b_captain=$(sed -n 's/^file=captain\.md estimated_tokens=//p' "$snap")
    b_shared=$(sed -n 's/^file=captain-shared\.md estimated_tokens=//p' "$snap")
    b_learn=$(sed -n 's/^file=learnings\.md estimated_tokens=//p' "$snap")
    b_total=$(sed -n 's/^total_estimated_tokens=//p' "$snap")
    [ -z "$b_total" ] || have_total=1
  fi
  for file in $MEMORY_FILES; do
    fm_startup_memory_measure_file "$DATA/$file" >/dev/null \
      || fm_stow_plan_die "$FM_STARTUP_MEMORY_BUDGET_ERROR"
    after=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    total_after=$((total_after + after))
    case "$file" in
      captain.md) before=${b_captain:-unavailable} ;;
      captain-shared.md) before=${b_shared:-unavailable} ;;
      learnings.md) before=${b_learn:-unavailable} ;;
    esac
    if [ "$before" = unavailable ]; then
      printf 'file=%s before=unavailable after=%s\n' "$file" "$after"
    else
      printf 'file=%s before=%s after=%s delta=%s\n' "$file" "$before" "$after" "$((after - before))"
    fi
  done
  if [ "$have_total" -eq 1 ]; then
    printf 'total before=%s after=%s delta=%s\n' "$b_total" "$total_after" "$((total_after - b_total))"
  else
    printf 'total before=unavailable after=%s\n' "$total_after"
  fi
}

case "${1:-}" in
  plan)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_plan
    ;;
  stamp)
    [ "$#" -ge 5 ] && [ "$#" -le 6 ] || { usage >&2; exit 2; }
    cmd_stamp "$2" "$3" "$4" "$5" "${6:-}"
    ;;
  archive)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
    cmd_archive "$2" "$3" "${4:-}"
    ;;
  check-destination)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cmd_check_destination "$2"
    ;;
  receipt)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_receipt
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
