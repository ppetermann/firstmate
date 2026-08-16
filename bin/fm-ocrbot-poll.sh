#!/usr/bin/env bash
# One short-poll of the OCR review bot's registered repos for reviewable PRs.
#
# Inert by default: a HARD no-op (exit 0, no output) unless
# config/ocr-bot/repos exists and lists at least one valid owner/repo entry.
# The watcher invokes this trusted repository script directly only after
# state/ocrbot-watch.check.sh matches the expected byte-static identity shim.
# Its contract is "output => wake firstmate, silence => keep sleeping".
#
# Per cycle, per registered repo:
#   - gh api -i "repos/<repo>/pulls?state=open&per_page=50" under the ambient
#     (captain) gh auth, ETag-conditional via If-None-Match from the private
#     cache state/ocrbot/etag/<owner>__<repo>; a 304 skips the repo for free.
#     gh api -i prints the status line, headers, a blank line, then the body,
#     and exits 1 on the expected 304, so the status line in stdout (not the
#     exit code) classifies the response.
#   - Every currently open PR (draft or not) is recorded as
#     "<number> <head_sha> <draft:0|1>" in state/ocrbot/seen/<owner>__<repo>.
#   - One stdout line "ocr-pr <owner/repo>#<number> <head_sha>" per reviewable
#     PR: a PR never seen before, a new head SHA on a known PR, or a
#     draft-to-ready transition. Draft PRs never wake.
#     The watcher's wake payload joins lines with spaces, which stays
#     unambiguous because every line carries its own "ocr-pr" prefix.
#   - Seen-state advances only AFTER the wake lines print, so a crash between
#     the two re-detects on the next cycle instead of losing a review.
#   - Auth/config errors print one deduped diagnostic "ocrbot-error <first
#     line>" (state/ocrbot/poll.error marker, x-poll.error pattern); a fully
#     successful cycle clears the marker.
#
# Cadence: the watcher's default check sweep (300s); the bot defines no
# cadence override. Budget is one conditional request per repo per cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ocrbot-lib.sh
. "$SCRIPT_DIR/fm-ocrbot-lib.sh"

REPOS_FILE=$(ocrbot_repos_file "$CONFIG")
# Hard no-op until the home opts in: this is what keeps the check shim inert.
[ -f "$REPOS_FILE" ] || exit 0

STATE_DIR="$STATE/ocrbot"
ERROR_FILE="$STATE_DIR/poll.error"

emit_error_once() {
  local msg=$1
  msg=$(printf '%s' "$msg" | head -n 1 | cut -c1-160)
  if fmx_private_artifact_file_valid "$STATE_DIR" poll.error 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE_DIR" poll.error 600 2>/dev/null || true
  printf 'ocrbot-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$STATE_DIR" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v gh >/dev/null 2>&1 || { emit_error_once "missing gh"; exit 0; }
command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ocrbot-poll.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT

# A malformed repos entry is a config error: report it once and stay inert this
# cycle rather than partially polling around a typo.
if ! ocrbot_repos_list "$REPOS_FILE" > "$WORK/repos" 2> "$WORK/repos-invalid"; then
  emit_error_once "$(head -n 1 "$WORK/repos-invalid" 2>/dev/null || echo invalid repos file)"
  exit 0
fi
[ -s "$WORK/repos" ] || exit 0

all_ok=1
while IFS= read -r repo; do
  name=$(ocrbot_state_name "$repo")
  seen_file="$STATE_DIR/seen/$name"
  etag_file="$STATE_DIR/etag/$name"

  etag=
  if fmx_private_artifact_file_valid "$STATE_DIR/etag" "$name" 600; then
    etag=$(cat "$etag_file" 2>/dev/null || true)
  fi

  gh_args=(-i "repos/$repo/pulls?state=open&per_page=50")
  [ -n "$etag" ] && gh_args+=(-H "If-None-Match: $etag")

  gh api "${gh_args[@]}" > "$WORK/headers" 2> "$WORK/gh-err" || true
  status=$(awk 'NR == 1 { print $2; exit }' "$WORK/headers")
  case "$status" in
    304) continue ;;
    200) ;;
    *)
      diag=$(head -n 1 "$WORK/gh-err" 2>/dev/null | tr '\t\r' '  ')
      [ -n "$diag" ] || diag="gh api failed for $repo${status:+ (status $status)}"
      emit_error_once "$diag"
      all_ok=0
      continue
      ;;
  esac

  new_etag=$(awk -F': *' 'tolower($1) == "etag" { print $2; exit }' "$WORK/headers")
  # The body is everything after the first blank line of the -i dump.
  awk 'body { print } $0 == "" { body = 1 }' "$WORK/headers" | tr -d '\r' > "$WORK/body"

  if ! jq -r '.[] | [.number, .head.sha, (.draft | if . then 1 else 0 end)] | @tsv' \
    "$WORK/body" > "$WORK/prs" 2>/dev/null; then
    emit_error_once "cannot parse the PR listing for $repo"
    all_ok=0
    continue
  fi

  : > "$WORK/new-seen"
  : > "$WORK/wakes"
  while IFS="$(printf '\t')" read -r num sha draft; do
    case "$num" in ''|*[!0-9]*) continue ;; esac
    case "$sha" in ''|*[!A-Za-z0-9]*) continue ;; esac
    prev=$(awk -v n="$num" '$1 == n { print $2, $3; exit }' "$seen_file" 2>/dev/null || true)
    reviewable=0
    if [ "$draft" = 1 ]; then
      reviewable=0
    elif [ -z "$prev" ]; then
      reviewable=1
    elif [ "${prev%% *}" != "$sha" ]; then
      reviewable=1
    elif [ "${prev#* }" = 1 ]; then
      reviewable=1
    fi
    [ "$reviewable" -eq 1 ] && printf 'ocr-pr %s#%s %s\n' "$repo" "$num" "$sha" >> "$WORK/wakes"
    printf '%s %s %s\n' "$num" "$sha" "$draft" >> "$WORK/new-seen"
  done < "$WORK/prs"

  # Wake first, record after: a failure between these re-detects next cycle.
  cat "$WORK/wakes"
  if ! fmx_private_artifact_publish_stdin "$STATE_DIR/seen" "$name" 600 < "$WORK/new-seen"; then
    emit_error_once "cannot record seen-state for $repo"
    all_ok=0
    continue
  fi
  if [ -n "$new_etag" ]; then
    if ! printf '%s\n' "$new_etag" \
      | fmx_private_artifact_publish_stdin "$STATE_DIR/etag" "$name" 600; then
      emit_error_once "cannot record the ETag for $repo"
      all_ok=0
    fi
  fi
done < "$WORK/repos"

[ "$all_ok" -eq 1 ] && clear_error
exit 0
