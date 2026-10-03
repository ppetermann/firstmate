#!/usr/bin/env bash
# fm-maia-notify.sh - send keyed notifications to the maia-firstmate plugin.
#
# docs/maia-notify.md owns the operator contract (what is sent, when, and the
# config file's fields). This header owns the mechanics.
#
# Off by default. Every hook guards its call with one file test on the home's
# config/maia-notify, so while it is absent this script is never run. It
# repeats that test so a direct invocation writes and sends nothing.
#
# Hooks:
#   bin/fm-captain-hold.sh   send decision (a newly set hold, not a repeat or
#                            an --until deferral)
#   bin/fm-watch.sh          follow, detached, once per poll cycle
#   fleet-delivery-flow      send merge-ready (checklist D), send deployed
#                            (checklist F), run by the firstmate agent
#
# Usage:
#   fm-maia-notify.sh send <key> [--id <id>] [name=value ...]
#   fm-maia-notify.sh flush
#   fm-maia-notify.sh follow
#
# send validates the key and variables, drops a key not listed in the config's
# events, writes one JSON file to state/maia-notify/spool/ and starts flush
# detached. The spool file holds key, id, vars and creation time; the token is
# never written to it, and spool file names carry only time, pid and a random
# suffix. Values are cut to 200 characters. At most 16 variables. The spool
# keeps at most 200 files; the oldest is dropped to make room.
#
# flush posts each spool file in name order: the body (token added here) goes
# to the transport on stdin, so it is never in any argv. A 2xx answer or a 4xx
# other than 429 deletes the file; 429, 5xx and anything else keep it for a
# later flush. A transport failure (no HTTP status) stops this flush, so a dead
# maia costs one bounded attempt per flush. A file older than the ttl is
# dropped with one log line. One lock, so two flushes never overlap.
#
# follow maps new state/fleet-ledger.jsonl records to keys and spools them,
# then flushes. Ledger mapping needs config/fleet-ledger as well; the flush
# runs either way, which is what gives the spool its retry cadence. The byte
# offset lives in state/maia-notify/follow-offset. On the first run it starts
# at the end of the ledger, so history is not replayed; a ledger shorter than
# the offset (truncated) is read from byte 0. The offset is saved after the
# records are spooled, so an interrupted follow repeats rather than loses; the
# plugin deduplicates by id.
#   task.merged                  -> merged     project task pr_url pr_number via
#   task.status state=failed     -> failed     project task text
#   task.status state=blocked    -> blocked    project task text
#   task.pr_ready                -> pr-ready   project task pr_url
# The project is the basename of state/<task>.meta's project=.
#
# Log: state/maia-notify/log, one line per outcome, holding key, id and HTTP
# status. Variable values and the token are never logged.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE resolve the
# home as the other bin/ scripts do.
#   FM_MAIA_NOTIFY_EXEC   transport seam: run as `<cmd> <url>` with the JSON
#                         body on stdin; it prints the HTTP status. "discard"
#                         sends nothing and answers 202. Unset uses curl -m 5.
#   FM_MAIA_NOTIFY_FLUSH  what send does after spooling: background (default),
#                         sync, or none.
#   FM_MAIA_NOTIFY_NOW    clock override in Unix seconds, for tests.
#
# Exit status: 0 for every delivery outcome, including off, maia down, and a
# dropped notification; 2 only on a usage error. Hooks still ignore failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONF="$CONFIG/maia-notify"
DIR="$STATE/maia-notify"
SPOOL="$DIR/spool"
LOG="$DIR/log"
LEDGER="$STATE/fleet-ledger.jsonl"
DEFAULT_EVENTS="decision merge-ready merged deployed failed"
DEFAULT_TTL=900
SPOOL_MAX=200
VARS_MAX=16
VALUE_MAX=200
ID_MAX=200
SPOOL_SEQ=0

usage() {
  echo "usage: fm-maia-notify.sh send <key> [--id <id>] [name=value ...] | flush | follow" >&2
  exit 2
}

now() {
  printf '%s' "${FM_MAIA_NOTIFY_NOW:-$(date +%s)}"
}

log() {  # <message>
  mkdir -p "$DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
  # Keep the log bounded: past 256 KB, keep its newest 500 lines.
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
  return 0
}

# conf_value <field>: the last `field=value` line of the config, trimmed.
conf_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
    | tail -n 1 | sed 's/[[:space:]]*$//'
}

events() {
  local list
  list=$(conf_value events | tr ',' ' ')
  printf '%s' "${list:-$DEFAULT_EVENTS}"
}

ttl() {
  local t
  t=$(conf_value ttl)
  case "$t" in ''|*[!0-9]*) t=$DEFAULT_TTL ;; esac
  printf '%s' "$t"
}

key_ok() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

event_enabled() {  # <key>
  local e
  for e in $(events); do
    [ "$e" = "$1" ] && return 0
  done
  return 1
}

# Directory lock with stale-holder takeover. lock_take <name> -> 0 when held.
lock_take() {
  local lock="$DIR/.$1.lock" pid
  mkdir -p "$DIR" 2>/dev/null || return 1
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}

lock_drop() {
  rm -rf "$DIR/.$1.lock" 2>/dev/null || true
}

# spool <key> <id> <name=value>... : validated input -> one spool file.
spool() {
  local key=$1 id=$2 tmp file count
  shift 2
  if ! event_enabled "$key"; then
    log "off key=$key id=$id"
    return 0
  fi
  mkdir -p "$SPOOL" 2>/dev/null || { log "error key=$key id=$id: cannot create the spool"; return 0; }
  # Make room: the spool keeps at most SPOOL_MAX files, dropping the oldest.
  count=$(find "$SPOOL" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  while [ "$count" -ge "$SPOOL_MAX" ]; do
    file=$(find "$SPOOL" -maxdepth 1 -name '*.json' 2>/dev/null | sort | head -n 1)
    [ -n "$file" ] || break
    rm -f -- "$file"
    log "dropped spool-full file=${file##*/}"
    count=$((count - 1))
  done
  tmp=$(mktemp "$SPOOL/.new.XXXXXX") || { log "error key=$key id=$id: cannot write the spool"; return 0; }
  if ! jq -n --arg key "$key" --arg id "$id" --argjson created "$(now)" \
      --argjson max "$VALUE_MAX" '$ARGS.positional
        | map(index("=") as $i | {key: .[:$i], value: (.[$i + 1:]
            | gsub("[[:cntrl:]]"; " ")
            | if length > $max then .[0:$max - 1] + "…" else . end)})
        | from_entries as $vars
        | {key: $key, created: $created, vars: $vars}
        + (if $id == "" then {} else {id: $id} end)' --args "$@" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    log "error key=$key id=$id: cannot encode the notification"
    return 0
  fi
  # Name order is send order within one process: time, pid, then a sequence.
  SPOOL_SEQ=$((SPOOL_SEQ + 1))
  file="$SPOOL/$(now)-$$-$(printf '%06d' "$SPOOL_SEQ").json"
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; log "error key=$key id=$id: cannot write the spool"; return 0; }
  log "spooled key=$key id=$id vars=$#"
}

start_flush() {
  case "${FM_MAIA_NOTIFY_FLUSH:-background}" in
    none) ;;
    sync) cmd_flush ;;
    *) ( "$SELF" flush </dev/null >/dev/null 2>&1 & ) ;;
  esac
}

cmd_send() {
  local key=${1:-} id='' pair name n=0
  local -a pairs=()
  [ "$#" -ge 1 ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) [ "$#" -ge 2 ] || usage; id=$2; shift 2; continue ;;
      *=*) pairs+=("$1") ;;
      *) usage ;;
    esac
    shift
  done
  [ -e "$CONF" ] || return 0
  if ! key_ok "$key"; then
    log "rejected bad key"
    return 0
  fi
  # Ids are opaque to firstmate; cut them to the plugin's limit.
  id=$(printf '%s' "$id" | tr -d '\000-\037')
  [ "${#id}" -le "$ID_MAX" ] || id=${id:0:$ID_MAX}
  for pair in "${pairs[@]+"${pairs[@]}"}"; do
    name=${pair%%=*}
    if ! [[ "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
      log "rejected key=$key id=$id: bad variable name"
      return 0
    fi
    n=$((n + 1))
  done
  if [ "$n" -gt "$VARS_MAX" ]; then
    log "rejected key=$key id=$id: more than $VARS_MAX variables"
    return 0
  fi
  spool "$key" "$id" "${pairs[@]+"${pairs[@]}"}"
  start_flush
  return 0
}

# post <url> <token> <spool-file>: print the HTTP status ("000" on transport
# failure). The token reaches jq through a file descriptor, never argv or env.
post() {
  local url=$1 token=$2 file=$3
  jq -c --rawfile token <(printf '%s' "$token") \
      '{token: $token, key: .key} + (if .id then {id: .id} else {} end) + {vars: .vars}' \
      "$file" 2>/dev/null \
    | case "${FM_MAIA_NOTIFY_EXEC:-}" in
        '') curl -sS -m 5 -o /dev/null -w '%{http_code}' \
              -H 'Content-Type: application/json' --data-binary @- "$url" 2>/dev/null ;;
        discard) cat >/dev/null; printf '202' ;;
        *) $FM_MAIA_NOTIFY_EXEC "$url" 2>/dev/null ;;
      esac
}

cmd_flush() {
  local url token ttl_s now_s file created key id status mode
  [ -e "$CONF" ] || return 0
  [ -d "$SPOOL" ] || return 0
  lock_take flush || return 0
  # shellcheck disable=SC2064
  trap "rm -rf '$DIR/.flush.lock'" EXIT
  url=$(conf_value url)
  token=$(conf_value token)
  ttl_s=$(ttl)
  mode=$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF" 2>/dev/null || echo 600)
  case "$mode" in *00) ;; *) log "warning: config/maia-notify is readable by others (mode $mode); chmod 600 it" ;; esac
  for file in $(find "$SPOOL" -maxdepth 1 -name '*.json' 2>/dev/null | sort); do
    now_s=$(now)
    created=$(jq -r '.created // 0' "$file" 2>/dev/null || echo 0)
    key=$(jq -r '.key // ""' "$file" 2>/dev/null || true)
    id=$(jq -r '.id // ""' "$file" 2>/dev/null || true)
    case "$created" in ''|*[!0-9]*) created=0 ;; esac
    if [ $((now_s - created)) -gt "$ttl_s" ]; then
      rm -f -- "$file"
      log "expired key=$key id=$id"
      continue
    fi
    if [ -z "$url" ] || [ -z "$token" ]; then
      log "waiting key=$key id=$id: config/maia-notify has no url or token"
      break
    fi
    status=$(post "$url" "$token" "$file")
    case "$status" in
      2[0-9][0-9])
        rm -f -- "$file"
        log "delivered key=$key id=$id status=$status" ;;
      429)
        log "retry key=$key id=$id status=429" ;;
      4[0-9][0-9])
        rm -f -- "$file"
        log "rejected key=$key id=$id status=$status" ;;
      [0-9][0-9][0-9])
        if [ "$status" = 000 ]; then
          log "retry key=$key id=$id: maia unreachable"
          break
        fi
        log "retry key=$key id=$id status=$status" ;;
      *)
        log "retry key=$key id=$id: maia unreachable"
        break ;;
    esac
  done
  lock_drop flush
  trap - EXIT
  return 0
}

meta_project() {  # <task>
  local p
  p=$(sed -n 's/^project=//p' "$STATE/$1.meta" 2>/dev/null | head -n 1)
  p=${p%/}
  printf '%s' "${p##*/}"
}

# follow_record <json-line>: map one ledger record to a spooled notification.
follow_record() {
  local line=$1 fields event task state pr via text ts project num
  # Unit-separated, because read collapses empty fields between whitespace
  # separators such as tabs; control characters are blanked first.
  fields=$(printf '%s' "$line" | jq -r '[.event, .task, .state, .pr, .via, .text, .ts]
    | map(if . == null then "" else tostring | gsub("[[:cntrl:]]"; " ") end) | join("\u001f")' 2>/dev/null) || return 0
  IFS=$'\037' read -r event task state pr via text ts <<< "$fields"
  case "$task" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  project=$(meta_project "$task")
  case "$event" in
    task.merged)
      if [ "$via" = pr ] && [ -n "$pr" ]; then
        num=${pr##*/}
        case "$num" in *[!0-9]*) num='' ;; esac
        spool merged "merged:$pr" project="$project" task="$task" pr_url="$pr" pr_number="$num" via=pr
      else
        spool merged "merged:local:$task" project="$project" task="$task" via="${via:-local}"
      fi ;;
    task.status)
      text=$(printf '%s' "$text" | sed 's/^[[:space:]]*//')
      case "$state" in
        failed|blocked) spool "$state" "$state:$task:$ts" project="$project" task="$task" text="$text" ;;
      esac ;;
    task.pr_ready)
      [ -z "$pr" ] || spool pr-ready "pr-ready:$pr" project="$project" task="$task" pr_url="$pr" ;;
  esac
  return 0
}

cmd_follow() {
  local offset size new lines line consumed
  [ -e "$CONF" ] || return 0
  if [ -e "$CONFIG/fleet-ledger" ] && [ -f "$LEDGER" ] && lock_take follow; then
    size=$(wc -c < "$LEDGER" | tr -d ' ')
    offset=$(cat "$DIR/follow-offset" 2>/dev/null || true)
    case "$offset" in
      '') printf '%s\n' "$size" > "$DIR/follow-offset"; offset=$size ;;
      *[!0-9]*) offset=$size; printf '%s\n' "$size" > "$DIR/follow-offset" ;;
    esac
    [ "$offset" -le "$size" ] || offset=0
    if [ "$size" -gt "$offset" ] && new=$(mktemp "$DIR/.follow.XXXXXX"); then
      tail -c +"$((offset + 1))" "$LEDGER" | head -c "$((size - offset))" > "$new"
      # Only complete lines: a partial last line waits for a later follow.
      lines=$(tr -cd '\n' < "$new" | wc -c | tr -d ' ')
      if [ "$lines" -gt 0 ]; then
        while IFS= read -r line; do
          [ -z "$line" ] || follow_record "$line"
        done < <(head -n "$lines" "$new")
        consumed=$(head -n "$lines" "$new" | wc -c | tr -d ' ')
        printf '%s\n' "$((offset + consumed))" > "$DIR/follow-offset"
      fi
      rm -f -- "$new"
    fi
    lock_drop follow
  fi
  cmd_flush
  return 0
}

case "${1:-}" in
  send) shift; cmd_send "$@" ;;
  flush) [ "$#" -eq 1 ] || usage; cmd_flush ;;
  follow) [ "$#" -eq 1 ] || usage; cmd_follow ;;
  *) usage ;;
esac
exit 0
