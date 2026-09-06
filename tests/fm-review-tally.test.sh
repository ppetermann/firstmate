#!/usr/bin/env bash
# Behavior tests for the review tally (bin/fm-review-tally.sh).
#
# The network is stubbed with a fakebin `gh` that dispatches on the request
# path: anything containing `graphql` answers the PR fixture, a commit path
# answers that commit's file list, its `/check-runs` sibling answers the
# ocr-review conclusion, and `search/issues` answers the merged-PR count. A
# `fail` marker in the fixture directory makes every call print one stderr line
# and exit 1, and a `fail-commits` marker fails only the per-commit reads that
# run after the PR query has already succeeded. Both drive the fail-closed
# path. No GitHub network call is ever made.
#
# Each case asserts the recorded TSV columns by name, and one case pins the
# exact header line, so a column reorder is caught as well as a wrong count.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-review-tally-tests)

PR_URL=https://github.com/ppetermann/eve-members/pull/134
PR2_URL=https://github.com/ppetermann/eve-members/pull/137
EXPECTED_HEADER='recorded_at	repo	pr	merged_at	regime	bot_rounds	bot_findings	bot_blocking	bot_unique_acted	bot_rejected	cr_findings	cr_blocking	cr_unique_acted	cr_unique_acted_on_bot_approved	cr_rejected	judged	note'

# --- fixture world ----------------------------------------------------------

make_fake_gh() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
fix="${TALLY_FIX:?}"
if [ -f "$fix/fail" ]; then
  head -n 1 "$fix/fail" >&2
  exit 1
fi
[ -n "${TALLY_GH_LOG:-}" ] && echo "$*" >> "$TALLY_GH_LOG"
case "$*" in
  *graphql*) cat "$fix/graphql.json" ;;
  *search/issues*) cat "$fix/search.json" ;;
  *)
    path=
    for a in "$@"; do
      case "$a" in repos/*/commits/*) path=$a ;; esac
    done
    [ -n "$path" ] || { echo "fake gh: unroutable request: $*" >&2; exit 1; }
    if [ -f "$fix/fail-commits" ]; then
      head -n 1 "$fix/fail-commits" >&2
      exit 1
    fi
    rest=${path#*/commits/}
    case "$rest" in
      */check-runs*) cat "$fix/checks-${rest%%/*}.json" ;;
      *) cat "$fix/commit-$rest.json" ;;
    esac
    ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/fix" "$home/data"
  printf '{"total_count":5}\n' > "$home/fix/search.json"
}

run_tally() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" TALLY_FIX="$home/fix" \
    TALLY_GH_LOG="${TALLY_GH_LOG:-}" "$ROOT/bin/fm-review-tally.sh" "$@"
}

# commit_node <oid> <committedDate>
commit_node() {
  printf '{"commit":{"oid":"%s","committedDate":"%s"}}' "$1" "$2"
}

# set_commit <home> <sha> <filename>...
set_commit() {
  local home=$1 sha=$2 files='' sep='' f
  shift 2
  for f in "$@"; do
    files="$files$sep{\"filename\":\"$f\"}"
    sep=','
  done
  printf '{"files":[%s]}\n' "$files" > "$home/fix/commit-$sha.json"
}

# set_check <home> <sha> <conclusion|none>
set_check() {
  local home=$1 sha=$2 conclusion=$3
  if [ "$conclusion" = none ]; then
    printf '{"total_count":0,"check_runs":[]}\n' > "$home/fix/checks-$sha.json"
  else
    printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"%s","completed_at":"2026-09-05T10:30:00Z"}]}\n' \
      "$conclusion" > "$home/fix/checks-$sha.json"
  fi
}

# thread <login> <path> <line-json> <oc-oid> <oc-date> <createdAt> <body> [isResolved] [resolvedBy-json]
thread() {
  printf '{"isResolved":%s,"isOutdated":false,"resolvedBy":%s,"comments":{"nodes":[{"author":{"login":"%s"},"path":"%s","originalLine":%s,"originalCommit":{"oid":"%s","committedDate":"%s"},"createdAt":"%s","body":"%s"}]}}' \
    "${8:-false}" "${9:-null}" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# set_graphql <home> <mergedAt-json> <threads-json> <commits-json>
set_graphql() {
  printf '{"data":{"repository":{"pullRequest":{"mergedAt":%s,"headRefOid":"bbb222","reviewThreads":{"nodes":[%s]},"commits":{"nodes":[%s]}}}}}\n' \
    "$2" "$3" "$4" > "$1/fix/graphql.json"
}

# The shared two-commit world: aaa111 touches y.ts and carries a successful
# ocr-review run; bbb222 lands two hours later and touches x.ts.
set_two_commit_world() {
  local home=$1
  set_commit "$home" aaa111 y.ts
  set_commit "$home" bbb222 x.ts
  set_check "$home" aaa111 success
  set_check "$home" bbb222 none
}

COMMITS_AB='{"commit":{"oid":"aaa111","committedDate":"2026-09-05T10:00:00Z"}},{"commit":{"oid":"bbb222","committedDate":"2026-09-05T12:00:00Z"}}'

cr_x10() {
  thread coderabbitai x.ts 10 aaa111 2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
    '🟠 **Major**: this repair can run against a stale snapshot'
}

# tally_col <home> <pr> <column-name>
tally_col() {
  awk -F'\t' -v pr="$2" -v name="$3" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == name) idx = i; next }
    $3 == pr { print $idx }
  ' "$1/data/review-tally.tsv"
}

assert_col() {
  local home=$1 pr=$2 name=$3 want=$4 got
  got=$(tally_col "$home" "$pr" "$name")
  [ "$got" = "$want" ] || fail "$name for #$pr: expected '$want', got '$got'"
}

# ---------------------------------------------------------------------------

test_unique_coderabbit_finding_on_an_approved_head() {
  local home fakebin out rc
  home="$TMP_ROOT/case1"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL"); rc=$?
  expect_code 0 "$rc" "record exit"
  assert_contains "$out" "1 cr x.ts:10 @aaa111 sev=medium acted=y bot_approved=y" \
    "record must print the candidate it is about to count"
  [ "$(head -n 1 "$home/data/review-tally.tsv")" = "$EXPECTED_HEADER" ] \
    || fail "the TSV header must carry the specified columns in order"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 cr_unique_acted 1
  assert_col "$home" 134 cr_unique_acted_on_bot_approved 1
  assert_col "$home" 134 bot_rounds 1
  assert_col "$home" 134 regime once-after-bot
  assert_col "$home" 134 merged_at 2026-09-06T09:00:00Z
  pass "a CodeRabbit finding the bot never raised, acted on after an approved head, counts"
}

test_nearby_bot_finding_makes_the_thread_shared() {
  local home fakebin threads
  home="$TMP_ROOT/case2"; make_home "$home"
  set_two_commit_world "$home"
  threads="$(cr_x10),$(thread firstmate-ocr-review x.ts 18 aaa111 2026-09-05T10:00:00Z \
    2026-09-05T10:30:00Z '_bug_ | _medium_ | the same class one gate later')"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 bot_findings 1
  assert_col "$home" 134 cr_unique_acted 0
  assert_col "$home" 134 bot_unique_acted 0
  assert_col "$home" 134 bot_blocking 1
  assert_col "$home" 134 cr_blocking 1
  pass "the same path within fifteen lines makes both findings shared, not unique"
}

test_unacted_resolved_by_a_human_is_rejected() {
  local home fakebin
  home="$TMP_ROOT/case3"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' \
    "$(thread coderabbitai z.ts 4 aaa111 2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
       '🟡 Minor: consider renaming' true '{"login":"ppetermann"}')" \
    "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 cr_rejected 1
  assert_col "$home" 134 cr_unique_acted 0
  assert_col "$home" 134 cr_blocking 0
  pass "a finding nobody acted on that a human resolved counts as rejected"
}

test_judgement_excludes_a_candidate_and_rejects_a_bad_verdict() {
  local home fakebin out rc
  home="$TMP_ROOT/case4"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" --judge 1=declined >/dev/null \
    || fail "a judged record must succeed"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 cr_unique_acted 0
  assert_col "$home" 134 judged 1=declined
  out=$(run_tally "$home" "$fakebin" record "$PR_URL" --judge 1=bogus 2>&1); rc=$?
  expect_code 2 "$rc" "bogus verdict exit"
  assert_contains "$out" "unknown judgement verdict: bogus" "a bad verdict must be a usage error"
  out=$(run_tally "$home" "$fakebin" record "$PR_URL" --judge 4=dup 2>&1); rc=$?
  expect_code 2 "$rc" "out-of-range judgement exit"
  assert_contains "$out" "--judge 4 has no candidate" "a judgement with no candidate must be refused"
  pass "a declined judgement drops the candidate; a bad verdict and a judgement with no candidate are refused"
}

test_re_recording_replaces_the_line() {
  local home fakebin lines headers
  home="$TMP_ROOT/case5"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "first record must succeed"
  run_tally "$home" "$fakebin" record "$PR_URL" --judge 1=dup --note "second pass" >/dev/null \
    || fail "second record must succeed"
  lines=$(awk -F'\t' '$3 == "134"' "$home/data/review-tally.tsv" | wc -l | tr -d ' ')
  [ "$lines" = 1 ] || fail "re-recording must replace the PR's line (found $lines)"
  headers=$(grep -c '^recorded_at	' "$home/data/review-tally.tsv")
  [ "$headers" = 1 ] || fail "the file must carry exactly one header line (found $headers)"
  assert_col "$home" 134 judged 1=dup
  assert_col "$home" 134 note "second pass"
  assert_col "$home" 134 cr_unique_acted 0
  pass "recording the same PR twice replaces its line and keeps one header"
}

test_summary_totals_rates_and_coverage() {
  local home fakebin out
  home="$TMP_ROOT/case6"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "first record must succeed"
  set_graphql "$home" '"2026-09-06T11:00:00Z"' '' "$COMMITS_AB"
  run_tally "$home" "$fakebin" record "$PR2_URL" >/dev/null || fail "second record must succeed"
  out=$(run_tally "$home" "$fakebin" summary) || fail "summary must succeed"
  assert_contains "$out" \
    "repo ppetermann/eve-members: prs=2 cr_findings=1 cr_unique_acted=1 cr_unique_acted_on_bot_approved=1 cr_rejected=0 bot_findings=0 bot_blocking=0 bot_unique_acted=0 bot_rejected=0" \
    "summary must sum the repo's recorded PRs"
  assert_contains "$out" "total: prs=2 cr_findings=1 cr_unique_acted=1" "summary must print a total line"
  assert_contains "$out" "cr_unique_per_pr=0.50" "summary must print the CodeRabbit rate per PR"
  assert_contains "$out" "bot_unique_per_pr=0.00" "summary must print the bot rate per PR"
  assert_not_contains "$out" "coverage " "coverage needs --since"
  out=$(run_tally "$home" "$fakebin" summary --since 2026-09-01) || fail "summary --since must succeed"
  assert_contains "$out" "coverage ppetermann/eve-members: recorded=2 merged=5" \
    "--since must print the coverage line that makes a lapse visible"
  pass "summary sums per repo and in total, prints both rates, and reports coverage"
}

test_open_pr_is_refused_without_allow_open() {
  local home fakebin out rc
  home="$TMP_ROOT/case7"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" null "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL" 2>&1); rc=$?
  expect_code 2 "$rc" "unmerged record exit"
  assert_contains "$out" "is not merged" "an unmerged PR must say why it is refused"
  assert_absent "$home/data/review-tally.tsv" "a refused record must write nothing"
  run_tally "$home" "$fakebin" record "$PR_URL" --allow-open >/dev/null \
    || fail "--allow-open must record an unmerged PR"
  assert_col "$home" 134 merged_at -
  assert_col "$home" 134 cr_unique_acted 1
  pass "an unmerged PR is refused unless --allow-open, and then records with no merge date"
}

test_a_failed_read_writes_nothing() {
  local home fakebin out rc before after
  home="$TMP_ROOT/case8"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL" 2>&1); rc=$?
  expect_code 0 "$rc" "healthy record exit"
  before=$(cat "$home/data/review-tally.tsv")
  printf 'gh: HTTP 401 Bad credentials\n' > "$home/fix/fail"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed read must exit non-zero"
  assert_contains "$out" "gh: HTTP 401 Bad credentials" "the first error line must be reported"
  after=$(cat "$home/data/review-tally.tsv")
  [ "$before" = "$after" ] || fail "a failed read must leave the tally unchanged"
  rm -f "$home/fix/fail"
  printf 'gh: HTTP 502 Bad gateway\n' > "$home/fix/fail-commits"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a commit read that fails after the PR query must exit non-zero"
  assert_contains "$out" "gh: HTTP 502 Bad gateway" "the commit read's error line must be reported"
  after=$(cat "$home/data/review-tally.tsv")
  [ "$before" = "$after" ] || fail "a failed commit read must leave the tally unchanged"
  pass "a failed GitHub read reports its first error line and writes nothing"
}

test_a_null_line_is_never_shared() {
  local home fakebin out threads
  home="$TMP_ROOT/case9"; make_home "$home"
  set_two_commit_world "$home"
  threads="$(thread coderabbitai x.ts null aaa111 2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
    '🟠 Major: the file-level concern'),$(thread firstmate-ocr-review x.ts 10 aaa111 \
    2026-09-05T10:00:00Z 2026-09-05T10:30:00Z '_bug_ | _high_ | a line-anchored concern')"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" candidates "$PR_URL") || fail "candidates must succeed"
  assert_contains "$out" "cr x.ts:- @aaa111 sev=medium acted=y bot_approved=y" \
    "a null-line finding must still be printed as a candidate"
  assert_absent "$home/data/review-tally.tsv" "candidates must never write the tally"
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 cr_unique_acted 1
  assert_col "$home" 134 bot_unique_acted 1
  pass "a finding with no line is counted as unique rather than silently shared"
}

test_bot_suffix_is_stripped_from_the_author() {
  local home fakebin
  home="$TMP_ROOT/case10"; make_home "$home"
  set_two_commit_world "$home"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' \
    "$(thread 'firstmate-ocr-review[bot]' x.ts 10 aaa111 2026-09-05T10:00:00Z \
       2026-09-05T11:00:00Z '_bug_ | _high_ | dereferenced after the gate')" \
    "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 bot_findings 1
  assert_col "$home" 134 bot_blocking 1
  assert_col "$home" 134 bot_unique_acted 1
  assert_col "$home" 134 cr_findings 0
  pass "a GitHub App author shown with a [bot] suffix is still the review bot"
}

# The shape the plan's backfill expects on eve-members#134, rebuilt as a
# fixture: two CodeRabbit threads, one of which (the partial-configuration one
# at +page.server.ts:192) is far enough from the bot's low on the same path to
# stay unique, while the config.ts pair eight lines apart is shared. If the
# definitions drift, this case moves before the live backfill does.
test_backfill_shape_from_the_plan() {
  local home fakebin threads commits out
  home="$TMP_ROOT/backfill"; make_home "$home"
  commits="$(commit_node 0983da70000 2026-09-05T10:00:00Z),$(commit_node aa11bb20000 2026-09-05T12:00:00Z),$(commit_node 16cf3cd0000 2026-09-05T14:00:00Z),$(commit_node cc33dd40000 2026-09-05T16:00:00Z)"
  set_commit "$home" 0983da70000
  set_commit "$home" aa11bb20000 docs/operations.md
  set_commit "$home" 16cf3cd0000 src/routes/+page.server.ts src/lib/config.ts
  set_commit "$home" cc33dd40000 src/lib/structure-notifications.ts
  set_check "$home" 0983da70000 success
  set_check "$home" aa11bb20000 failure
  set_check "$home" 16cf3cd0000 failure
  set_check "$home" cc33dd40000 success
  threads="$(thread coderabbitai 'src/routes/+page.server.ts' 192 0983da70000 \
      2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
      '🟠 Major: an enabled-but-partial record passes the strict gate, then throws')"
  threads="$threads,$(thread coderabbitai 'src/lib/config.ts' 51 0983da70000 \
      2026-09-05T10:00:00Z 2026-09-05T11:05:00Z \
      '🟠 Major: deep-normalize wardec before comparing')"
  threads="$threads,$(thread firstmate-ocr-review 'src/routes/+page.server.ts' 61 0983da70000 \
      2026-09-05T09:30:00Z 2026-09-05T09:40:00Z '_nit_ | _low_ | copy the defaults')"
  threads="$threads,$(thread firstmate-ocr-review 'src/lib/config.ts' 43 0983da70000 \
      2026-09-05T09:30:00Z 2026-09-05T09:41:00Z '_bug_ | _medium_ | normalize before comparing')"
  threads="$threads,$(thread firstmate-ocr-review 'src/lib/structure-notifications.ts' 1259 aa11bb20000 \
      2026-09-05T12:00:00Z 2026-09-05T12:10:00Z '_bug_ | _high_ | the scheduler dereferences after the gate')"
  threads="$threads,$(thread firstmate-ocr-review AGENTS.md 27 aa11bb20000 \
      2026-09-05T12:00:00Z 2026-09-05T12:11:00Z '_doc_ | _low_ | the remedy rule is undated')"
  threads="$threads,$(thread firstmate-ocr-review AGENTS.md 32 aa11bb20000 \
      2026-09-05T12:00:00Z 2026-09-05T12:12:00Z '_doc_ | _low_ | enabled is not complete')"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$commits"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL") || fail "record must succeed"
  assert_contains "$out" "cr src/routes/+page.server.ts:192" \
    "the far-apart CodeRabbit finding must be offered for judgement"
  assert_not_contains "$out" "cr src/lib/config.ts:51" \
    "a finding eight lines from the other reviewer's must not be a candidate"
  assert_col "$home" 134 cr_findings 2
  assert_col "$home" 134 cr_unique_acted 1
  assert_col "$home" 134 cr_unique_acted_on_bot_approved 1
  assert_col "$home" 134 bot_findings 5
  assert_col "$home" 134 bot_rounds 4
  pass "the plan's backfill shape reproduces its expected counts"
}

# ---------------------------------------------------------------------------

test_unique_coderabbit_finding_on_an_approved_head
test_nearby_bot_finding_makes_the_thread_shared
test_unacted_resolved_by_a_human_is_rejected
test_judgement_excludes_a_candidate_and_rejects_a_bad_verdict
test_re_recording_replaces_the_line
test_summary_totals_rates_and_coverage
test_open_pr_is_refused_without_allow_open
test_a_failed_read_writes_nothing
test_a_null_line_is_never_shared
test_bot_suffix_is_stripped_from_the_author
test_backfill_shape_from_the_plan
