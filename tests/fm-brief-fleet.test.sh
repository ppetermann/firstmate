#!/usr/bin/env bash
# tests/fm-brief-fleet.test.sh - this fleet's own bin/fm-brief.sh cases: the
# always-draft direct-PR definition of done, the required-review merge bar, PR
# hygiene sentences, and rule 6's keyed decisions. They live beside upstream's
# tests/fm-brief.test.sh so a take-in never re-resolves them inside it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-fleet)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The same two-project registry fixture upstream's suite writes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'REG'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
REG
}

# Fork patch (always-draft flow): a direct-PR ship runs the local gate, pushes
# once, opens its PR as a DRAFT, and reports done on that draft; firstmate owns
# the flip. The no-mistakes contract keeps upstream's non-draft readback, and
# local-only opens no PR, so it must not carry either requirement.
test_pr_based_dod_draft_contract() {
  local home mode id brief
  home="$TMP_ROOT/draft-dod-home"
  mkdir -p "$home/data"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-draft-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$mode: brief was not scaffolded"
    case "$mode" in
      local-only)
        assert_no_grep "isDraft" "$brief" "$mode: a branch-only delivery must not require a non-draft PR"
        assert_no_grep "DRAFT" "$brief" "$mode: a branch-only delivery must not open a draft PR"
        ;;
      direct-PR)
        assert_grep "bin/fm-local-gate.sh $id ." "$brief" \
          "$mode: done must run the local gate on the task before pushing"
        assert_grep "open the PR as a DRAFT" "$brief" \
          "$mode: the PR must open as a draft"
        assert_grep "Never mark it ready yourself" "$brief" \
          "$mode: the worker must leave the flip to firstmate"
        assert_grep "done [at=<epoch>]: PR {url}" "$brief" \
          "$mode: done must report the draft PR URL"
        assert_no_grep "isDraft" "$brief" "$mode: done must not require a non-draft PR"
        assert_no_grep "gh-axi pr ready" "$brief" "$mode: the worker must not mark its own PR ready"
        ;;
      no-mistakes)
        # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
        assert_grep 'confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`' "$brief" \
          "$mode: done must require reading the PR back from the forge as non-draft"
        ;;
    esac
  done
  pass "fm-brief.sh: direct-PR opens a draft after the local gate; no-mistakes keeps its non-draft readback"
}

# The PR-bearing DOD must state the required-review merge bar reviewer-neutrally:
# the PR-open report stays, but on a repository whose merge requires a review its
# findings are the worker's to address in one push per round, and a push after
# approval dismisses the approval. The concrete reviewer is per-task knowledge,
# so the scaffold must stay free of any specific review tool's name.
test_pr_briefs_state_required_review_merge_bar() {
  local home id brief
  home="$TMP_ROOT/review-bar-home"
  mkdir -p "$home/data"

  id="brief-reviewbar-dp-f2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "addressing them is part of this task" "$brief" \
    "direct-PR DOD lost relayed-review-findings ownership"
  assert_grep "land one round of fixes in a single push" "$brief" \
    "direct-PR DOD lost one-push-per-review-round batching"
  assert_grep "dismisses the approval and costs another full review round" "$brief" \
    "direct-PR DOD lost the approval-dismissal consequence"
  assert_no_grep "CodeRabbit" "$brief" \
    "direct-PR DOD hardcoded a specific review tool"
  assert_no_grep "CI-ready return point" "$brief" \
    "direct-PR DOD leaked retired pipeline CI-ready language"
  pass "fm-brief.sh: the PR-bearing DOD states the required-review merge bar and approval-dismissal cost"
}

# A local-only task has no PR and no reviewer, so its DOD must not carry any
# required-review or approval language from the PR-bearing modes.
test_local_only_dod_carries_no_review_language() {
  local home id brief
  home="$TMP_ROOT/local-no-review-home"
  mkdir -p "$home/data"
  id="brief-local-noreview-f3"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep "required review" "$brief" \
    "local-only DOD gained required-review language"
  assert_no_grep "review state" "$brief" \
    "local-only DOD gained review-state language"
  assert_no_grep "dismisses the approval" "$brief" \
    "local-only DOD gained approval-dismissal language"
  assert_no_grep "CodeRabbit" "$brief" \
    "local-only DOD hardcoded a specific review tool"
  pass "fm-brief.sh: local-only DOD carries no review language"
}

# Both PR-bearing DODs carry the PR-hygiene sentences (plain-word title, one
# Closes #N trailer per closed issue); the PR-less modes must not.
test_pr_hygiene_dod_sentences() {
  local id brief
  local title_sentence="Give the PR a title that names what the change does for the project in plain words - never the task id, the branch name, or a tool-generated prefix."
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  local closes_sentence='When this task closes GitHub issues, end the PR body with one `Closes #N` line per issue so the merge closes them automatically.'
  id="brief-pr-hygiene-d1"
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" "$id" alpha --mode direct-PR >/dev/null 2>&1
  brief="$BRIEF_HOME/data/$id/brief.md"
  assert_present "$brief" "direct-PR hygiene brief was not scaffolded"
  assert_grep "$title_sentence" "$brief" "direct-PR DOD lost the PR title sentence"
  assert_grep "$closes_sentence" "$brief" "direct-PR DOD lost the Closes #N trailer sentence"
  id="brief-pr-hygiene-l1"
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" "$id" alpha --mode local-only >/dev/null 2>&1
  brief="$BRIEF_HOME/data/$id/brief.md"
  assert_present "$brief" "local-only hygiene brief was not scaffolded"
  assert_no_grep "$title_sentence" "$brief" "local-only DOD must not carry the PR title sentence"
  assert_no_grep "$closes_sentence" "$brief" "local-only DOD must not carry the Closes #N trailer sentence"
  id="brief-pr-hygiene-s1"
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" "$id" alpha --scout >/dev/null 2>&1
  brief="$BRIEF_HOME/data/$id/brief.md"
  assert_present "$brief" "scout hygiene brief was not scaffolded"
  assert_no_grep "$title_sentence" "$brief" "scout brief must not carry the PR title sentence"
  assert_no_grep "$closes_sentence" "$brief" "scout brief must not carry the Closes #N trailer sentence"
  pass "fm-brief: PR-bearing DODs carry the title and Closes #N hygiene sentences, PR-less modes do not"
}

# Fork patch: rule 6 teaches the keyed decision syntax (with the emission stamp)
# that `fm-send --resolve-key` closes, on both ship and scout briefs, and a ship
# brief also routes ask-user findings to firstmate whatever raised them.
test_rule6_teaches_keyed_decisions() {
  local home kind id brief
  home="$TMP_ROOT/rule6-key-home"
  write_registry "$home"
  for kind in ship scout; do
    id="brief-rule6-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode direct-PR >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "needs-decision [at=<epoch>] [key=<slug>]: {one-line summary}" "$brief" \
      "$kind brief rule 6 lost the keyed decision syntax"
    assert_grep "bin/fm-send.sh <task> --resolve-key <slug>" "$brief" \
      "$kind brief rule 6 lost the resolve-key close"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'or a bare `resolved [at=<epoch>]: {how it cleared}` if you opened it without a key' "$brief" \
      "$kind brief lost the unkeyed self-close wording"
  done
  assert_grep "ask-user findings are never yours to answer: escalate and stop, whatever raised the finding." \
    "$home/data/brief-rule6-ship/brief.md" "ship brief rule 6 lost the ask-user routing"
  pass "fm-brief.sh: rule 6 teaches keyed decisions and ask-user routing"
}

fm_test_run \
  test_pr_based_dod_draft_contract \
  test_pr_briefs_state_required_review_merge_bar \
  test_local_only_dod_carries_no_review_language \
  test_pr_hygiene_dod_sentences \
  test_rule6_teaches_keyed_decisions
