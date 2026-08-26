#!/usr/bin/env bash
# tests/fm-promote.test.sh - behavior tests for bin/fm-promote.sh's brief
# record and steer emission.
#
# Promotion must flip kind= AND append the ship delivery contract to the
# scout's brief (a relaunched promoted task reads its brief, and a scout brief
# forbids pushing), emit a single-line ready-to-send steer naming the brief,
# refuse a second promotion, tolerate a missing brief with a warning, and
# leave the first `Delivery contract: mode=` line exactly where fm-spawn.sh's
# first-match read finds it.
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
  printf '%s\n' "$dir"
}

run_promote() {  # <dir> <id> <mode> -> OUT, RC, ERR
  local dir=$1 id=$2 mode=$3
  OUT=$(env FM_HOME="$dir/home" "$PROMOTE" "$id" --mode "$mode" --yolo off 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

test_promotion_records_ship_contract_in_brief() {
  local dir id brief first_contract
  id=promote-contract
  dir=$(make_case promote-contract "$id")
  brief="$dir/home/data/$id/brief.md"
  run_promote "$dir" "$id" direct-PR
  expect_code 0 "$RC" "promotion to direct-PR must succeed"
  assert_grep 'kind=ship' "$dir/home/state/$id.meta" "meta kind= was not flipped to ship"
  assert_grep 'mode=direct-PR' "$dir/home/state/$id.meta" "meta mode= was not recorded"
  assert_grep 'yolo=off' "$dir/home/state/$id.meta" "meta yolo= was not recorded"
  assert_grep '# Promotion to ship (recorded by fm-promote.sh)' "$brief" \
    "brief gained no promotion heading"
  assert_grep 'supersedes the scout Setup, Rule 1, and Definition of done above' "$brief" \
    "promotion section does not declare its supersession"
  assert_grep 'Inventory scratch state first (git status, git log)' "$brief" \
    "promotion section lost the scratch-inventory instruction"
  assert_grep 'Delivery contract: mode=direct-PR' "$brief" \
    "promotion section does not carry the ship delivery contract"
  assert_grep 'Run the local gate before pushing' "$brief" \
    "promotion section does not carry the mode-specific gate line"
  # fm-spawn.sh reads the FIRST `Delivery contract: mode=` line in the brief;
  # a scout brief contains none, so the appended one must be that first match.
  first_contract=$(sed -n 's/^Delivery contract: mode=\(.*\)$/\1/p' "$brief" | head -1)
  [ "$first_contract" = direct-PR ] \
    || fail "fm-spawn's first-match contract read yields '$first_contract', not direct-PR"
  # The steer is one ready-to-send line naming the brief path.
  [ "$(printf '%s\n' "$OUT" | grep -c '^next: ')" -eq 1 ] \
    || fail "promotion did not emit exactly one next: line"
  printf '%s\n' "$OUT" | grep '^next: ' | grep -F "data/$id/brief.md" >/dev/null \
    || fail "the next: line does not name the brief path"
  # A second promotion is refused: the task is no longer a scout.
  run_promote "$dir" "$id" direct-PR
  expect_code 1 "$RC" "a second promotion must be refused"
  assert_contains "$ERR" "not a scout task" "re-promotion error must name the scout check"
  pass "fm-promote: records the ship contract in the brief and emits the send-ready steer"
}

test_promotion_tolerates_missing_brief_and_other_modes() {
  local dir id brief
  id=promote-nobrief
  dir=$(make_case promote-nobrief "$id")
  brief="$dir/home/data/$id/brief.md"
  rm -f "$brief"
  run_promote "$dir" "$id" local-only
  expect_code 0 "$RC" "promotion without a brief must still succeed"
  assert_contains "$ERR" "warning: no brief at $brief" "missing brief must warn with its path"
  assert_grep 'kind=ship' "$dir/home/state/$id.meta" "meta flip missing without a brief"

  id=promote-nm
  dir=$(make_case promote-nm "$id")
  brief="$dir/home/data/$id/brief.md"
  run_promote "$dir" "$id" no-mistakes
  expect_code 0 "$RC" "promotion to no-mistakes must succeed"
  assert_grep 'Delivery contract: mode=no-mistakes' "$brief" \
    "no-mistakes promotion section does not carry its contract"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'make `--intent` preserve all relevant content' "$brief" \
    "no-mistakes promotion section lost the --intent contract"
  pass "fm-promote: tolerates a missing brief and records every mode's contract"
}

test_promotion_records_ship_contract_in_brief
test_promotion_tolerates_missing_brief_and_other_modes
