#!/usr/bin/env bash
# Behavior tests for fm-stow-plan.sh: per-entry inventory and staleness classes
# under the clocks its header owns, idempotent stamping, atomic archival with
# the exact provenance line, the ordered destination battery, and receipt
# deltas. Every case drives the executable, never the source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLAN="$ROOT/bin/fm-stow-plan.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-plan)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

TODAY=2026-08-26

make_home() {  # <case-dir> <budget>
  local home="$1/home"
  mkdir -p "$home/config" "$home/data"
  printf '%s\n' "$2" > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

run_plan() {  # <home>
  FM_HOME="$1" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" plan
}

row_matches() {  # <output> <egrep-pattern over tab-separated row>
  printf '%s\n' "$1" | grep -Eq "$2"
}

test_plan_reports_every_marker_class_and_its_clocks() {
  local home out
  home=$(make_home "$TMP_ROOT/classes" 100000)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- Fresh aging exercised today. <!--a:2026-08-26-->
- Old aging past its clock. <!--a:2026-07-01-->
- Fresh perishable inside its clock. <!--p:2026-08-20-->
- Stale perishable past its clock. <!--p:2026-08-01-->
- Pinned exemption. <!--P-->
- Grace legacy marker. <!--g-->
- Unmarked legacy entry.
MD
  out=$(run_plan "$home")
  row_matches "$out" $'learnings\.md\t2\ta\t2026-08-26\t0\t0\t[0-9]+\tfresh' \
    || fail "fresh aging row missing or misclassified"
  row_matches "$out" $'learnings\.md\t3\ta\t2026-07-01\t56\t0\t[0-9]+\tstale' \
    || fail "30-day aging clock not applied (age 56 should read stale)"
  row_matches "$out" $'learnings\.md\t4\tp\t2026-08-20\t6\t0\t[0-9]+\tfresh' \
    || fail "7-day perishable clock not applied (age 6 should read fresh)"
  row_matches "$out" $'learnings\.md\t5\tp\t2026-08-01\t25\t0\t[0-9]+\tstale' \
    || fail "stale perishable row missing or misclassified"
  row_matches "$out" $'learnings\.md\t6\tP\t-\t-\t0\t[0-9]+\tpinned' \
    || fail "pinned row missing or misclassified"
  row_matches "$out" $'learnings\.md\t7\tg\t-\t-\t0\t[0-9]+\tgrace' \
    || fail "grace row missing or misclassified"
  row_matches "$out" $'learnings\.md\t8\tunmarked\t-\t-\t0\t[0-9]+\tunmarked' \
    || fail "unmarked row missing or misclassified"
  pass "plan classifies every marker tier under its clock"
}

test_plan_pass_horizon_reads_counters_only_when_opted_in() {
  local home out
  home=$(make_home "$TMP_ROOT/horizon" 100000)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- Counter high, date fresh, no flag. <!--a:2026-08-26/11-->
- Counter high, date fresh, flag on. <!--p:2026-08-26/3-->
MD
  out=$(run_plan "$home")
  row_matches "$out" $'learnings\.md\t2\ta\t2026-08-26\t0\t11\t[0-9]+\tfresh' \
    || fail "a counter was read without the pass-horizon flag"
  : > "$home/config/stow-pass-horizon"
  out=$(run_plan "$home")
  row_matches "$out" $'learnings\.md\t2\ta\t2026-08-26\t0\t11\t[0-9]+\tstale' \
    || fail "aging pass clock (10) not applied with the flag"
  row_matches "$out" $'learnings\.md\t3\tp\t2026-08-26\t0\t3\t[0-9]+\tstale' \
    || fail "perishable pass clock (3) not applied with the flag"
  pass "pass counters gate staleness on the opt-in flag exactly"
}

test_plan_token_estimate_agrees_with_the_lib_estimator() {
  local home out entry
  home=$(make_home "$TMP_ROOT/estimator" 100000)
  entry="- $(head -c 88 /dev/zero | tr '\0' 'x')"
  printf '%s\n%s\n' '# learnings' "$entry" > "$home/data/learnings.md"
  [ "${#entry}" -eq 90 ] || fail "fixture line is ${#entry} bytes, expected 90"
  out=$(run_plan "$home")
  row_matches "$out" $'learnings\.md\t2\tunmarked\t-\t-\t0\t30\tunmarked' \
    || fail "a 90-byte line must estimate 30 tokens (ceil(bytes/3))"
  pass "plan entry tokens agree with ceil(UTF-8 bytes / 3)"
}

test_plan_over_budget_pool_is_ordered_with_convergence_verdict() {
  local home out
  home=$(make_home "$TMP_ROOT/pool" 30)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- Younger stale aging entry. <!--a:2026-07-15-->
- Much older stale aging entry. <!--a:2026-06-01-->
- Fresh entry that is not pool-eligible. <!--a:2026-08-26-->
MD
  out=$(run_plan "$home")
  assert_contains "$out" "must_shed_tokens=" "an over-budget home must name its shed amount"
  row_matches "$out" $'learnings\.md\t3\t2026-06-01\t[0-9]+\t[0-9]+' \
    || fail "the older entry must be listed first in the pool"
  row_matches "$out" $'learnings\.md\t2\t2026-07-15\t[0-9]+\t[0-9]+' \
    || fail "the younger stale entry must be listed second in the pool"
  local first_cum second_cum
  first_cum=$(printf '%s\n' "$out" | awk -F'\t' '$1=="learnings.md" && $3=="2026-06-01" {print $5}')
  second_cum=$(printf '%s\n' "$out" | awk -F'\t' '$1=="learnings.md" && $3=="2026-07-15" {print $5}')
  [ "$first_cum" -gt 0 ] || fail "pool cumulative column must be positive"
  [ "$second_cum" -gt "$first_cum" ] || fail "pool cumulative column must grow oldest-first"
  if printf '%s\n' "$out" | grep -Eq $'learnings\.md\t4\t2026-'; then
    fail "a fresh entry must not enter the eviction pool"
  fi
  local total pool_total budget=30
  total=$(printf '%s\n' "$out" | sed -n 's/^total_estimated_tokens=//p')
  pool_total=$(printf '%s\n' "$out" | sed -n 's/^pool_total_tokens=//p')
  if [ $((total - pool_total)) -le "$budget" ]; then
    assert_contains "$out" "converges=yes" "pool that reaches budget must converge"
  else
    assert_contains "$out" "converges=no" "pool that cannot reach budget must not converge"
  fi
  pass "over-budget plan orders the eviction pool and answers convergence"
}

test_plan_excludes_read_only_shared_entries_from_a_secondmate_pool() {
  local home out
  home=$(make_home "$TMP_ROOT/secondmate-pool" 1)
  touch "$home/.fm-secondmate-home"
  printf '%s\n' '# shared' '- Shared stale entry. <!--a:2026-01-01-->' > "$home/data/captain-shared.md"
  printf '%s\n' '# learnings' '- Local stale entry. <!--a:2026-01-01-->' > "$home/data/learnings.md"
  out=$(run_plan "$home")
  assert_contains "$out" "role=secondmate" "the secondmate role must be reported"
  if printf '%s\n' "$out" | grep -Eq $'captain-shared\.md\t[0-9]+\t2026-'; then
    fail "a secondmate pool must exclude the read-only shared file"
  fi
  row_matches "$out" $'learnings\.md\t2\t2026-01-01\t[0-9]+\t[0-9]+' \
    || fail "the local stale entry must still pool for a secondmate"
  pass "secondmate pools exclude the primary-owned shared file"
}

test_stamp_is_idempotent_and_refuses_non_list_lines() {
  local home path before rc
  home=$(make_home "$TMP_ROOT/stamp" 100000)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- An unmarked entry awaiting its first marker.
MD
  path="$home/data/learnings.md"
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" stamp learnings.md 2 a 2026-08-26 >/dev/null
  before=$(cat "$path")
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" stamp learnings.md 2 a 2026-08-26 >/dev/null
  [ "$(cat "$path")" = "$before" ] || fail "a second identical stamp must be byte-idempotent"
  assert_grep '<!--a:2026-08-26-->' "$path" "the first stamp must have written the marker"
  cp "$path" "$TMP_ROOT/stamp-before-refusal.md"
  set +e
    out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" stamp learnings.md 1 a 2026-08-26 2>&1)
    rc=$?
  set -e
  expect_code 2 "$rc" "stamping a non-list line must refuse"
  assert_contains "$out" "is not a list line" "the refusal must name the wrong line content"
  cmp -s "$path" "$TMP_ROOT/stamp-before-refusal.md" || fail "a refused stamp must leave the file untouched"
  set +e
    out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" stamp learnings.md 2 a 2026-08-26 3 2>&1)
    rc=$?
  set -e
  expect_code 2 "$rc" "a passes value must refuse without the horizon flag"
  assert_contains "$out" "requires config/stow-pass-horizon" "the refusal must name the missing flag"
  touch "$home/config/stow-pass-horizon"
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" stamp learnings.md 2 a 2026-08-26 3 >/dev/null
  assert_grep '<!--a:2026-08-26/3-->' "$path" "a counter marker must be written with the flag"
  pass "stamp is idempotent, writes counters only when opted in, and refuses wrong lines"
}

test_archive_moves_the_entry_with_exact_provenance_atomically() {
  local home path archive expected rc
  home=$(make_home "$TMP_ROOT/archive" 100000)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- Entry kept for the file's shape. <!--a:2026-08-26-->
- Old aging entry that is date-stale. <!--a:2026-07-01-->
MD
  path="$home/data/learnings.md"
  archive="$home/data/memory-archive.md"
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" archive learnings.md 3 >/dev/null
  assert_present "$archive" "the archive must exist after the move"
  assert_grep '- (from learnings.md, tier: aging, reinforced: 2026-07-01) Old aging entry that is date-stale. [archived: unreinforced 56d]' \
    "$archive" "the provenance line must match the cold-tier shape exactly"
  assert_grep "## $TODAY stow" "$archive" "the entry must land under today's dated pass heading"
  assert_no_grep 'Old aging entry that is date-stale.' "$path" "the archived entry must leave its source file"
  assert_grep 'Entry kept for the file' "$path" "a sibling entry must survive the move"
  local leftovers
  leftovers=$(find "$home/data" -name '*.XXXXXX' -o -name '.stow-plan-baseline.tmp' | wc -l)
  [ "$leftovers" -eq 0 ] || fail "atomic write-then-rename must leave no temporary files behind"
  set +e
    out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" archive learnings.md 1 2>&1)
    rc=$?
  set -e
  expect_code 2 "$rc" "archiving a non-list line must refuse"
  assert_contains "$out" "is not a list line" "the refusal must name the wrong line content"
  pass "archive moves one entry to the cold tier with exact provenance and no partial state"
}

test_archive_derives_the_grace_and_counter_reasons() {
  local home archive
  home=$(make_home "$TMP_ROOT/archive-reasons" 100000)
  cat > "$home/data/learnings.md" <<'MD'
# learnings
- Grace entry with no date. <!--g-->
- Counter-stale entry with a fresh date. <!--a:2026-08-26/11-->
MD
  archive="$home/data/memory-archive.md"
  touch "$home/config/stow-pass-horizon"
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" archive learnings.md 2 >/dev/null
  assert_grep '[archived: legacy-unvalidated]' "$archive" "a g entry must archive as legacy-unvalidated"
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" archive learnings.md 2 >/dev/null
  assert_grep '[archived: unreinforced 11p]' "$archive" "the pass horizon must derive the unreinforced-Np reason"
  pass "archive derives legacy and pass-counter reasons per the clock owner"
}

test_check_destination_runs_the_ordered_battery() {
  local root out rc
  fm_git_identity
  fm_git_init_commit "$TMP_ROOT/destroot"
  printf '%s\n' '.agents/skills/private-note/' >> "$TMP_ROOT/destroot/.git/info/exclude"
  mkdir -p "$TMP_ROOT/destroot/.agents/skills"
  set +e
    out=$(FM_HOME="$TMP_ROOT/destroot" "$PLAN" check-destination README.md)
    rc=$?
  set -e
  expect_code 1 "$rc" "a tracked destination must fail the battery"
  assert_contains "$out" "tracked-in-index" "the refusal must name the failing check"
  set +e
    out=$(FM_HOME="$TMP_ROOT/destroot" "$PLAN" check-destination would-be-new.md)
    rc=$?
  set -e
  expect_code 1 "$rc" "an unignored destination must fail the battery"
  assert_contains "$out" "not-ignored" "the refusal must name the failing check"
  out=$(FM_HOME="$TMP_ROOT/destroot" "$PLAN" check-destination .agents/skills/private-note/SKILL.md)
  assert_contains "$out" "safe" "an excluded absent destination must pass every check"
  pass "check-destination answers safe or the named failing check"
}

test_receipt_reports_before_and_after_deltas() {
  local home out
  home=$(make_home "$TMP_ROOT/receipt" 100000)
  printf '%s\n%s\n' '# learnings' '- Entry one. <!--a:2026-08-26-->' > "$home/data/learnings.md"
  run_plan "$home" >/dev/null
  FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" archive learnings.md 2 >/dev/null
  out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" receipt)
  row_matches "$out" 'file=learnings\.md before=[0-9]+ after=[0-9]+ delta=-[0-9]+' \
    || fail "receipt must report the learnings before/after delta"
  row_matches "$out" 'total before=[0-9]+ after=[0-9]+ delta=-[0-9]+' \
    || fail "receipt must report the total delta"
  rm -rf "$home/state"
  out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" receipt)
  row_matches "$out" 'file=learnings\.md before=unavailable after=[0-9]+' \
    || fail "receipt must read unavailable without a plan snapshot"
  pass "receipt prints per-file and total deltas against the plan baseline"
}

test_plan_refuses_an_invalid_budget_rather_than_guessing() {
  local home out rc
  home=$(make_home "$TMP_ROOT/bad-budget" 100000)
  printf 'not-a-number\n' > "$home/config/startup-memory-budget"
  set +e
    out=$(FM_HOME="$home" FM_STOW_PLAN_TODAY=$TODAY "$PLAN" plan 2>&1)
    rc=$?
  set -e
  expect_code 1 "$rc" "an invalid budget must fail the plan"
  assert_contains "$out" "invalid config/startup-memory-budget" "the error must name the config file"
  pass "plan refuses an unsafe budget instead of inferring a default"
}

test_plan_reports_every_marker_class_and_its_clocks
test_plan_pass_horizon_reads_counters_only_when_opted_in
test_plan_token_estimate_agrees_with_the_lib_estimator
test_plan_over_budget_pool_is_ordered_with_convergence_verdict
test_plan_excludes_read_only_shared_entries_from_a_secondmate_pool
test_stamp_is_idempotent_and_refuses_non_list_lines
test_archive_moves_the_entry_with_exact_provenance_atomically
test_archive_derives_the_grace_and_counter_reasons
test_check_destination_runs_the_ordered_battery
test_receipt_reports_before_and_after_deltas
test_plan_refuses_an_invalid_budget_rather_than_guessing
