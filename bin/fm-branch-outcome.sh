#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false}.
#     Legacy rows without `silent` remain valid and are treated as visible.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as an append-only merge note, emitted by the locked session-start
#     replay, or silently consumed there because `silent` is true. Records
#     above the cursor are "unread": the branch stored them but
#     did not reach either handoff. A crash inside Pi's delivery window after
#     cursor advancement does not auto-replay the row; it remains durable and
#     available through the main session's fm_branch_outcomes tool.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the merge note is appended to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print visible unread records under a labeled
#     header into the locked startup digest, skip rows whose `silent` field is
#     true, and mark every unread row read. Prints nothing when nothing visible
#     is unread, so a home that never ran the branch stays silent. Run it only
#     when the session holds the lock (fm-session-start.sh owns the call site).
#   fm-branch-outcome.sh loop-check [--window <n>] [--threshold <n>]
#     Circuit breaker for a stuck branch (upstream has no equivalent guard;
#     see data/fm-upstream-degradation-compare/report.md follow-up 4). Looks
#     at the most recent --window rows (default 6, or FM_BRANCH_LOOP_WINDOW),
#     excluding a silent fleet-heartbeat row - a legitimate run of "nothing
#     changed" heartbeats is expected on a quiet fleet and is never evidence of
#     a stuck loop. A row counts against the breaker when its summary is
#     degenerate (trimmed to 3 characters or fewer, matching the observed
#     "task/wake/summary all '.'" incident shape) or when a non-captain-verdict
#     row exactly repeats a neighboring row (task, wake, summary, and verdict
#     all equal - a genuine content freeze, never coincidental for distinct
#     fleet events). A captain-verdict row is exempt from the repeat check
#     (though never from the degenerate check): the tool contract gates that
#     verdict on directly answering an explicit captain request, so identical
#     captain outcomes reflect the captain asking the same thing repeatedly,
#     not a stuck agent repeating itself unprompted. Trips when at least
#     --threshold (default 4, or
#     FM_BRANCH_LOOP_THRESHOLD) of the window rows qualify. Always prints
#     exactly one line and exits 0: "0" when not tripped, "1<TAB><reason>" when
#     tripped. The caller (the Pi branch extension's fm_branch_report tool) is
#     the one place that acts on a trip: it stops prompting the branch,
#     reclaims its row grant, and surfaces the trip as one captain-relevant
#     outcome - this subcommand only judges, never mutates state or the grant.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | list [--recent <n>] | startup-replay | loop-check [--window <n>] [--threshold <n>]" >&2
  exit 2
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

last_seq() {
  local value
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  value=$(tail -n 1 "$STORE" 2>/dev/null | jq -er '
    select(type == "object")
    | select(
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
    | .seq
  ') || return 1
  printf '%s\n' "$value"
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    advance_cursor "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      VISIBLE=$(printf '%s\n' "$UNREAD" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$UNREAD" | tail -n 1)")
      [ -z "$LAST" ] || advance_cursor "$LAST"
    fi
    fm_lock_release "$LOCK"
    ;;
  loop-check)
    WINDOW=${FM_BRANCH_LOOP_WINDOW:-6}
    THRESHOLD=${FM_BRANCH_LOOP_THRESHOLD:-4}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --window) WINDOW=${2:-}; shift 2 || usage ;;
        --threshold) THRESHOLD=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    case "$WINDOW" in ''|*[!0-9]*|0) usage ;; esac
    case "$THRESHOLD" in ''|*[!0-9]*|0) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if [ ! -s "$STORE" ]; then
      fm_lock_release "$LOCK"
      printf '0\n'
      exit 0
    fi
    RESULT=$(tail -n "$WINDOW" "$STORE" | jq -s -r --argjson threshold "$THRESHOLD" '
      def same($a; $b): $a.task == $b.task and $a.wake == $b.wake
        and $a.summary == $b.summary and $a.verdict == $b.verdict;
      map(select(.silent != true)) as $rows
      | ($rows | length) as $n
      | [ range(0; $n) as $i
          | $rows[$i] as $r
          | (($r.summary // "") | length) <= 3 as $empty
          # A row counts as "identical" when either neighbor matches it, so a
          # run of N mutually-identical rows contributes all N (not N-1) - the
          # plain reading of "N identical rows", not merely N-1 repeats of a
          # first occurrence that itself goes uncounted. A captain-verdict row
          # never counts here (though it still can via $empty): the tool
          # contract gates that verdict on directly answering an explicit
          # captain request, so a run of identical captain outcomes reflects
          # the captain asking the same thing repeatedly, not a stuck agent
          # repeating itself unprompted - the incident this guards against.
          | ($r.verdict != "captain"
             and (($i > 0 and same($rows[$i - 1]; $r)) or ($i < $n - 1 and same($rows[$i + 1]; $r)))) as $dup
          | select($empty or $dup)
        ] as $bad
      | ($bad | length) as $count
      | (if $n > 0 then $rows[$n - 1] else null end) as $last
      | [ (if $count >= $threshold then "1" else "0" end),
          ($count | tostring),
          ($n | tostring),
          (if $last then ($last.task // "") else "" end),
          (if $last and (($last.summary // "") | length) > 0 then $last.summary else "(empty)" end)
        ] | @tsv
    ') || { fm_lock_release "$LOCK"; exit 1; }
    fm_lock_release "$LOCK"
    IFS=$(printf '\t') read -r TRIPPED COUNT N LAST_TASK LAST_SUMMARY <<EOF
$RESULT
EOF
    if [ "$TRIPPED" = 1 ]; then
      printf '1\t%s of the last %s branch outcome rows look identical or empty (most recent: %s: %s)\n' \
        "$COUNT" "$N" "$LAST_TASK" "$LAST_SUMMARY"
    else
      printf '0\n'
    fi
    ;;
  *) usage ;;
esac
