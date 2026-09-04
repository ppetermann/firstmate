#!/usr/bin/env bash
# tests/fm-promote.test.sh - behavior tests for bin/fm-promote.sh's ship
# instructions and steer emission.
#
# Promotion must flip kind= AND publish the ship delivery contract to
# data/<id>/ship-instructions.md (a relaunched promoted task's crewmate reads
# them, and a scout brief forbids pushing), emit a single-line ready-to-send
# steer that delivers those instructions, refuse a second promotion, and
# succeed even when no scout brief was ever scaffolded, since the published
# instructions never depend on one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-promote-tests)

make_case() {  # <name> <id>
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data"
  printf 'window=test:fm-%s\nkind=scout\n' "$id" > "$dir/home/state/$id.meta"
  FM_HOME="$dir/home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "could not scaffold a scout brief for the promotion fixture"
  # A scaffold still carrying its placeholders is refused by bin/fm-dod-lib.sh,
  # so fill the Task subsections the way firstmate does before dispatch.
  perl -0pi -e 's/\{TASK\}/investigate the reported fault/; s/\{FIRSTMATE_SPEC\}/Reproduce it, then report./' \
    "$dir/home/data/$id/brief.md" \
    || fail "could not fill the scout brief placeholders"
  printf '%s\n' "$dir"
}

run_promote() {  # <dir> <id> <mode> -> OUT, RC, ERR
  local dir=$1 id=$2 mode=$3
  OUT=$(env FM_HOME="$dir/home" "$PROMOTE" "$id" --mode "$mode" --yolo off 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

test_promotion_records_ship_contract_in_instructions() {
  local dir id instructions first_contract
  id=promote-contract
  dir=$(make_case promote-contract "$id")
  instructions="$dir/home/data/$id/ship-instructions.md"
  run_promote "$dir" "$id" direct-PR
  expect_code 0 "$RC" "promotion to direct-PR must succeed"
  assert_grep 'kind=ship' "$dir/home/state/$id.meta" "meta kind= was not flipped to ship"
  assert_grep 'mode=direct-PR' "$dir/home/state/$id.meta" "meta mode= was not recorded"
  assert_grep 'yolo=off' "$dir/home/state/$id.meta" "meta yolo= was not recorded"
  assert_present "$instructions" "promotion published no ship-instructions.md"
  assert_grep 'pwd -P' "$instructions" \
    "ship instructions do not tell the worker to verify its worktree"
  assert_grep 'git rev-parse --show-toplevel' "$instructions" \
    "ship instructions do not tell the worker to verify its repository root"
  assert_grep 'These ship instructions supersede the scout delivery rules' "$instructions" \
    "ship instructions do not declare their supersession"
  assert_grep "Inventory this worktree's scratch state" "$instructions" \
    "ship instructions lost the scratch-inventory instruction"
  assert_grep 'Delivery contract: mode=direct-PR' "$instructions" \
    "ship instructions do not carry the ship delivery contract"
  assert_grep 'Run the local gate before pushing' "$instructions" \
    "ship instructions do not carry the mode-specific gate line"
  # fm-spawn.sh reads the FIRST `Delivery contract: mode=` line in a brief; the
  # published ship instructions are a separate delivered payload, so they only
  # need to carry exactly one contract line.
  first_contract=$(sed -n 's/^Delivery contract: mode=\(.*\)$/\1/p' "$instructions" | head -1)
  [ "$first_contract" = direct-PR ] \
    || fail "the published contract line reads '$first_contract', not direct-PR"
  # The steer is one ready-to-send line delivering the published instructions.
  [ "$(printf '%s\n' "$OUT" | grep -c '^next: ')" -eq 1 ] \
    || fail "promotion did not emit exactly one next: line"
  printf '%s\n' "$OUT" | grep '^next: ' | grep -F "data/$id/ship-instructions.md" >/dev/null \
    || fail "the next: line does not deliver the published ship instructions"
  # A second promotion is refused: the task is no longer a scout.
  run_promote "$dir" "$id" direct-PR
  expect_code 1 "$RC" "a second promotion must be refused"
  assert_contains "$ERR" "not a scout task" "re-promotion error must name the scout check"
  pass "fm-promote: publishes the ship contract in ship-instructions.md and emits the send-ready steer"
}

# Upstream 28fb5ac made a promoted worker's `--intent` the captain's own words,
# carried out of the scout brief's `## Captain's intent`. With no brief there are
# no captain words to carry, so promotion now refuses instead of publishing a ship
# contract with an empty intent - superseding this fork's earlier tolerance, which
# predates that contract. The task record must survive the refusal untouched.
test_promotion_refuses_a_missing_brief_and_records_every_mode() {
  local dir id brief instructions
  id=promote-nobrief
  dir=$(make_case promote-nobrief "$id")
  brief="$dir/home/data/$id/brief.md"
  instructions="$dir/home/data/$id/ship-instructions.md"
  rm -f "$brief"
  run_promote "$dir" "$id" local-only
  [ "$RC" -ne 0 ] || fail "promotion without a scout brief must refuse, not invent an empty intent"
  printf '%s\n' "$ERR" | grep -F 'before promotion' >/dev/null \
    || fail "the refusal did not name the missing brief content: $ERR"
  assert_grep 'kind=scout' "$dir/home/state/$id.meta" "a refused promotion must leave the task a scout"
  assert_absent "$instructions" "a refused promotion must publish no ship instructions"

  id=promote-lo
  dir=$(make_case promote-lo "$id")
  instructions="$dir/home/data/$id/ship-instructions.md"
  run_promote "$dir" "$id" local-only
  expect_code 0 "$RC" "promotion to local-only must succeed"
  assert_grep 'Delivery contract: mode=local-only' "$instructions" \
    "local-only ship instructions do not carry their contract"
  assert_grep 'Do NOT push, do NOT open a PR, do NOT merge' "$instructions" \
    "local-only ship instructions lost their no-remote contract"

  id=promote-retired
  dir=$(make_case promote-retired "$id")
  instructions="$dir/home/data/$id/ship-instructions.md"
  run_promote "$dir" "$id" no-mistakes
  [ "$RC" -ne 0 ] || fail "promotion to the retired no-mistakes mode must refuse"
  printf '%s\n' "$ERR" | grep -F 'must be one of direct-PR, local-only' >/dev/null \
    || fail "the retired-mode refusal did not name the accepted modes: $ERR"
  assert_absent "$instructions" "a refused promotion must publish no ship instructions"
  pass "fm-promote: refuses a missing scout brief and a retired mode, and records every live mode's contract"
}

test_promotion_records_ship_contract_in_instructions
test_promotion_refuses_a_missing_brief_and_records_every_mode
