#!/usr/bin/env bash
# tests/fm-pr-check-lint.test.sh - behavior tests for fm_pr_body_lint in
# bin/fm-pr-lib.sh.
#
# The lint is a pure detector driven as a function: every known-bad shape
# fires its exact advisory line, a clean human title+body prints nothing,
# multiple hits print multiple lines, and the function always returns 0 so
# bin/fm-pr-check.sh arms the merge poll regardless.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

NL='
'

run_lint() {  # <title> <body> -> LINT (stdout), RC
  LINT=$(fm_pr_body_lint "$1" "$2")
  RC=$?
}

expect_lines() {  # <expected-count> <label>
  local want=$1 label=$2 got
  got=$(printf '%s\n' "$LINT" | sed -n '/./p' | wc -l | tr -d ' ')
  [ "$got" = "$want" ] || fail "$label: expected $want lint line(s), got $got:$NL$NL$LINT"
}

test_each_pattern_fires_its_exact_line() {
  run_lint "A fine title" "You are a crewmate managed by firstmate."
  expect_lines 1 "crewmate brief body"
  [ "$LINT" = "PR_BODY_LINT: body contains crewmate brief text" ] || fail "crewmate message mismatch: $LINT"

  run_lint "A fine title" "Steps: {TASK} and more."
  expect_lines 1 "placeholder body"
  [ "$LINT" = "PR_BODY_LINT: body contains a brief placeholder" ] || fail "placeholder message mismatch: $LINT"

  run_lint "A fine title" "# Definition of done
mode=direct-PR"
  expect_lines 1 "contract heading body"
  [ "$LINT" = "PR_BODY_LINT: body contains brief contract text" ] || fail "contract message mismatch: $LINT"

  run_lint "A fine title" "Delivery contract: mode=direct-PR"
  expect_lines 1 "delivery contract body"
  [ "$LINT" = "PR_BODY_LINT: body contains brief contract text" ] || fail "delivery-contract message mismatch: $LINT"

  run_lint "A fine title" "See state/fm-fix-login.status for details."
  expect_lines 1 "status file reference body"
  [ "$LINT" = "PR_BODY_LINT: body references an internal status file" ] || fail "status-file message mismatch: $LINT"

  run_lint "A fine title" "Intent: make the gate pass"
  expect_lines 1 "pipeline intent body"
  [ "$LINT" = "PR_BODY_LINT: body is a pipeline intent, not a human description" ] || fail "intent message mismatch: $LINT"

  run_lint "A fine title" "## Intent: fix the flake"
  expect_lines 1 "pipeline intent heading body"
  [ "$LINT" = "PR_BODY_LINT: body is a pipeline intent, not a human description" ] || fail "intent-heading message mismatch: $LINT"

  run_lint "A fine title" ""
  expect_lines 1 "empty body"
  [ "$LINT" = "PR_BODY_LINT: body is empty" ] || fail "empty-body message mismatch: $LINT"

  run_lint "fm-fix-login-k3" "A human description of the change."
  expect_lines 1 "task-id title"
  [ "$LINT" = "PR_BODY_LINT: title is a task or branch id, not a description" ] || fail "task-id title message mismatch: $LINT"

  run_lint "fm/llm-to-code-w1" "A human description of the change."
  expect_lines 1 "branch-id title"
  [ "$LINT" = "PR_BODY_LINT: title is a task or branch id, not a description" ] || fail "branch-id title message mismatch: $LINT"
  pass "fm_pr_body_lint: every pattern fires its exact advisory line"
}

test_clean_and_multi_hit_shapes() {
  # A clean human title and body print nothing and still return 0.
  run_lint "Gate direct-PR pushes behind the local validation gate" "This change runs bin/fm-local-gate.sh before every direct-PR push, so a red gate blocks the push early.
Closes #12"
  expect_lines 0 "clean PR shape"
  expect_code 0 "$RC" "clean PR shape must return 0"

  # Multiple hits print multiple lines, one per hit, still returning 0.
  run_lint "fm-x" "# Definition of done
You are a crewmate: {TASK}"
  expect_lines 4 "multi-hit body"
  expect_code 0 "$RC" "multi-hit shape must return 0"

  # A body that merely mentions the words in prose stays clean: the patterns
  # are anchored to brief/pipeline artifacts, not conversational English.
  run_lint "Explain the delivery contract in docs" "The docs now define the delivery contract wording and an intent section for contributors."
  expect_lines 0 "prose false-positive"
  pass "fm_pr_body_lint: clean shapes stay silent, multi-hits stack, return 0 always"
}

test_each_pattern_fires_its_exact_line
test_clean_and_multi_hit_shapes
