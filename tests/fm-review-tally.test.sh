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
  fm_fakebin_write "$fakebin/gh" <<'SH'
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

# set_graphql <home> <mergedAt-json> <threads-json> <commits-json> [reviews-json]
set_graphql() {
  printf '{"data":{"repository":{"pullRequest":{"mergedAt":%s,"headRefOid":"bbb222","reviewThreads":{"nodes":[%s]},"reviews":{"nodes":[%s]},"commits":{"nodes":[%s]}}}}}\n' \
    "$2" "$3" "${5:-}" "$4" > "$1/fix/graphql.json"
}

# review <login> <submittedAt> <commit-oid> <commit-date> <body>
review() {
  printf '{"author":{"login":"%s"},"submittedAt":"%s","commit":{"oid":"%s","committedDate":"%s"},"body":"%s"}' \
    "$1" "$2" "$3" "$4" "$5"
}

# cr_body <section-summary> <path> <line-ref> <severity-line> <title>: one
# CodeRabbit review body carrying a single body finding, in the nested
# <summary>/<blockquote> shape the reviewer actually posts, JSON-escaped.
# shellcheck disable=SC2016 # The backticks are literal CodeRabbit markdown.
cr_body() {
  printf '**Actionable comments posted: 0**\\n\\n<details>\\n<summary>%s</summary><blockquote>\\n\\n<details>\\n<summary>%s (1)</summary><blockquote>\\n\\n`%s`: %s\\n\\n**%s**\\n\\nThe prose that explains it.\\n\\n</blockquote></details>\\n\\n</blockquote></details>\\n\\n<details>\\n<summary>ℹ️ Review info</summary><blockquote>\\n\\nRun ID: test\\n\\n</blockquote></details>' \
    "$1" "$2" "$3" "$4" "$5"
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

# The pin world, eve-members#137 in miniature: aaa1110... carries no ocr-review
# run, bbb2220... lands two hours later carrying the only successful one, and
# ccc3330... two hours after that. Both later commits touch x.ts, so the proxy
# credits CodeRabbit's finding to bbb2220... - the push that fixed the bot's own
# finding - and it never reads as having survived an approved head. Passing
# "twin" adds a fourth commit sharing ccc3330...'s first eight characters, so a
# seven-character abbreviation is ambiguous.
set_pin_world() {
  local home=$1 twin=${2:-} commits
  commits="$(commit_node aaa11100000 2026-09-05T10:00:00Z),$(commit_node bbb22200000 2026-09-05T12:00:00Z),$(commit_node ccc33300000 2026-09-05T14:00:00Z)"
  set_commit "$home" aaa11100000 y.ts
  set_commit "$home" bbb22200000 x.ts
  set_commit "$home" ccc33300000 x.ts
  set_check "$home" aaa11100000 none
  set_check "$home" bbb22200000 success
  set_check "$home" ccc33300000 none
  if [ -n "$twin" ]; then
    commits="$commits,$(commit_node ccc33300001 2026-09-05T16:00:00Z)"
    set_commit "$home" ccc33300001 x.ts
    set_check "$home" ccc33300001 none
  fi
  set_graphql "$home" '"2026-09-06T09:00:00Z"' \
    "$(thread coderabbitai x.ts 10 aaa11100000 2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
       '🟠 **Major**: make the repair a compare-and-swap')" \
    "$commits"
}

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

# eve-members#137 in miniature: three findings on one line, one from the bot
# and two distinct ones from CodeRabbit. Pairing is one-to-one, so the bot's
# finding consumes exactly one of them and the other stays unique. Under the
# many-to-one relation this replaced, both vanished.
test_one_counterpart_pairs_with_only_one_finding() {
  local home fakebin out threads crlines
  home="$TMP_ROOT/case11"; make_home "$home"
  set_two_commit_world "$home"
  threads="$(thread firstmate-ocr-review x.ts 10 aaa111 2026-09-05T10:00:00Z \
    2026-09-05T10:30:00Z '_bug_ | _high_ | the shape check throws instead of repairing')"
  threads="$threads,$(thread coderabbitai x.ts 10 aaa111 2026-09-05T10:00:00Z \
    2026-09-05T11:00:00Z '🟠 Major: replace the malformed value instead of throwing')"
  threads="$threads,$(thread coderabbitai x.ts 10 aaa111 2026-09-05T10:00:00Z \
    2026-09-05T11:05:00Z '🟠 Major: make the repair a compare-and-swap')"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$COMMITS_AB"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL") || fail "record must succeed"
  crlines=$(printf '%s\n' "$out" | grep -c ' cr x.ts:10 ')
  [ "$crlines" = 1 ] \
    || fail "exactly one CodeRabbit finding must survive as a candidate (found $crlines)"
  assert_col "$home" 137 cr_findings 2
  assert_col "$home" 137 bot_findings 1
  assert_col "$home" 137 cr_unique_acted 1
  assert_col "$home" 137 bot_unique_acted 0
  pass "one finding pairs with only one of two counterparts on the same line"
}

# Two counterparts equidistant from the same finding: the tie breaks on the
# pair's lower original line, so the same one is consumed whichever order the
# API returns the threads in.
test_equidistant_counterparts_pair_deterministically() {
  local home fakebin out order threads near far
  near="$(thread coderabbitai x.ts 10 aaa111 2026-09-05T10:00:00Z 2026-09-05T11:00:00Z \
    '🟠 Major: the earlier line of the equidistant pair')"
  far="$(thread coderabbitai x.ts 30 aaa111 2026-09-05T10:00:00Z 2026-09-05T11:05:00Z \
    '🟠 Major: the later line of the equidistant pair')"
  for order in low-first high-first; do
    home="$TMP_ROOT/case12-$order"; make_home "$home"
    set_two_commit_world "$home"
    threads="$(thread firstmate-ocr-review x.ts 20 aaa111 2026-09-05T10:00:00Z \
      2026-09-05T10:30:00Z '_bug_ | _high_ | ten lines from either of them')"
    if [ "$order" = low-first ]; then
      threads="$threads,$near,$far"
    else
      threads="$threads,$far,$near"
    fi
    set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$COMMITS_AB"
    fakebin=$(make_fake_gh "$home")
    out=$(run_tally "$home" "$fakebin" candidates "$PR2_URL") \
      || fail "candidates must succeed with the $order fixture"
    assert_not_contains "$out" "cr x.ts:10" \
      "the equidistant pair with the lower original line must be the one consumed ($order)"
    assert_contains "$out" "cr x.ts:30" \
      "the counterpart left unpaired must stay a candidate ($order)"
    assert_not_contains "$out" "bot x.ts:20" \
      "the paired finding must not also be a candidate ($order)"
  done
  pass "an equidistant tie breaks on the lower original line, not on API order"
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

# eve-members#137's undercount in miniature: the bot's own fix commit is the
# first push to touch the file, so the proxy credits CodeRabbit's distinct
# finding to it too and that finding never reads as having survived a head the
# bot had approved. The pin says which push actually fixed it.
test_a_pin_moves_the_acting_commit_and_flips_approval() {
  local home fakebin out
  home="$TMP_ROOT/case13"; make_home "$home"
  set_pin_world "$home"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL") || fail "record must succeed"
  assert_contains "$out" "1 cr x.ts:10 @aaa1110 sev=medium acted=y bot_approved=n" \
    "the proxy must credit the first push that touches the path"
  assert_col "$home" 137 cr_unique_acted 1
  assert_col "$home" 137 cr_unique_acted_on_bot_approved 0
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at 1=ccc3330) \
    || fail "a pinned record must succeed"
  assert_contains "$out" "1 cr x.ts:10 @aaa1110 sev=medium acted=y bot_approved=y" \
    "on_bot_approved must be recomputed against the pinned commit"
  assert_col "$home" 137 cr_unique_acted 1
  assert_col "$home" 137 cr_unique_acted_on_bot_approved 1
  pass "a pin moves a finding's acting commit later and flips it onto a bot-approved head"
}

test_a_pin_round_trips_through_the_judged_column() {
  local home fakebin pinned lines
  home="$TMP_ROOT/case14"; make_home "$home"
  set_pin_world "$home"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at 1=ccc3330 >/dev/null \
    || fail "a pinned record must succeed"
  pinned=$(tally_col "$home" 137 judged)
  [ "$pinned" = "1=acted@ccc3330" ] \
    || fail "the judged column must carry the pin as 1=acted@<sha7> (got '$pinned')"
  run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at "1=${pinned#1=acted@}" >/dev/null \
    || fail "re-recording from the judged column's own value must succeed"
  lines=$(awk -F'\t' '$3 == "137"' "$home/data/review-tally.tsv" | wc -l | tr -d ' ')
  [ "$lines" = 1 ] || fail "re-recording a pinned PR must replace its line (found $lines)"
  assert_col "$home" 137 judged 1=acted@ccc3330
  assert_col "$home" 137 cr_unique_acted_on_bot_approved 1
  pass "a pin is recorded as 1=acted@<sha7> and re-recording from that value reproduces the row"
}

test_a_verdict_and_a_pin_coexist_on_one_candidate() {
  local home fakebin
  home="$TMP_ROOT/case15"; make_home "$home"
  set_pin_world "$home"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR2_URL" --judge 1=declined --acted-at 1=ccc3330 \
    >/dev/null || fail "a record carrying both a verdict and a pin must succeed"
  assert_col "$home" 137 judged '1=declined,1=acted@ccc3330'
  assert_col "$home" 137 cr_findings 1
  assert_col "$home" 137 cr_unique_acted 0
  pass "one candidate carries both its judgement and its pin"
}

test_a_bad_pin_is_refused_and_writes_nothing() {
  local home fakebin out rc
  home="$TMP_ROOT/case16"; make_home "$home"
  set_pin_world "$home" twin
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at 4=ccc33300000 2>&1); rc=$?
  expect_code 2 "$rc" "out-of-range pin exit"
  assert_contains "$out" "--acted-at 4 has no candidate" "a pin with no candidate must be refused"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at 1=deadbee 2>&1); rc=$?
  expect_code 2 "$rc" "unknown commit pin exit"
  assert_contains "$out" "--acted-at 1=deadbee names no commit" \
    "a pin naming no commit of the PR must be refused"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at 1=ccc3330 2>&1); rc=$?
  expect_code 2 "$rc" "ambiguous pin exit"
  assert_contains "$out" "--acted-at 1=ccc3330 is ambiguous" \
    "an abbreviation matching two of the PR's commits must be refused"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" \
    --acted-at 1=ccc33300000 --acted-at 1=bbb22200000 2>&1); rc=$?
  expect_code 2 "$rc" "duplicate pin exit"
  assert_contains "$out" "--acted-at 1 was already given" \
    "the same candidate pinned twice must be refused"
  out=$(run_tally "$home" "$fakebin" record "$PR2_URL" --acted-at ccc33300000 2>&1); rc=$?
  expect_code 2 "$rc" "malformed pin exit"
  assert_contains "$out" "--acted-at needs <n>=<sha>" "a pin with no candidate number must be refused"
  assert_absent "$home/data/review-tally.tsv" "a refused pin must write nothing"
  pass "an unknown candidate, unknown commit, ambiguous abbreviation, duplicate, or malformed pin is refused and writes nothing"
}


# maia#392 in miniature. CodeRabbit's blocking catch arrived in the review BODY
# because the line sits outside the diff, so no thread ever carried it and the
# tally could not see it at all. It must count, keep its own review's commit for
# on_bot_approved, and NOT be absorbed by an unrelated bot thread four lines
# away - the pairing proxy is not evidence of the same defect across a boundary
# the other reviewer could not comment on.
test_a_body_finding_counts_and_is_never_paired() {
  local home fakebin out reviews threads
  home="$TMP_ROOT/case17"; make_home "$home"
  set_two_commit_world "$home"
  threads="$(thread firstmate-ocr-review x.ts 2825 aaa111 2026-09-05T10:00:00Z \
    2026-09-05T10:30:00Z '_other_ | _low_ | a different defect four lines away')"
  reviews="$(review coderabbitai 2026-09-05T11:00:00Z aaa111 2026-09-05T10:00:00Z \
    "$(cr_body '⚠️ Outside diff range comments (1)' x.ts 2821-2821 \
       '_🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_' \
       'Restore focus after URL-driven tab changes.')")"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$threads" "$COMMITS_AB" "$reviews"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL") || fail "record must succeed"
  assert_contains "$out" "cr x.ts:2821 @aaa111 sev=medium acted=y bot_approved=y via=body" \
    "a body finding must surface as a candidate marked via=body"
  assert_contains "$out" "Restore focus after URL-driven tab changes." \
    "the candidate line must carry the body finding's own title"
  assert_contains "$out" "bot x.ts:2825" \
    "the nearby thread must stay a candidate rather than pairing with a body finding"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 cr_blocking 1
  assert_col "$home" 134 cr_unique_acted 1
  assert_col "$home" 134 cr_unique_acted_on_bot_approved 1
  assert_col "$home" 134 cr_rejected 0
  assert_col "$home" 134 bot_unique_acted 1
  pass "a finding delivered in a review body counts, keys to its review's commit, and never pairs"
}

# The body recaps the same reviewer's own inline comments. That recap must not
# be counted a second time against the thread that already carries it.
test_a_body_entry_repeating_its_own_thread_is_dropped() {
  local home fakebin reviews
  home="$TMP_ROOT/case18"; make_home "$home"
  set_two_commit_world "$home"
  reviews="$(review coderabbitai 2026-09-05T11:00:00Z aaa111 2026-09-05T10:00:00Z \
    "$(cr_body '⚠️ Outside diff range comments (1)' x.ts 10-10 \
       '_🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_' \
       'this repair can run against a stale snapshot')")"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' "$(cr_x10)" "$COMMITS_AB" "$reviews"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 cr_unique_acted 1
  pass "a body entry restating the same reviewer's own thread at that path and line is not counted twice"
}

# A nitpick section is the other shape a body finding arrives in, and it is
# where the Trivial tier appears; unparsed it would read "unknown" instead of
# the low it is.
test_a_nitpick_body_finding_maps_trivial_to_low() {
  local home fakebin reviews
  home="$TMP_ROOT/case19"; make_home "$home"
  set_two_commit_world "$home"
  reviews="$(review coderabbitai 2026-09-05T11:00:00Z aaa111 2026-09-05T10:00:00Z \
    "$(cr_body '🧹 Nitpick comments (1)' x.ts 1763-1774 \
       '_📐 Maintainability & Code Quality_ | _🔵 Trivial_ | _⚡ Quick win_' \
       'Complete the ARIA tab pattern on the panels.')")"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' '' "$COMMITS_AB" "$reviews"
  fakebin=$(make_fake_gh "$home")
  run_tally "$home" "$fakebin" record "$PR_URL" >/dev/null || fail "record must succeed"
  assert_col "$home" 134 cr_findings 1
  assert_col "$home" 134 cr_blocking 0
  assert_col "$home" 134 cr_unique_acted 1
  pass "a nitpick body finding counts at the low its Trivial tier means, not as blocking"
}

# The section states its own count. If the parse cannot match it, the vendor
# format moved: refuse loudly instead of recording the undercount, which is the
# failure this whole definition exists to stop.
test_an_unparsable_body_section_refuses_the_record() {
  local home fakebin out rc body reviews
  home="$TMP_ROOT/case20"; make_home "$home"
  set_two_commit_world "$home"
  body=$(cr_body '⚠️ Outside diff range comments (2)' x.ts 2821-2821 \
    '_🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_' \
    'only one of the two the section declares')
  reviews="$(review coderabbitai 2026-09-05T11:00:00Z aaa111 2026-09-05T10:00:00Z "$body")"
  set_graphql "$home" '"2026-09-06T09:00:00Z"' '' "$COMMITS_AB" "$reviews"
  fakebin=$(make_fake_gh "$home")
  out=$(run_tally "$home" "$fakebin" record "$PR_URL" 2>&1); rc=$?
  expect_code 1 "$rc" "unparsable body section exit"
  assert_contains "$out" "the review-body finding format changed" \
    "a declared count the parse cannot match must be reported"
  assert_contains "$out" "declares 2 body finding(s), parsed 1" \
    "the refusal must name the declared and parsed counts"
  assert_absent "$home/data/review-tally.tsv" "a refused parse must write nothing"
  pass "a body finding section whose declared count the parse cannot match refuses the record"
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
test_one_counterpart_pairs_with_only_one_finding
test_equidistant_counterparts_pair_deterministically
test_backfill_shape_from_the_plan
test_a_pin_moves_the_acting_commit_and_flips_approval
test_a_pin_round_trips_through_the_judged_column
test_a_verdict_and_a_pin_coexist_on_one_candidate
test_a_bad_pin_is_refused_and_writes_nothing
test_a_body_finding_counts_and_is_never_paired
test_a_body_entry_repeating_its_own_thread_is_dropped
test_a_nitpick_body_finding_maps_trivial_to_low
test_an_unparsable_body_section_refuses_the_record
