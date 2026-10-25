#!/usr/bin/env bash
# fm-pr-flip.sh - flip a draft PR to ready and start its OCR review bot round
# in the same turn.
#
# The flip is the landing turn's sole CI and review trigger
# (fleet-delivery-flow phase 3). On a repository registered in
# config/ocr-bot/repos the bot's round would otherwise wait for the next
# fm-ocrbot-poll.sh cycle; this helper instead:
#   1. runs `gh pr ready` on the PR (nothing else happens if that fails);
#   2. reads the PR's head SHA and draft flag back from GitHub;
#   3. queues the same `ocr-pr <owner/repo>#<number> <head_sha>` check wake the
#      poll would emit, under the same per-PR key (ocrbot_wake_key), so
#      ocr-bot-review's ordinary wake handling spawns the round with no new
#      logic and several flips in one turn each keep their own wake;
#   4. records the PR as seen and ready at that head in the poll's seen-state,
#      so the poll does not wake for the same flip a second time.
# Wake first, record after, as the poll does: a failure between the two can
# only produce a duplicate wake, which the round's completed-check-run dedupe
# absorbs, never a lost round. A poll cycle racing the flip can likewise only
# produce a duplicate wake.
# On any other repository, or while the bot is not armed or its repos file has
# an invalid entry (the poll is inert then too), the helper only flips.
#
# Resolution: a task id with state/<id>.meta reads the recorded pr= identity;
# a raw GitHub PR URL is used as given. GitLab and other forges are refused.
#
# Exit codes: 0 flipped (and the round queued where the bot applies);
# 1 the flip failed and nothing changed; 2 usage error; 3 flipped, but the
# round could not be queued here - the poll's draft tracking still detects the
# flip on its next cycle, and the seen-state recovery in fleet-delivery-flow
# remains the fallback.
#
# Dependencies: gh, jq. Usage: fm-pr-flip.sh <task-id|pr-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-ocrbot-lib.sh
. "$SCRIPT_DIR/fm-ocrbot-lib.sh"

usage() {
  sed -n '2,32{s/^# \{0,1\}//;p;}' "$0"
}

ARG=
for a in "$@"; do
  case $a in
    -h|--help) usage; exit 0 ;;
    -*) echo "fm-pr-flip.sh: unknown flag: $a" >&2; exit 2 ;;
    *) [ -z "$ARG" ] || { echo "fm-pr-flip.sh: exactly one task id or PR url expected" >&2; exit 2; }
       ARG=$a ;;
  esac
done
[ -n "$ARG" ] || { usage >&2; exit 2; }

URL=$ARG
if fm_pr_task_id_valid "$ARG" && [ -f "$STATE/$ARG.meta" ] && [ ! -L "$STATE/$ARG.meta" ]; then
  fm_pr_metadata_identity_parse "$STATE/$ARG.meta" || true
  [ -n "$FM_PR_META_URL" ] || { echo "fm-pr-flip.sh: no PR recorded for task $ARG" >&2; exit 2; }
  URL=$FM_PR_META_URL
fi
fm_pr_url_parse "$URL" || { echo "fm-pr-flip.sh: not a valid task id or PR url: $ARG" >&2; exit 2; }
[ "$FM_PR_PROVIDER" = github ] || { echo "fm-pr-flip.sh: only GitHub PRs are supported: $FM_PR_URL" >&2; exit 2; }
URL=$FM_PR_URL
NUMBER=$FM_PR_NUMBER

command -v gh >/dev/null 2>&1 || { echo "fm-pr-flip.sh: gh not found" >&2; exit 1; }
if ! gh pr ready "$URL" >&2; then
  echo "fm-pr-flip.sh: gh pr ready failed for $URL" >&2
  exit 1
fi
echo "flipped $URL"

REPO=$(ocrbot_registered_repo "$(ocrbot_repos_file "$CONFIG")" "$FM_PR_OWNER/$FM_PR_REPO") || exit 0

not_queued() {
  echo "fm-pr-flip.sh: flipped, but the OCR review round was not queued: $1; the bot poll detects the flip on its next cycle" >&2
  exit 3
}

command -v jq >/dev/null 2>&1 || not_queued "jq not found"
PR_JSON=$(gh api "repos/$REPO/pulls/$NUMBER" 2>/dev/null) || not_queued "cannot read the PR back from GitHub"
read -r SHA DRAFT <<EOF
$(printf '%s' "$PR_JSON" | jq -r '[.head.sha, (.draft | if . then 1 else 0 end)] | @tsv' 2>/dev/null)
EOF
case "${SHA:-}" in ''|*[!A-Za-z0-9]*) not_queued "cannot parse the PR's head SHA" ;; esac
[ "${DRAFT:-}" = 0 ] || not_queued "GitHub still reports the PR as a draft"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Key and payload match what bin/fm-watch.sh queues for the poll's own output.
SHIM="$STATE/ocrbot-watch.check.sh"
LINE=$(ocrbot_wake_line "$REPO" "$NUMBER" "$SHA")
fm_wake_append check "$(ocrbot_wake_key "$SHIM" "$LINE")" "check: $SHIM: $LINE" || not_queued "cannot queue the review wake"
ocrbot_seen_upsert "$STATE" "$REPO" "$NUMBER" "$SHA" 0 \
  || echo "fm-pr-flip.sh: review queued, but the seen-state was not recorded; the poll may wake for this head once more" >&2
echo "review queued: $LINE"
