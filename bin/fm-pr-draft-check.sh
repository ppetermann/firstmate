#!/usr/bin/env bash
# Record a PR-ready task in this fleet's always-draft flow, where a direct-PR
# worker reports `done: PR <url>` on a DRAFT pull request and firstmate owns
# the flip at that PR's landing turn (AGENTS.md section 7, fleet-delivery-flow).
# Firstmate runs this at the ready signal in place of bin/fm-pr-check.sh, which
# refuses to arm merge monitoring on a draft.
#
# Usage: fm-pr-draft-check.sh <task-id> <pr-url>
#
# Steps, in order:
#   1. Refuses when FM_TASK_ID marks a task worker's own isolated (and possibly
#      stale) checkout: the arm-time poll template is this checkout's own copy
#      of fm-pr-poll.sh, and only firstmate's checkout is guaranteed to still
#      be the copy the watcher authenticates later.
#   2. Runs bin/fm-pr-check.sh unchanged under its FM_PR_CHECK_MERGE=1 seam,
#      which skips only its draft refusal and its fleet-ledger pr_ready write;
#      everything else (pr= and pr_head=, the named-head gate, the merge poll,
#      the contributions observer, the parent-channel ready line) is its own.
#      A refusal there is this script's refusal, with the same exit status.
#   3. Restores the fleet-ledger pr_ready record the seam skipped, when
#      config/fleet-ledger exists.
#   4. For a direct-PR task, checks the local-gate pass marker
#      (bin/fm-local-gate.sh owns its contract) against the recorded pr_head=
#      and prints an advisory `warning:` line to stderr when it is missing,
#      records no valid head, or names another head. Never blocks.
#   5. On GitHub, lints the PR title and body through fm_pr_body_lint
#      (bin/fm-pr-lib.sh), printing advisory PR_BODY_LINT: lines to stdout.
#      Never blocks.
# Merge-time draft refusal stays with bin/fm-pr-merge.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

case "${1:-}" in -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; exit 0 ;; esac

if [ -n "${FM_TASK_ID:-}" ]; then
  echo "error: fm-pr-draft-check.sh must be run by firstmate, not from a task worker (FM_TASK_ID=$FM_TASK_ID); report the PR URL to firstmate so it can register the merge watch" >&2
  exit 1
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_pr_url_parse "$2"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
[ "$PROVIDER" != github ] || fm_pr_github_host_export "$FM_PR_HOST"

rc=0
FM_PR_CHECK_MERGE=1 "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

[ ! -e "$CONFIG/fleet-ledger" ] \
  || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" pr_ready "$ID" "$URL" || true

META="$STATE/$ID.meta"
meta_value() { sed -n "s/^$1=//p" "$META" 2>/dev/null | tail -1; }

if [ "$(meta_value mode)" = direct-PR ]; then
  PR_HEAD=$(meta_value pr_head)
  GATE_PASS="$STATE/$ID.gate-pass"
  if [ -f "$GATE_PASS" ] && [ ! -L "$GATE_PASS" ]; then
    GATE_HEAD=$(sed -n 's/^head=//p' "$GATE_PASS" | tail -1 | cut -d' ' -f1)
    if [ -z "$GATE_HEAD" ] || ! fm_pr_head_valid "$GATE_HEAD"; then
      echo "warning: direct-PR task $ID gate pass marker records no valid head" >&2
    elif [ -n "$PR_HEAD" ] && [ "$GATE_HEAD" != "$PR_HEAD" ]; then
      echo "warning: direct-PR task $ID gate pass head $GATE_HEAD does not match PR head $PR_HEAD (branch moved after gating)" >&2
    fi
  else
    echo "warning: direct-PR task $ID has no local-gate pass marker (state/$ID.gate-pass); confirm the gate ran before the push" >&2
  fi
fi

WT=$(meta_value worktree)
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  LINT_TITLE=$(cd "$WT" && gh pr view "$URL" --json title -q .title 2>/dev/null || true)
  LINT_BODY=$(cd "$WT" && gh pr view "$URL" --json body -q .body 2>/dev/null || true)
  fm_pr_body_lint "$LINT_TITLE" "$LINT_BODY"
fi
