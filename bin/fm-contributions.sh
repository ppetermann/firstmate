#!/usr/bin/env bash
# Observe published contributions owned by this home's durable task records.
#
# Usage:
#   fm-contributions.sh snapshot <input.json> [--all]
#   fm-contributions.sh poll
#   fm-contributions.sh pending
#   fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <captain|fleet|maintainer|nobody> <summary>
#   fm-contributions.sh ack <task> <url> <event-token>
#   fm-contributions.sh retire <task> <url> captain <reason>
#   fm-contributions.sh arm [--if-owned]
#   fm-contributions.sh owned
#   fm-contributions.sh enroll <task> <pr-url>
#
# snapshot is read-only and never contacts a forge. Its input is the canonical
# fleet snapshot's backlog/tasks pair; --all adds rows for supervisor inspection.
# URLs accepted by canonical_url in fm-contributions.jq and explicitly linked
# by a structured backlog row or a task's pr= are owned.
# Previously observed or enrolled URLs remain in data/<task>/contributions.json
# after endpoint teardown. Repository-wide PR discovery never establishes ownership.
# That file is the per-poll working set. poll moves a record whose observation is
# merged or closed and settled error-free for every owner, or that is retired,
# and has no pending signal, into data/<task>/contributions-archive.json (same
# schema), and lists each archived pair (task, url, kind, state, retired) in
# state/.contributions-archive.tsv, so its local cost scales with open
# contributions rather than history. The archive is written first, then the
# index, then the working file; an interrupted move leaves a duplicate whose
# working copy wins. A missing or malformed index is rebuilt from the archives,
# reading only those it lacks. poll, owned and arm read the index and never the
# archived records; snapshot, enroll, verdict, ack and retire read both, so an
# archived pair stays owned, final and measured, a retired one stays retired,
# and enroll on an archived URL changes nothing. A write to an archived pair
# lands in the working file and is archived again once settled.
# enroll records one task's supported PR URL as an unobserved record, so a PR
# the task opened is owned before any pr= exists; it changes nothing when the
# task already has a record for that URL and fails when that record is
# retired, so a retirement is never undone by rediscovery.
# owned prints the supported PR URLs this home owns as a JSON array of
# {url,tasks,final}, where final means a saved observation is merged or closed.
# It is read-only and never contacts a forge.
# Only canonical PR and issue URLs on the exact github.com host are supported;
# other accepted URLs remain visibly unmeasured.
# poll skips unsupported URLs without forge calls, unavailable output, wakes or
# new error stamps, and clears their legacy errors without changing observation,
# timestamps or ownership evidence.
#
# This script owns fm-contributions.v1: one atomic file per durable task with
# task and records[]. Each record contains url, kind, checked_at, error,
# observation, verdict, seen event tokens, pending events, notified tokens,
# unanswered threads, and retired provenance once retired.
# observation is one coherent forge read (a PR head is rechecked after fetching
# checks/reviews). Checks are normalized by name, id, started_at, status and
# conclusion; projection picks the newest attempt per distinct name. The last
# observation's lane names also disclose a lane absent from the next head.
# Reviews keep only id, state, submitted_at, commit_id and user.login, so a
# long review history cannot push a task's file past the 1 MiB cap above which
# a read refuses it as an unreadable record.
# A verdict records the EXACT judged head, source URL, actor and summary. The
# actor is exactly one of captain, fleet, maintainer or nobody; any other value
# is refused. A comment's arrival time never supplies its judged head. Record a
# prose verdict only after its source identifies that head; otherwise leave it unbound and
# triage its signal. Formal reviews carry GitHub's own commit_id. Neither kind
# can grant merge authority. Captain-actor prose requires an existing live hold;
# an eligible merge remains a captain call, never an automatic forge action.
#
# retire ends one task's observation of a contribution whose forge object can
# never be read again, such as a PR in a deleted repository. It records retired
# with actor captain, a non-empty reason and the UTC time. It refuses any
# other actor, a blank reason, and a task/url pair with no saved record or
# with unacknowledged pending signals. A retired pair leaves known, rotation and coverage even while a
# backlog link remains. Retiring a retired pair again is a no-op that keeps the
# first provenance. Nothing un-retires a record, poll never retires one on its
# own, and a later owner settled from a retired record is not retired. A
# retirement always records the captain's word: the script cannot verify who
# runs it, and the authority to retire is the captain's.
#
# poll consumes fm-fleet-snapshot.sh --contribution-input, a local-only read,
# and spends at most FM_CONTRIBUTIONS_BUDGET seconds on forge reads (default 20,
# 1..25). A configured value rides the generated check shim into watcher runs
# and is cut down to the watcher's own per-check bound (FM_CHECK_TIMEOUT,
# default 30, read from the poll's environment because the watcher runs it as
# a direct child) with a three-second margin. That margin also bounds the whole
# run from process start, local bookkeeping included: forge reads stop at the
# earlier of now plus the budget and that run bound, and settlement and
# archiving stop at the run bound. When local work passes its three seconds and
# leaves less than the observation reserve, poll prints one "contributions: local
# bookkeeping used ..." line per episode; a poll with its full reserve ends the
# episode. Every read, including one retry,
# is capped at five seconds. A first attempt killed at that bound or deadline is
# budget refusal; a killed retry retains the genuine failure that caused it.
# HTTP 5xx, 429, secondary-rate-limit 403, connection, DNS and TLS failures are
# retried once when that bound still has time. Other failures are reported
# immediately, including a 404, which is how a lost login reads on a private
# repository. A pull observation has three
# dependent waves: core, six independent reads (seven when FM_CONTRIBUTIONS_REPLY_AGE
# is set), then the closing head read;
# an issue has two waves. Before starting a URL, poll reserves the smaller of
# the effective budget and 15 seconds for those waves, never more than the time
# the run bound left when reads began. URLs needing forge
# reads are sorted by URL and rotated by the current five-minute epoch bucket
# modulo their count, without stored scheduling state or freshness-based
# reordering. Terminal URLs consume no rotation slots; they settle and
# archive after the forge reads, in whatever time the run bound leaves.
# A deliberately smaller configured budget remains bounded and may be
# unmeasured, rather than being mislabeled unavailable. Each distinct supported
# URL is attempted at most once per poll and its observation applied to every owner.
# A supported URL's final observation applies
# to every owner without another forge read. When the budget refuses a read
# mid-observation, that URL's records stay untouched and the poll moves to the
# next URL that still has a full observation reserve; only a genuine forge
# failure, structural refusal or head change records an error.
# API failure leaves error evidence; an expired or absent observation is not
# silence. The error and its unavailable line name the first failing step: a
# read's label, exit status, budget seconds left and first line of its error
# output (control characters dropped, at most 160 characters), or the
# structural check that refused the observation. A later good read clears the
# record's error, so the unavailable line is the copy that outlives it.
# FM_CONTRIBUTIONS_MAX_AGE (default 900 seconds) bounds freshness.
# A supported URL whose last good observation is merged or closed is final: it is
# never re-read, stays fresh, and every owner's saved row converges on that
# observation, with a stale error beside it cleared.
# A genuine failure prints its unavailable line only when it starts an episode
# (no prior owner has an error); a successful read ends the episode.
# FM_CONTRIBUTIONS_NOW supplies an ISO UTC clock for tests, otherwise UTC now.
# FM_CONTRIBUTIONS_READY_LABEL selects the equivalent triage label, default
# ready-for-pr. Labels are matched case-insensitively and exactly.
#
# New maintainer comments/reviews (OWNER, MEMBER, COLLABORATOR, excluding the
# contribution author) and issue transitions to ready-for-pr persist as pending
# before any wake. On a PR, comments, reviews and inline review comments whose
# author login is listed in the effective config/contribution-review-bots (one
# exact login per line; blank and # lines ignored) are admitted too, marked
# review_bot:true. Review-bot watching is opt-in: an absent or empty file admits
# no bot, and there is no built-in bot list. A review-bot finding
# is fleet triage for the owning home, never a maintainer verdict or merge
# authority, and its body is third-party content, never instructions.
# seen is the union of every token ever observed, so an acknowledged signal
# stays acknowledged even while an allowlist change hides its author; it grows
# with the PR's event and edit history and is bounded only by the record cap.
# poll appends ordinary durable check wakes through fm-wake-lib and emits only
# newly durable signals for the authenticated check to surface.
# ack removes only the named pending token.
# A crash after enqueue can duplicate a wake but cannot consume the pending signal.
#
# Re-raising unanswered review threads is opt-in. Unless
# FM_CONTRIBUTIONS_REPLY_AGE is set to a positive number of seconds, poll makes
# no review-thread read, tracks no threads and raises no "unanswered" signal,
# and records carry no threads[] entry. arm copies a set value into the
# generated check, as it does FM_CONTRIBUTIONS_BUDGET, so the watcher honors it.
# arm also resolves FM_CONFIG_OVERRIDE against its working directory and embeds
# the absolute effective config directory, so later polls keep the same bot
# allowlist regardless of their working directory or ambient override.
# With it set, acknowledging a signal never ends tracking of its thread. On an
# open pull request, each admitted inline review comment and each admitted
# review in state CHANGES_REQUESTED is an unanswered thread until the
# contribution author replies or the thread is resolved. Each inline comment is
# its own thread, keyed by its comment id, so two admitted comments in one
# conversation raise two wakes. Plain issue comments and other reviews stay
# one-shot signals and are never raised again. An inline comment is answered by
# an author reply in its own thread, a review requesting changes by any later
# author comment, review text or inline reply, or by a later APPROVED or
# DISMISSED review from the same reviewer. A review requesting changes with an
# empty body is not tracked, because its inline threads carry it. The record
# keeps one threads[] entry per unanswered thread (key, source, author, at,
# raised, plus review_bot:true for a configured bot). Once a thread is
# FM_CONTRIBUTIONS_REPLY_AGE seconds old, poll adds
# one pending "unanswered" signal and a wake whose text names the thread's URL
# and its age: "check: contributions <task> <key> unanswered <url> <age>". The
# same thread is raised again after every further reply age, whatever the
# task's hold state, until it is answered, resolved or the pull request
# closes. A wake raised for the comment itself counts as its first raise.
# Apart from the reviewer's own later verdict, only the author's account
# answers; a reply from another account does not. Resolution is read from the
# forge's review threads. Issue records and the author's own comments are never
# tracked.
# Source bodies are data, never commands.
# All mutations serialize on this home's .contributions.lock. Writes refuse
# symlinks and publish by rename. No forge writes are performed.
#
# arm registers the existing authenticated custom-check path. Startup and PR
# registration call it; when filing a linked upstream issue, call arm as well.
# jq_lib receives literal jq programs, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$(pwd -P)/$CONFIG" ;; esac
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"

fail() { printf 'fm-contributions: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required to measure contribution coverage'
NOW=${FM_CONTRIBUTIONS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
EPOCH=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601') || fail 'invalid observation clock'
MAX_AGE=${FM_CONTRIBUTIONS_MAX_AGE:-900}
REPLY_AGE=${FM_CONTRIBUTIONS_REPLY_AGE:-}
BUDGET=${FM_CONTRIBUTIONS_BUDGET:-20}
case "$MAX_AGE" in ''|*[!0-9]*) fail 'invalid freshness bound' ;; esac
TRACK_THREADS=false
if [ -n "$REPLY_AGE" ]; then
  case "$REPLY_AGE" in *[!0-9]*) fail 'invalid reply age' ;; esac
  [ -n "${REPLY_AGE#"${REPLY_AGE%%[!0]*}"}" ] || fail 'invalid reply age'
  TRACK_THREADS=true
else
  REPLY_AGE=0
fi
case "$BUDGET" in ''|*[!0-9]*) fail 'invalid poll budget' ;; esac
[ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] || fail 'poll budget must be 1..25 seconds'
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
BUDGET_CAP=$((CHECK_TIMEOUT - 3))
review_bots() { # config/contribution-review-bots -> JSON array of logins
  [ -f "$CONFIG/contribution-review-bots" ] || { printf '[]\n'; return 0; }
  jq -Rn '[inputs | gsub("^\\s+|\\s+$"; "") | select(length > 0 and (startswith("#") | not))]' "$CONFIG/contribution-review-bots"
}
[ "$BUDGET_CAP" -ge 1 ] || BUDGET_CAP=1
[ "$BUDGET" -le "$BUDGET_CAP" ] || BUDGET=$BUDGET_CAP
# The whole run, local work included, ends by RUN_END; SECONDS counts from process start.
START=$(( $(date +%s) - SECONDS ))
RUN_END=$((START + BUDGET_CAP))
ARCHIVE=contributions-archive.json
INDEX="$STATE/.contributions-archive.tsv"
STARVED="$STATE/.contributions-starved"
INDEX_DIRTY=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-contributions.XXXXXX")
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.contributions.lock" || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

jq_lib() { # jq options/program via final argument
  local program=${!#}
  set -- "${@:1:$#-1}"
  jq -L "$SCRIPT_DIR" "$@" "include \"fm-contributions\"; $program"
}

read_record_file() { # file task: append the valid record to $TMP/records.jsonl
  local dir
  fm_dirname_to dir "$1"
  # A file's task identity must match its durable directory, not arbitrary JSON.
  [ ! -L "$1" ] && [ ! -L "$dir" ] && [ -f "$1" ] \
    && [ "$(wc -c < "$1")" -le 1048576 ] \
    && jq_lib -nc --arg task "$2" --slurpfile record "$1" '
      if ($record | length) == 1 and ($record[0] | valid_record) and $record[0].task == $task
      then $record[0] else error("invalid record") end' >> "$TMP/records.jsonl" 2>/dev/null
}

read_records() { # file-name output-json: every valid data/<task>/<file-name>
  local file dir task
  : > "$TMP/records.jsonl"
  for file in "$DATA"/*/"$1"; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    fm_dirname_to dir "$file"
    fm_basename_to task "$dir"
    read_record_file "$file" "$task" || ERRORS=$((ERRORS + 1))
  done
  jq -s . "$TMP/records.jsonl" > "$2"
}

read_saved() { # the working set: data/<task>/contributions.json
  ERRORS=0
  if [ -L "$DATA" ]; then
    ERRORS=1; printf '[]\n' > "$TMP/saved.json"; return 0
  fi
  read_records contributions.json "$TMP/saved.json"
}

read_all() { # working records, then archived records whose pair has no working copy
  read_saved
  [ ! -L "$DATA" ] || return 0
  read_records "$ARCHIVE" "$TMP/archive.json"
  jq -n --slurpfile working "$TMP/saved.json" --slurpfile archive "$TMP/archive.json" '
    $working[0] + $archive[0] | group_by(.task)
    | map({schema:"fm-contributions.v1",task:.[0].task,
        records:(reduce (.[].records[]) as $r ([]; if any(.[]; .url == $r.url) then . else . + [$r] end))})' \
    > "$TMP/all.json"
  mv "$TMP/all.json" "$TMP/saved.json"
}

load_index() { # archived pairs into $TMP/index.json without reading indexed archives
  local file dir task
  : > "$TMP/archive-tasks"
  if [ ! -L "$DATA" ]; then
    for file in "$DATA"/*/"$ARCHIVE"; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      fm_dirname_to dir "$file"
      fm_basename_to task "$dir"
      printf '%s\n' "$task" >> "$TMP/archive-tasks"
    done
  fi
  if [ ! -f "$INDEX" ] || [ -L "$INDEX" ] || ! jq -Rn '[inputs | split("\t")
      | if length == 5 and (.[4] | IN("0","1")) then {task:.[0],url:.[1],kind:.[2],state:.[3],retired:(.[4] == "1")}
        else error("malformed index line") end]' < "$INDEX" > "$TMP/index.json" 2>/dev/null; then
    printf '[]\n' > "$TMP/index.json"
  fi
  # Drop a task whose archive is gone; read only the archives the index lacks.
  jq -Rn --slurpfile index "$TMP/index.json" '[inputs] as $tasks
    | ($index[0] | map(.task) | unique) as $indexed
    | {keep:[$index[0][] | select(.task | IN($tasks[]))],missing:($tasks - $indexed),
       dirty:((($tasks - $indexed) + ($indexed - $tasks)) != [])}' < "$TMP/archive-tasks" > "$TMP/index-plan.json"
  if jq -e '.dirty' "$TMP/index-plan.json" >/dev/null || [ ! -f "$INDEX" ]; then
    INDEX_DIRTY=1
  fi
  [ "$INDEX_DIRTY" = 1 ] || return 0
  : > "$TMP/records.jsonl"
  while IFS= read -r task; do
    read_record_file "$DATA/$task/$ARCHIVE" "$task" || ERRORS=$((ERRORS + 1))
  done < <(jq -r '.missing[]' "$TMP/index-plan.json")
  jq_lib -n --slurpfile plan "$TMP/index-plan.json" --slurpfile fresh <(jq -s . "$TMP/records.jsonl") '
    $plan[0].keep + [$fresh[0][] | index_entries]' > "$TMP/index.json"
}

persist_index() { # under the observation lock
  local device staged
  device=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$INDEX" "$device" || fail 'unsafe archive index destination'
  staged=$(umask 077; mktemp "$STATE/.contributions-archive.XXXXXX")
  jq -r '.[] | [.task,.url,.kind,.state,(if .retired then "1" else "0" end)] | @tsv' "$TMP/index.json" > "$staged"
  mv -f -- "$staged" "$INDEX"
  INDEX_DIRTY=0
}

read_view() { # working records plus a stub per archived pair; archived records are not read
  read_saved
  INDEX_DIRTY=0
  load_index
  jq -n --slurpfile saved "$TMP/saved.json" --slurpfile index "$TMP/index.json" '
    ([$saved[0][] | .task as $t | .records[] | {key:($t + "\t" + .url),value:true}] | from_entries) as $working
    | $saved[0] + ([$index[0][] | select($working[.task + "\t" + .url] | not)] | group_by(.task)
      | map({schema:"fm-contributions.v1",task:.[0].task,records:map({url,kind,
          checked_at:null,error:null,verdict:null,seen:[],pending:[],notified:[],
          observation:(if .state | IN("open","closed","merged") then {state} else null end),
          retired:(if .retired then {actor:"captain"} else null end)})}))' > "$TMP/view.json"
}

get_input() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input.json"
}

project() {
  jq_lib -n --slurpfile input "$1" --slurpfile saved "$TMP/saved.json" \
    --argjson now "$EPOCH" --argjson max_age "$MAX_AGE" --argjson errors "$ERRORS" \
    --arg all "${2:-}" '
    projected($input[0];$saved[0];$now;$max_age) as $rows
    | summary($rows;($errors + (if $input[0].backlog.present == true then 0 else 1 end)))
    # Final rows never expire; a home holding only final rows is valid from now.
    | .valid_until = (if ($rows | length) > 0 and all($rows[]; .final) then $now else .valid_until end) + $max_age
    | .captain_omitted = ([0, (.captain | length) - 20] | max)
    | .captain |= .[:20]
    | . + (if $all == "--all" then {rows:$rows} else {} end)'
}

acquire() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'data directory unavailable'
  # Keep the wake library's source-time state initialization off read-only paths.
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$STATE/.contributions.lock" || fail 'observation lock unavailable'
  LOCK_HELD=1
}

publish_task_file() { # task file-name content-file: atomically replace one durable task file
  local task=$1 dir file device staged
  fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
  dir="$DATA/$task"
  [ ! -L "$dir" ] || fail 'contribution directory is a symlink'
  mkdir -p "$dir"
  file="$dir/$2"
  device=$(fm_pr_file_device "$dir")
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'unsafe contribution record destination'
  staged=$(umask 077; mktemp "$dir/.contributions.XXXXXX")
  cat -- "$3" > "$staged"
  chmod 600 "$staged"
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'contribution destination changed'
  mv -f -- "$staged" "$file"
}

write_record() { # task record-json-file
  local task=$1 file
  fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
  file="$DATA/$task/contributions.json"
  # Preserve other contributions owned by this same task.
  if [ -f "$file" ] && [ ! -L "$DATA/$task" ]; then
    jq_lib -ne --arg task "$task" --slurpfile record "$file" '$record[0] | valid_record and .task == $task' >/dev/null || fail 'invalid stored contribution record'
    jq --slurpfile row "$2" '.records = ([.records[] | select(.url != $row[0].url)] + $row)' "$file" > "$TMP/file.json"
  else
    jq -n --arg task "$task" --slurpfile row "$2" '{schema:"fm-contributions.v1",task:$task,records:$row}' > "$TMP/file.json"
  fi
  publish_task_file "$task" contributions.json "$TMP/file.json"
}

forge_http_status() { # stderr-file
  sed -nE 's/^gh: HTTP ([0-9]{3})$/\1/p; s/^HTTP ([0-9]{3})[: ].*/\1/p; s/.*\(HTTP ([0-9]{3})\).*/\1/p' "$1" | head -n 1
}

forge_error_summary() { # stderr-file
  local err=$1 status
  status=$(forge_http_status "$err")
  if [ -n "$status" ]; then
    printf 'HTTP %s\n' "$status"
  elif grep -q '^GraphQL:' "$err"; then
    printf 'request failed\n'
  elif grep -Fqi 'error connecting to' "$err" \
    && grep -Fqi 'check your internet connection or https://githubstatus.com' "$err"; then
    printf 'DNS error\n'
  elif grep -Eqi '^Could not resolve host:|name resolution|no such host|dial (tcp|udp): lookup|lookup [^:]+:' "$err"; then
    printf 'DNS error\n'
  elif grep -Eqi 'tls: |x509: |TLS handshake|certificate (verify|signed)' "$err"; then
    printf 'TLS error\n'
  elif grep -Eqi 'connection (reset|refused|closed|failed|error)|could not connect|failed to connect|error connecting|broken pipe|network is unreachable|dial (tcp|udp)|unexpected EOF' "$err"; then
    printf 'connection error\n'
  else
    printf 'request failed\n'
  fi
}

forge_transient_error() { # stderr-file summary
  case "$2" in
    'HTTP 5'[0-9][0-9]|'HTTP 429'|'connection error'|'DNS error'|'TLS error') return 0 ;;
    'HTTP 403') grep -Eqi 'secondary[- ]rate[- ]limit' "$1" && return 0 ;;
  esac
  return 1
}

forge_bound_result() { # failed-rc failed-why fallback-rc
  FORGE_BOUND_RC=$3
  if [ "$1" -ne 0 ]; then
    : > "$TMP/forge-unavailable"
    printf '%s\n' "$2" >> "$TMP/why"
    FORGE_BOUND_RC=$1
  else
    BUDGET_EXHAUSTED=1
    : > "$TMP/budget-exhausted"
  fi
}

forge() {
  local remaining rc=0 failed_rc=0 failed_why='' now read_deadline
  local forge_err=${FORGE_ERR:-$TMP/forge.err} out summary why
  out=$(mktemp "$TMP/forge-output.XXXXXX")
  now=$(date +%s)
  read_deadline=$((now + 5))
  [ "$read_deadline" -le "$DEADLINE" ] || read_deadline=$DEADLINE
  while :; do
    now=$(date +%s)
    remaining=$((read_deadline - now))
    if [ "$remaining" -le 0 ]; then
      forge_bound_result "$failed_rc" "$failed_why" 1
      rm -f -- "$out"
      return "$FORGE_BOUND_RC"
    fi
    rc=0
    fm_run_timed "$remaining" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh "$@" > "$out" 2> "$forge_err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      cat "$out"
      rm -f -- "$out"
      return 0
    fi
    # A kill at the read bound or the deadline is budget refusal. If the retry
    # times out, retain the genuine forge failure that caused that retry.
    if [ "$rc" -eq 124 ]; then
      forge_bound_result "$failed_rc" "$failed_why" "$rc"
      rm -f -- "$out"
      return "$FORGE_BOUND_RC"
    fi
    # Keep the failing read's own words; the retry and cleanup discard its error file.
    why=$(printf '%s read exited %s with %ss of budget left: %s' "$(basename "$forge_err" .err)" "$rc" \
      "$((DEADLINE - $(date +%s)))" "$(sed -n '/[^[:space:]]/{p;q;}' "$forge_err" | tr -d '\000-\037\177' | cut -c1-160)")
    summary=$(forge_error_summary "$forge_err")
    if [ "$failed_rc" -ne 0 ] || ! forge_transient_error "$forge_err" "$summary"; then
      : > "$TMP/forge-unavailable"
      printf '%s\n' "$why" >> "$TMP/why"
      rm -f -- "$out"
      return "$rc"
    fi
    failed_rc=$rc
    failed_why=$why
  done
}

unobserved() { # why: a structural check, not a forge read, refused the observation
  printf '%s\n' "$1" >> "$TMP/why"
  return 1
}

wait_forges() { # background forge pids from one independent read wave
  local pid rc=0
  for pid in "$@"; do wait "$pid" || rc=1; done
  # A known failed parallel read is unavailable even if another read reached
  # the deadline. Only an otherwise successful wave cut short is unmeasured.
  if [ ! -e "$TMP/forge-unavailable" ] && [ -e "$TMP/budget-exhausted" ]; then
    BUDGET_EXHAUSTED=1
  fi
  return "$rc"
}

observe() { # canonical GitHub URL -> normalized JSON
  local url=$1 part number kind endpoint head after label
  case "$url" in https://github.com/*) ;; *) return 1 ;; esac
  part=${url#https://github.com/}; number=${part##*/}; part=${part%/*}; kind=${part##*/}; part=${part%/*}
  case "$kind" in pull) endpoint="repos/$part/pulls/$number" ;; issues) endpoint="repos/$part/issues/$number" ;; *) return 1 ;; esac
  rm -f -- "$TMP/budget-exhausted" "$TMP/forge-unavailable" "$TMP/why"
  BUDGET_EXHAUSTED=0
  FORGE_ERR="$TMP/core.err" forge api "$endpoint" > "$TMP/core.json" || return 1
  jq -e '(.state == "open" or .state == "closed") and (.user.login | type == "string")' "$TMP/core.json" >/dev/null \
    || unobserved 'core read returned an unexpected shape' || return 1
  if [ "$kind" = pull ]; then
    head=$(jq -er '.head.sha | select(test("^[a-fA-F0-9]{40}$"))' "$TMP/core.json") \
      || unobserved 'core read named no head commit' || return 1
    FORGE_ERR="$TMP/comments.err" forge api "repos/$part/issues/$number/comments?per_page=100" --paginate --slurp > "$TMP/comments.json" &
    local comments_pid=$!
    FORGE_ERR="$TMP/reviews.err" forge api "$endpoint/reviews?per_page=100" --paginate --slurp > "$TMP/reviews.json" &
    local reviews_pid=$!
    FORGE_ERR="$TMP/inline.err" forge api "$endpoint/comments?per_page=100" --paginate --slurp > "$TMP/inline.json" &
    local inline_pid=$!
    FORGE_ERR="$TMP/checks.err" forge api "repos/$part/commits/$head/check-runs?filter=all&per_page=100" --paginate --slurp > "$TMP/checks.json" &
    local checks_pid=$!
    FORGE_ERR="$TMP/statuses.err" forge api "repos/$part/commits/$head/statuses?per_page=100" --paginate --slurp > "$TMP/statuses.json" &
    local statuses_pid=$!
    FORGE_ERR="$TMP/repo.err" forge api "repos/$part" > "$TMP/repo.json" &
    local repo_pid=$!
    local -a pids=("$comments_pid" "$reviews_pid" "$inline_pid" "$checks_pid" "$statuses_pid" "$repo_pid")
    printf '[]\n' > "$TMP/threads.json"
    if [ "$TRACK_THREADS" = true ]; then
      FORGE_ERR="$TMP/threads.err" forge api graphql --paginate --slurp -f owner="${part%/*}" -f name="${part#*/}" -F number="$number" \
        -f query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved comments(first:1){nodes{databaseId}}}pageInfo{hasNextPage endCursor}}}}}' \
        > "$TMP/threads.json" &
      pids+=("$!")
    fi
    wait_forges "${pids[@]}" || return 1
    jq -e 'type == "array" and all(.[]; type == "array")' "$TMP/comments.json" >/dev/null \
      || unobserved 'comment pages returned an unexpected shape' || return 1
    jq -e 'type == "array" and all(.[]; (.data.repository.pullRequest.reviewThreads.nodes | type) == "array")' "$TMP/threads.json" >/dev/null \
      || unobserved 'review thread pages returned an unexpected shape' || return 1
    FORGE_ERR="$TMP/head.err" forge pr view "$url" --json headRefOid,reviewDecision > "$TMP/after.json" || return 1
    after=$(jq -er '.headRefOid | select(test("^[a-fA-F0-9]{40}$"))' "$TMP/after.json") \
      || unobserved 'head read named no head commit' || return 1
    [ "$head" = "$after" ] || unobserved 'head changed during observation' || return 1
    jq -n --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" \
      --slurpfile reviews "$TMP/reviews.json" --slurpfile inline "$TMP/inline.json" --slurpfile after "$TMP/after.json" --slurpfile checks "$TMP/checks.json" \
      --slurpfile statuses "$TMP/statuses.json" --slurpfile repo "$TMP/repo.json" --slurpfile threads "$TMP/threads.json" \
      --argjson track "$TRACK_THREADS" --argjson bots "$(review_bots)" '
      $core[0] as $c
      | ($reviews[0] | add // []) as $reviews
      | ($comments[0] | add // []) as $issue_comments
      | ($inline[0] | add // []) as $inline_comments
      | [$threads[0][] | .data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved) | .comments.nodes[0].databaseId] as $resolved
      # Replies by the contribution author, as timestamps: a review requesting
      # changes is answered by any later author comment, review body or inline reply.
      | ([$issue_comments[] | select(.user.login == $c.user.login) | .created_at]
        + [$inline_comments[] | select(.user.login == $c.user.login) | .created_at]
        + [$reviews[] | select(.user.login == $c.user.login and ((.body // "") != "")) | .submitted_at]) as $replied_at
      | {head:$c.head.sha,state:(if $c.merged_at != null then "merged" else $c.state end),
          draft:$c.draft,mergeable:(if $c.mergeable == true then "mergeable" elif $c.mergeable == false then "conflicting" else "unknown" end),
          can_merge:($repo[0].permissions.push // false),
          review_decision:($after[0].reviewDecision // ""),
          reviews:($reviews | map({id,state,submitted_at,commit_id,user:{login:.user.login}})),
          checks:([ $checks[0][] | .check_runs[] | {name,id,status,conclusion,started_at} ]
            + [ $statuses[0][] | .[] | {name:.context,id,started_at:.created_at,
              status:(if .state == "pending" then "in_progress" else "completed" end),
              conclusion:(if .state == "pending" then null else .state end)} ]),
          events:((($issue_comments | map(. + {_signal:"comment"})) + ($reviews | map(. + {_signal:"review"})) + ($inline_comments | map(. + {_signal:"review-comment"})))
            | map(select(.user.login != $c.user.login
                and ((.author_association | IN("OWNER","MEMBER","COLLABORATOR")) or (.user.login | IN($bots[]))))
              | (.created_at // .submitted_at // "") as $at | (.in_reply_to_id // .id) as $root | . as $e
              | {token:((._signal + ":") + (.id|tostring) + ":" + (.updated_at // .submitted_at // "") + ":" + (.state // "")),
                 type:._signal,source:.html_url,head:.commit_id,
                 author:.user.login,body:(.body // "" | .[:500])}
                 + (if (.user.login | IN($bots[])) then {review_bot:true} else {} end)
                 + (if $track then {at:$at,
                   # A resolved inline thread counts as answered.
                   unanswered:(if ._signal == "review-comment" then
                       ($resolved | index($root)) == null
                       and (any($inline_comments[]; .user.login == $c.user.login and (.in_reply_to_id // .id) == $root and .id > $e.id) | not)
                     elif ._signal == "review" and .state == "CHANGES_REQUESTED" and (.body // "") != "" then
                       (any($replied_at[]; . >= $at) | not)
                       and (any($reviews[]; .user.login == $e.user.login and (.state | IN("APPROVED","DISMISSED")) and .id > $e.id) | not)
                     else false end)} else {} end)))}' > "$TMP/observation.json" \
      || unobserved 'observation could not be assembled' || return 1
  else
    label=${FM_CONTRIBUTIONS_READY_LABEL:-ready-for-pr}
    FORGE_ERR="$TMP/comments.err" forge api "repos/$part/issues/$number/comments?per_page=100" --paginate --slurp > "$TMP/comments.json" &
    local comments_pid=$!
    FORGE_ERR="$TMP/issue-events.err" forge api "repos/$part/issues/$number/events?per_page=100" --paginate --slurp > "$TMP/issue-events.json" &
    local events_pid=$!
    wait_forges "$comments_pid" "$events_pid" || return 1
    jq -e 'type == "array" and all(.[]; type == "array")' "$TMP/comments.json" >/dev/null \
      || unobserved 'comment pages returned an unexpected shape' || return 1
    jq -n --slurpfile timeline "$TMP/issue-events.json" --arg label "$label" --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" '
      $core[0] as $c | {state:$c.state,head:null,
        ready:any($c.labels[]; (.name | ascii_downcase) == ($label | ascii_downcase)),
        checks:[],reviews:[],events:($comments[0] | add // []
          | map(select(.user.login != $c.user.login and (.author_association | IN("OWNER","MEMBER","COLLABORATOR")))
            | {token:("comment:" + (.id|tostring) + ":" + (.updated_at // "")),type:"comment",source:.html_url,
               head:null,author:.user.login,body:(.body // "" | .[:500])})
          + [$timeline[0][] | .[] | select(.event == "labeled" and (.label.name | ascii_downcase) == ($label | ascii_downcase))
             | {token:("ready-for-pr:" + (.id | tostring)),type:"ready-for-pr",source:$c.html_url,head:null,body:"filed issue reached ready-for-pr"}])}' > "$TMP/observation.json" \
      || unobserved 'observation could not be assembled' || return 1
  fi
  jq_lib -ne --arg url "$url" --arg kind "$kind" --slurpfile observed "$TMP/observation.json" '
    {schema:"fm-contributions.v1",task:"observation",records:[{url:$url,
      kind:(if $kind == "pull" then "pr" else "issue" end),pending:[],seen:[],observation:$observed[0]}]}
    | valid_record' >/dev/null || unobserved 'observation failed validation'
}

publish_pending() { # task canonical-url record-file
  local task=$1 url=$2 record=$3 token key count emitted status type source age reason
  count=$(jq '.pending | length' "$record")
  [ "$count" -gt 0 ] || return 0
  while IFS=$'\t' read -r token type source age; do
    [ -n "$token" ] || continue
    key=$(printf '%s\n%s\n' "$url" "$token" | shasum -a 256 | awk '{print $1}')
    emitted=0
    status=0
    reason="check: contributions $task $key"
    case "$type:$source" in
      unanswered:https://github.com/*) reason="$reason unanswered $source $age" ;;
    esac
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
    if ! fm_wake_queued_keys_locked check | grep -Fx "contribution-$key" >/dev/null; then
      fm_wake_append_locked check "contribution-$key" "$reason" || status=1
      [ "$status" -ne 0 ] || emitted=1
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1
    jq --arg token "$token" '.notified = ((.notified // []) + [$token] | unique)' "$record" > "$TMP/notified.json"
    mv "$TMP/notified.json" "$record"
    write_record "$task" "$record"
    [ "$emitted" -eq 0 ] || printf 'contribution-wake: %s\n' "$reason"
  done < <(jq -r '. as $r | .pending[] | select(.token as $t | ($r.notified // [] | index($t)) == null)
    | [.token, .type, (.source // "-"), (.age // "-")] | @tsv' "$record")
}

settle_final() { # canonical-url task... : copy the URL's final observation to every owner
  local url=$1 task
  local -a archived=()
  shift
  jq -n --slurpfile saved "$TMP/saved.json" --arg url "$url" '
    [$saved[0][] | .records[] | select(.url == $url
      and (.observation.state | IN("merged","closed")))] as $final
    | $final | sort_by([.retired != null, .error != null]) | first' > "$TMP/final.json"
  if jq -e '. == null' "$TMP/final.json" >/dev/null; then
    # The final observation was archived: read only the archives that hold it.
    while IFS= read -r task; do
      fm_pr_task_id_valid "$task" && archived+=("$DATA/$task/$ARCHIVE")
    done < <(jq -r --arg url "$url" '.[] | select(.url == $url and (.state | IN("merged","closed"))) | .task' "$TMP/index.json")
    [ "${#archived[@]}" -gt 0 ] || return 0
    jq -n --arg url "$url" '[inputs | .records[] | select(.url == $url
      and (.observation.state | IN("merged","closed")))]
      | sort_by([.retired != null, .error != null]) | first' "${archived[@]}" > "$TMP/final.json" 2>/dev/null || return 0
    jq -e '. != null' "$TMP/final.json" >/dev/null || return 0
  fi
  for task in "$@"; do
    fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
    jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" '
      [$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first' > "$TMP/old.json"
    if jq -e '. == null' "$TMP/old.json" >/dev/null; then
      jq -n --slurpfile final "$TMP/final.json" '
        $final[0] + {error:null,pending:[],notified:[]} | del(.retired)' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    elif jq -e '(.observation.state | IN("merged","closed") | not) or .error != null' "$TMP/old.json" >/dev/null; then
      jq -n --slurpfile final "$TMP/final.json" --slurpfile old "$TMP/old.json" '
        $old[0] + {observation:$final[0].observation,checked_at:$final[0].checked_at,error:null}
        | .pending |= map(select(.type != "unanswered"))
        | if has("notified") then .notified |= map(select(startswith("unanswered:") | not)) else . end
        | if has("threads") then .threads = [] else . end' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    fi
  done
}

clear_unsupported_errors() {
  local task url
  while IFS=$'\t' read -r task url; do
    fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
    jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" '
      $saved[0][] | select(.task == $task) | .records[] | select(.url == $url)
      | .error=null' > "$TMP/row.json"
    write_record "$task" "$TMP/row.json"
  done < <(jq_lib -nr --slurpfile saved "$TMP/saved.json" '$saved[0][] | .task as $task | .records[]
    | select((.url | supported_url | not) and .error != null)
    | [$task,.url] | @tsv')
}

archive_settled() { # move settled working rows into each task's archive while the run bound allows
  local task file
  local -a urls
  [ -s "$TMP/archivable.tsv" ] || return 0
  # Archive first, then the index, then the working file: an interrupted run
  # leaves a duplicate whose working copy wins, never a pair with no record.
  while IFS=$'\t' read -r -a urls; do
    task=${urls[0]}; urls=("${urls[@]:1}")
    [ "$(date +%s)" -lt "$RUN_END" ] || break
    fm_pr_task_id_valid "$task" && [ ! -L "$DATA/$task" ] || continue
    file="$DATA/$task/$ARCHIVE"
    : > "$TMP/records.jsonl"
    if [ -e "$file" ] || [ -L "$file" ]; then
      read_record_file "$file" "$task" || continue
    fi
    jq -n --arg task "$task" --slurpfile prior "$TMP/records.jsonl" \
      --slurpfile working "$DATA/$task/contributions.json" --args '
      $ARGS.positional as $urls
      | ($prior[0] // {schema:"fm-contributions.v1",task:$task,records:[]})
      | .records = ([.records[] | select(.url | IN($urls[]) | not)]
        + [$working[0].records[] | select(.url | IN($urls[]))])' "${urls[@]}" > "$TMP/archive-file.json" || continue
    publish_task_file "$task" "$ARCHIVE" "$TMP/archive-file.json"
    jq_lib -n --slurpfile index "$TMP/index.json" --slurpfile archive "$TMP/archive-file.json" --arg task "$task" '
      [$index[0][] | select(.task != $task)] + [$archive[0] | index_entries]' > "$TMP/index.next.json"
    mv "$TMP/index.next.json" "$TMP/index.json"
    (IFS=$'\t'; printf '%s\t%s\n' "$task" "${urls[*]}") >> "$TMP/archived.tsv"
  done < "$TMP/archivable.tsv"
  [ -s "$TMP/archived.tsv" ] || return 0
  persist_index
  while IFS=$'\t' read -r -a urls; do
    task=${urls[0]}; urls=("${urls[@]:1}")
    [ "$(date +%s)" -lt "$RUN_END" ] || break
    file="$DATA/$task/contributions.json"
    fm_pr_regular_destination_or_absent "$file" && [ -f "$file" ] || continue
    jq --args '$ARGS.positional as $urls | .records |= map(select(.url | IN($urls[]) | not))' \
      "${urls[@]}" < "$file" > "$TMP/working-file.json" || continue
    if jq -e '.records == []' "$TMP/working-file.json" >/dev/null; then
      rm -f -- "$file"
    else
      publish_task_file "$task" contributions.json "$TMP/working-file.json"
    fi
  done < "$TMP/archived.tsv"
}

poll() {
  local task url old kind error observed why now live
  local -a row
  acquire
  get_input
  read_view
  [ "$INDEX_DIRTY" = 0 ] || persist_index
  [ "$ERRORS" -eq 0 ] || printf 'contributions: %s unreadable durable record(s)\n' "$ERRORS"
  clear_unsupported_errors
  # Only supported URLs enter final settlement and the forge-read rotation, in
  # one classification pass: L lists a live URL then its owners, S a URL with a
  # final observation then the owners that still need it, and A a task then its
  # working rows that are settled and leave the per-poll working set.
  jq_lib -nr --slurpfile input "$TMP/input.json" --slurpfile view "$TMP/view.json" --slurpfile saved "$TMP/saved.json" '
    ([$view[0][] | .task as $t | .records[] | {task:$t,url,error,
        final:(.observation.state | IN("merged","closed"))}]
     | group_by([.task,.url]) | map(.[0]) | INDEX(.task + "\t" + .url)) as $first
    | [known($input[0];$view[0]) | map(select(.url | supported_url)) | group_by(.url)[]
      | {url:.[0].url,tasks:(map(.task) | unique)}
      | .url as $u | [.tasks[] | {task:.,row:$first[. + "\t" + $u]}] as $owners
      | if any($owners[]; .row != null and .row.final) then
          {kind:"S",url:$u,tasks:[$owners[] | select(.row == null or (.row.final | not) or .row.error != null) | .task]}
        else {kind:"L",url:$u,tasks:[$owners[].task]} end] as $urls
    | [$urls[] | select(.kind == "S" and .tasks != []) | .url] as $unsettled
    | ($urls[] | select(.tasks != []) | [.kind,.url] + .tasks | @tsv),
      ($saved[0][] | .task as $t
        | [.records[] | select(.pending == [] and (.retired != null
            or (.error == null and (.observation.state | IN("merged","closed"))
              and (.url | supported_url) and (.url | IN($unsettled[]) | not))))
          | .url] as $settled
        | select($settled != []) | ["A",$t] + $settled | @tsv)' > "$TMP/classified.tsv"
  : > "$TMP/live.tsv"; : > "$TMP/settle.tsv"; : > "$TMP/archivable.tsv"; : > "$TMP/archived.tsv"
  while IFS=$'\t' read -r -a row; do
    [ "${#row[@]}" -ge 3 ] || continue
    case "${row[0]}" in
      L) (IFS=$'\t'; printf '%s\n' "${row[*]:1}") >> "$TMP/live.tsv" ;;
      S) (IFS=$'\t'; printf '%s\n' "${row[*]:1}") >> "$TMP/settle.tsv" ;;
      A) (IFS=$'\t'; printf '%s\n' "${row[*]:1}") >> "$TMP/archivable.tsv" ;;
    esac
  done < "$TMP/classified.tsv"
  jq -Rnr --argjson bucket "$((EPOCH / 300))" '
    [inputs] | if length == 0 then . else ($bucket % length) as $offset | .[$offset:] + .[:$offset] end
    | .[]' < "$TMP/live.tsv" > "$TMP/known.tsv"
  now=$(date +%s)
  DEADLINE=$((now + BUDGET))
  [ "$DEADLINE" -le "$RUN_END" ] || DEADLINE=$RUN_END
  OBSERVATION_RESERVE=$((BUDGET < 15 ? BUDGET : 15))
  live=$(wc -l < "$TMP/known.tsv" | tr -d '[:space:]')
  # Local work past its three-second margin that cut the forge budget below the
  # observation reserve is reported once per episode; an uncut poll ends it.
  if [ "$live" -gt 0 ] && [ $((DEADLINE - now)) -lt "$OBSERVATION_RESERVE" ] && [ $((now - START)) -gt 3 ]; then
    if [ ! -e "$STARVED" ]; then
      : > "$STARVED"
      printf 'contributions: local bookkeeping used %ss of the %ss check bound, leaving %ss of forge budget for %s owned contributions\n' \
        "$((now - START))" "$CHECK_TIMEOUT" "$(( DEADLINE > now ? DEADLINE - now : 0 ))" "$live"
    fi
  elif [ -e "$STARVED" ]; then
    rm -f -- "$STARVED"
  fi
  # The reserve never exceeds what the run bound left, so the first URL still
  # gets every remaining second.
  [ $((DEADLINE - now)) -ge "$OBSERVATION_RESERVE" ] || OBSERVATION_RESERVE=$((DEADLINE - now))
  [ "$OBSERVATION_RESERVE" -ge 1 ] || OBSERVATION_RESERVE=1
  while IFS=$'\t' read -r -a row; do
    [ $((DEADLINE - $(date +%s))) -ge "$OBSERVATION_RESERVE" ] || break
    url=${row[0]}
    observed=0
    observe "$url" || observed=$?
    [ "$BUDGET_EXHAUSTED" -eq 0 ] || continue
    why='no failing step recorded'
    [ ! -s "$TMP/why" ] || IFS= read -r why < "$TMP/why"
    # Wake once per failure episode: only when no owner has a prior error.
    if [ "$observed" -ne 0 ] && jq -ne --slurpfile saved "$TMP/saved.json" --arg url "$url" --args \
      'all($ARGS.positional[] as $task | [$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first;
        .error == null)' "${row[@]:1}" >/dev/null; then
      printf 'contributions: observation unavailable for %s - %s\n' "$url" "$why"
    fi
    case "$url" in */issues/*) kind=issue ;; *) kind="pr" ;; esac
    for task in "${row[@]:1}"; do
      fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
      old="$TMP/old.json"
      jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" --arg kind "$kind" '
        ([$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first)
        // {url:$url,kind:$kind,checked_at:null,observation:null,verdict:null,seen:[],pending:[],notified:[]}' > "$old"
      if [ "$observed" -eq 0 ]; then
        jq_lib -n --arg now "$NOW" --argjson epoch "$EPOCH" --argjson reply_age "$REPLY_AGE" --argjson track "$TRACK_THREADS" \
          --slurpfile old "$old" --slurpfile observation "$TMP/observation.json" '
          $old[0] as $old | $observation[0] as $o
          | ($o.events + (if $o.ready == true and $old.observation.ready != true and (any($o.events[]; .type == "ready-for-pr") | not) then
              [{token:("ready-for-pr:" + $now),type:"ready-for-pr",source:$old.url,head:null,body:"filed issue reached ready-for-pr"}]
              else [] end)) as $events
          | [$events[] | select(.token as $t | ($old.seen // [] | index($t)) == null)] as $arrived
          # An acknowledgement removes the signal, not the thread: a thread
          # with no author reply or resolution is raised again after reply_age.
          | (if $track and $o.state == "open" then tracked_threads($old.threads; $o.events; $arrived | map(.token); $now) else [] end) as $tracked
          | due_threads($tracked; $epoch; $reply_age) as $due
          | ($tracked | map(.key)) as $live
          | ($due | map(.key)) as $due_keys
          | $old + {checked_at:$now,error:null,
            observation:($o + {absent_checks:((($old.observation.absent_checks // []) + [($old.observation.checks // [])[] | .name]) - [$o.checks[].name] | unique)}),
            seen:((($old.seen // []) + ($events | map(.token))) | unique),
            pending:((($old.pending // []) + $arrived
                | map(select(.type != "unanswered" or (.thread as $k | ($live | index($k)) != null and ($due_keys | index($k)) == null))))
              + [$due[] | reraise_event(.; $epoch; $now)] | unique_by(.token))}
          | (.pending | map(.token)) as $held
          | if has("notified") then .notified |= map(select((startswith("unanswered:") | not) or IN($held[]))) else . end
          | if $track then .threads = [$tracked[] | if .key | IN($due_keys[]) then .raised = $now else . end]
            else del(.threads) end' > "$TMP/row.json"
      else
        error="forge observation unavailable: $why"
        jq --arg now "$NOW" --arg error "$error" '.checked_at=$now | .error=$error' "$old" > "$TMP/row.json"
      fi
      write_record "$task" "$TMP/row.json"
      publish_pending "$task" "$url" "$TMP/row.json"
    done
  done < "$TMP/known.tsv"
  # Final observations need no forge read, so settlement and archiving take
  # only the time the forge phase left inside the run bound.
  while IFS=$'\t' read -r -a row; do
    [ "${#row[@]}" -ge 2 ] || continue
    [ "$(date +%s)" -lt "$RUN_END" ] || break
    settle_final "${row[@]}"
  done < "$TMP/settle.tsv"
  archive_settled
}

arm() {
  local device staged
  local -a shim
  acquire
  if [ "${1:-}" = --if-owned ]; then
    get_input; read_view
    if [ "$ERRORS" -eq 0 ] && ! jq_lib -ne --slurpfile input "$TMP/input.json" \
      --slurpfile view "$TMP/view.json" 'known($input[0];$view[0]) | length > 0' >/dev/null; then
      return 0
    fi
  fi
  device=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$STATE/contributions.check.sh" "$device" || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.contributions-check.XXXXXX")
  shim=('#!/usr/bin/env bash'
    "export FM_HOME=$(printf '%q' "$FM_HOME")"
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")"
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")"
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")")
  if [ -n "${FM_CONTRIBUTIONS_BUDGET:-}" ]; then
    shim+=("export FM_CONTRIBUTIONS_BUDGET=$(printf '%q' "$FM_CONTRIBUTIONS_BUDGET")")
  fi
  if [ -n "${FM_CONTRIBUTIONS_REPLY_AGE:-}" ]; then
    shim+=("export FM_CONTRIBUTIONS_REPLY_AGE=$(printf '%q' "$FM_CONTRIBUTIONS_REPLY_AGE")")
  fi
  shim+=("exec $(printf '%q' "$SCRIPT_DIR/fm-contributions.sh") poll")
  printf '%s\n' "${shim[@]}" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/contributions.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" contributions
}

case "${1:-}" in
  snapshot)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'snapshot needs canonical input'
    read_all
    project "$2" "${3:-}"
    ;;
  poll) poll ;;
  arm) arm "${2:-}" ;;
  owned)
    get_input; read_view
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); ownership is unverified"
    jq_lib -n --slurpfile input "$TMP/input.json" --slurpfile view "$TMP/view.json" '
      [$view[0][] | .records[] | select(.error == null and (.observation.state | IN("merged","closed"))) | .url] as $final
      | known($input[0];$view[0]) | map(select((.url | supported_url) and (.url | contains("/pull/"))))
      | group_by(.url) | map({url:.[0].url,tasks:(map(.task) | unique),final:(.[0].url | IN($final[]))})'
    ;;
  enroll)
    [ "$#" -eq 3 ] || fail 'enroll needs a task and a PR URL'
    task=$2; url=$3
    fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
    jq_lib -ne --arg url "$url" '$url | supported_url and contains("/pull/")' >/dev/null \
      || fail 'enroll needs a canonical github.com PR URL'
    acquire; read_all
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); enrollment is unverified"
    if jq -e --arg task "$task" --arg url "$url" 'any(.[] | select(.task == $task) | .records[]; .url == $url and .retired != null)' "$TMP/saved.json" >/dev/null; then
      fail 'contribution is retired for this task; enrollment refused'
    fi
    if ! jq -e --arg task "$task" --arg url "$url" 'any(.[] | select(.task == $task) | .records[]; .url == $url)' "$TMP/saved.json" >/dev/null; then
      jq -n --arg url "$url" '{url:$url,kind:"pr",checked_at:null,error:null,observation:null,verdict:null,seen:[],pending:[],notified:[]}' > "$TMP/row.json"
      write_record "$task" "$TMP/row.json"
    fi
    ;;
  pending)
    read_saved
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); pending signals are unverified"
    jq '[.[] | .task as $task | .records[] | .url as $url | .pending[] | . + {task:$task,url:$url}]' "$TMP/saved.json"
    ;;
  verdict|ack)
    action=$1; shift
    [ "$#" -ge 3 ] || fail 'task, URL and evidence required'
    task=$1; url=$2; shift 2
    acquire; get_input; read_all
    jq_lib -ne --slurpfile input "$TMP/input.json" --arg task "$task" --arg url "$url" --slurpfile saved "$TMP/saved.json" \
      'any(known($input[0];$saved[0])[]; .task == $task and .url == $url)' >/dev/null \
      || fail 'contribution is not owned by this durable task'
    jq -e --arg task "$task" --arg url "$url" '.[] | select(.task == $task) | .records[] | select(.url == $url)' "$TMP/saved.json" > "$TMP/row.json" \
      || fail 'observe the contribution before recording evidence'
    if [ "$action" = ack ]; then
      [ "$#" -eq 1 ] || fail 'ack needs one exact event token'
      jq --arg token "$1" '.pending |= map(select(.token != $token))' "$TMP/row.json" > "$TMP/update.json"
    else
      [ "$#" -eq 4 ] || fail 'verdict needs judged-head, source-url, actor and summary'
      fm_pr_head_valid "$1" || fail 'an exact judged commit is required'
      case "$3" in captain|fleet|maintainer|nobody) ;; *) fail "invalid required actor '$3'; expected one of: captain, fleet, maintainer, nobody" ;; esac
      case "$2" in "$url"\#*) ;; *) fail 'verdict source must be a comment or review on this contribution' ;; esac
      jq --arg head "$1" --arg source "$2" --arg actor "$3" --arg summary "$4" \
        '.verdict={head:$head,source:$source,actor:$actor,summary:$summary}' "$TMP/row.json" > "$TMP/update.json"
    fi
    write_record "$task" "$TMP/update.json"
    ;;
  retire)
    [ "$#" -eq 5 ] || fail 'retire needs task, URL, actor and reason'
    task=$2; url=$3
    fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
    [ "$4" = captain ] || fail "invalid retire actor '$4'; expected: captain"
    [ -n "${5//[[:space:]]/}" ] || fail 'retire needs a non-empty reason'
    acquire; read_all
    jq -e --arg task "$task" --arg url "$url" '.[] | select(.task == $task) | .records[] | select(.url == $url)' "$TMP/saved.json" > "$TMP/row.json" \
      || fail 'contribution is not recorded for this durable task'
    if jq -e '.retired != null' "$TMP/row.json" >/dev/null; then
      printf 'contributions: already retired %s for %s\n' "$url" "$task"
      exit 0
    fi
    jq -e '(.pending | length) == 0' "$TMP/row.json" >/dev/null \
      || fail 'acknowledge pending signals before retiring this contribution'
    jq --arg actor "$4" --arg reason "$5" --arg at "$NOW" \
      '.retired={actor:$actor,reason:$reason,at:$at}' "$TMP/row.json" > "$TMP/update.json"
    write_record "$task" "$TMP/update.json"
    ;;
  *) usage >&2; exit 2 ;;
esac
