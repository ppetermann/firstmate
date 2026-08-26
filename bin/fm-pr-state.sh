#!/usr/bin/env bash
# fm-pr-state.sh - one-line live PR verdict for a task id or PR URL.
#
# Replaces the every-PR read-and-judge: one command re-checks a PR's live
# state before it is reported or re-reported (the re-check-before-reporting
# rule), collapsing forge state, checks, review, draft, and head into a
# single line plus a three-valued ready= verdict:
#   ready=yes     state OPEN, not draft, checks passing, review APPROVED
#   ready=checks  ci green with no review verdict - the reader judges whether
#                 this repo has a binding reviewer (per-repo review
#                 requirements differ; the script reports, the model judges)
#   ready=no      anything else; reason names the first failing condition in
#                 order merged/closed/draft/checks/review
#
# Resolution: a task id with state/<id>.meta reads the recorded canonical
# pr= identity; a raw PR/MR URL is used as given. GitHub reads
# state,isDraft,headRefOid,reviewDecision,statusCheckRollup in one gh call
# collapsed through fm_pr_checks_collapse_jq (fm-pr-lib.sh, the single owner
# shared with fm-bearings-snapshot.sh). GitLab gets a minimal state-only
# read; bin/fm-pr-merge.sh owns the full pre-merge battery there.
#
# Failures are loud - pr=<url> state=UNKNOWN ready=no reason=<short error>
# with exit 1 - the deliberate opposite of fm-pr-poll.sh's silence; that
# poll's byte-static identity is load-bearing and is not touched here.
#
# Dependencies: gh (GitHub reads), jq. Usage: fm-pr-state.sh <task-id|pr-url> [--json]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,26{s/^# \{0,1\}//;p;}' "$0"
}

unknown_verdict() {  # <url> <reason...>
  printf 'pr=%s state=UNKNOWN ready=no reason=%s\n' "$1" "$2"
  exit 1
}

JSON_MODE=0
ARG=
for a in "$@"; do
  case $a in
    --json) JSON_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "fm-pr-state.sh: unknown flag: $a" >&2; exit 2 ;;
    *) [ -z "$ARG" ] || { echo "fm-pr-state.sh: exactly one task id or PR url expected" >&2; exit 2; }
       ARG=$a ;;
  esac
done
[ -n "$ARG" ] || { usage >&2; exit 2; }

URL=
PROVIDER=
if fm_pr_task_id_valid "$ARG" && [ -f "$STATE/$ARG.meta" ] && [ ! -L "$STATE/$ARG.meta" ]; then
  fm_pr_metadata_identity_parse "$STATE/$ARG.meta" || true
  if [ -z "$FM_PR_META_URL" ]; then
    printf 'pr=- state=UNKNOWN ready=no reason=no PR recorded for task %s\n' "$ARG"
    exit 1
  fi
  URL=$FM_PR_META_URL
  PROVIDER=$FM_PR_META_PROVIDER
else
  fm_pr_url_parse "$ARG" || { echo "fm-pr-state.sh: not a valid task id or PR url: $ARG" >&2; exit 2; }
  URL=$FM_PR_URL
  PROVIDER=$FM_PR_PROVIDER
fi

if [ "$PROVIDER" = github ]; then
  command -v gh >/dev/null 2>&1 || unknown_verdict "$URL" "gh not found"
  RAW=$(gh pr view "$URL" --json state,isDraft,headRefOid,reviewDecision,statusCheckRollup 2>/dev/null) \
    || unknown_verdict "$URL" "gh pr view failed"
  PARSED=$(printf '%s' "$RAW" | jq -r "$(fm_pr_checks_collapse_jq)"'
    . as $p | [
      ($p.state // "UNKNOWN"),
      (if ($p.isDraft // false) then "yes" else "no" end),
      ($p.headRefOid // "-"),
      ($p.reviewDecision // "none"),
      fm_checks_state($p.statusCheckRollup // [])
    ] | @tsv') || unknown_verdict "$URL" "forge payload did not parse"
  IFS="$(printf '\t')" read -r P_STATE P_DRAFT P_HEAD P_REVIEW P_CHECKS <<EOF
$PARSED
EOF
  ready=no
  case $P_STATE in
    OPEN)
      if [ "$P_DRAFT" = yes ]; then
        reason=draft
      elif [ "$P_CHECKS" != passing ]; then
        reason="checks $P_CHECKS"
      elif [ "$P_REVIEW" = APPROVED ]; then
        ready=yes
        reason="ci green and review approved"
      elif [ "$P_REVIEW" = none ]; then
        ready=checks
        reason="ci green, no review verdict - check whether this repo has a binding reviewer"
      else
        reason="review $P_REVIEW"
      fi
      ;;
    MERGED) reason="already merged" ;;
    CLOSED) reason="closed without merging" ;;
    *) reason="state $P_STATE" ;;
  esac
  if [ "$JSON_MODE" = 1 ]; then
    jq -n --arg pr "$URL" --arg state "$P_STATE" --arg checks "$P_CHECKS" \
      --arg review "$P_REVIEW" --arg draft "$P_DRAFT" --arg head "$P_HEAD" \
      --arg ready "$ready" --arg reason "$reason" \
      '{pr:$pr, state:$state, checks:$checks, review:$review, draft:$draft, head:$head, ready:$ready, reason:$reason}'
  else
    printf 'pr=%s state=%s checks=%s review=%s draft=%s head=%s ready=%s reason=%s\n' \
      "$URL" "$P_STATE" "$P_CHECKS" "$P_REVIEW" "$P_DRAFT" "$P_HEAD" "$ready" "$reason"
  fi
  exit 0
fi

# GitLab: minimal state-only read; fm-pr-merge.sh owns the full battery.
G_REASON="gitlab minimal read - bin/fm-pr-merge.sh owns the full pre-merge battery"
if ! command -v glab >/dev/null 2>&1; then
  unknown_verdict "$URL" "glab not found"
fi
RAW=$(glab mr view "$URL" --output json 2>/dev/null) || unknown_verdict "$URL" "glab mr view failed"
G_STATE=$(printf '%s' "$RAW" | jq -r '.state // empty') || unknown_verdict "$URL" "forge payload did not parse"
case $G_STATE in
  opened|merged|closed) : ;;
  *) unknown_verdict "$URL" "forge payload did not parse" ;;
esac
if [ "$JSON_MODE" = 1 ]; then
  jq -n --arg pr "$URL" --arg state "$G_STATE" --arg reason "$G_REASON" \
    '{pr:$pr, state:$state, checks:"unknown", review:"unknown", draft:"unknown", head:"unknown", ready:"no", reason:$reason}'
else
  printf 'pr=%s state=%s checks=unknown review=unknown ready=no reason=%s\n' "$URL" "$G_STATE" "$G_REASON"
fi
