#!/usr/bin/env bash
# Behavior tests for bin/fm-effort-ledger.sh: a finished task's dispatch,
# ready, and landed times reach Firstmate's own records through the public
# record command, the stats command summarizes them for planners, and backfill
# recovers what the markdown backlog still knows. Each case builds a private
# Firstmate home, a real markdown backlog driven by the installed tasks-axi,
# and a fake gh that answers one PR's createdAt and mergedAt.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-effort-ledger)
LEDGER_CMD="$ROOT/bin/fm-effort-ledger.sh"
DISPATCH=1792900000

iso() {  # <epoch>
  TZ=UTC0 date -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC0 date -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# make_case <name>: echo a case dir holding a Firstmate home (home/state,
# home/data with a markdown backlog) and a fake gh. The fake answers
# `pr view <url> --json createdAt,mergedAt` from FAKE_GH_PRS, one
# "<url> <createdAt> <mergedAt|null>" line per PR, and fails for any other URL.
make_case() {
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/fakebin"
  fm_test_tasks_toml "$d/home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$d/home/data/backlog.md"
  fm_fakebin_write "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] || exit 1
printf '%s\n' "${FAKE_GH_PRS:-}" | while read -r url created merged; do
  [ "$url" = "$3" ] || continue
  if [ "$merged" = null ]; then printf '%s -\n' "$created"; else printf '%s %s\n' "$created" "$merged"; fi
  exit 3
done
[ "$?" = 3 ] && exit 0
exit 1
SH
  chmod +x "$d/fakebin/gh"
  printf '%s\n' "$d"
}

# add_task <case-dir> <id> <kind> <note>: an In flight backlog row with a note.
add_task() {
  local backlog=$1/home/data/backlog.md
  tasks-axi add "$2" "fixture task $2" --kind "$3" --file "$backlog" >/dev/null
  tasks-axi start "$2" --file "$backlog" >/dev/null
  [ -z "$4" ] || tasks-axi update "$2" --body "$4" --file "$backlog" >/dev/null
}

effort() {  # <case-dir> <args...>
  local d=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$d/home" PATH="$d/fakebin:$PATH" \
    "$LEDGER_CMD" "$@"
}

field() {  # <json> <jq-filter>
  printf '%s\n' "$1" | jq -cS "$2"
}

test_record_takes_ready_from_the_pr_and_keeps_the_dispatch_clock_across_a_relaunch() {
  local d out
  d=$(make_case pr)
  add_task "$d" ship-pr ship "direct-PR, yolo off. estimate=45m dispatch-facts at=2026-10-25T05:39:15+0000"
  # spawn_gen is minted again by a relaunch, so it is later than the first
  # status stamp; the clock still starts at the original dispatch.
  fm_write_meta "$d/home/state/ship-pr.meta" \
    "project=/somewhere/projects/widget" "harness=claude" "kind=ship" "mode=direct-PR" \
    "model=opus" "effort=high" "spawn_gen=s$((DISPATCH + 600)).1.2" \
    "pr=https://github.com/o/widget/pull/7"
  printf 'working [at=%s]: setup done\ndone [at=%s]: PR open\n' "$DISPATCH" "$((DISPATCH + 1500))" \
    > "$d/home/state/ship-pr.status"
  FAKE_GH_PRS="https://github.com/o/widget/pull/7 $(iso $((DISPATCH + 1200))) $(iso $((DISPATCH + 3600)))" \
    effort "$d" record ship-pr >/dev/null || fail "record failed for a ship with a PR"
  out=$(tail -1 "$d/home/data/effort-ledger.jsonl")
  assert_equals "\"$(iso "$DISPATCH")\"" "$(field "$out" .dispatched_at)" 'a relaunch does not restart the dispatch clock'
  assert_equals "\"$(iso $((DISPATCH + 1200)))\"" "$(field "$out" .ready_at)" 'ready is when the draft PR opened'
  assert_equals '"pr-opened"' "$(field "$out" .ready_source)" 'the ready source names the PR'
  assert_equals "\"$(iso $((DISPATCH + 3600)))\"" "$(field "$out" .landed_at)" 'landed is the merge'
  assert_equals '"merged"' "$(field "$out" .landed_source)" 'the landed source names the merge'
  assert_equals '45' "$(field "$out" .estimate_min)" 'the backlog estimate is recorded in minutes'
  assert_equals '["widget","ship","direct-PR","claude","opus","high"]' \
    "$(field "$out" '[.project,.kind,.mode,.harness,.model,.effort]')" 'the record names the task context'
  assert_equals 'false' "$(field "$out" .backfill)" 'a recorded task is not a backfill'
  pass 'record takes ready and landed from the PR and keeps the dispatch clock across a relaunch'
}

test_record_without_a_pr_uses_the_done_line_and_teardown_time() {
  local d out before
  d=$(make_case local)
  # No backlog row at all: the estimate is simply unknown.
  fm_write_meta "$d/home/state/ship-local.meta" \
    "project=/p/firstmate" "harness=codex" "kind=ship" "mode=local-only" "spawn_gen=s$DISPATCH.1.2"
  printf 'working [at=%s]: setup\ndone [at=%s]: ready in branch\ndone [at=%s]: again\n' \
    "$((DISPATCH + 60))" "$((DISPATCH + 900))" "$((DISPATCH + 1900))" > "$d/home/state/ship-local.status"
  before=$(date +%s)
  effort "$d" record ship-local >/dev/null || fail "record failed for a local-only ship"
  out=$(tail -1 "$d/home/data/effort-ledger.jsonl")
  assert_equals "\"$(iso "$DISPATCH")\"" "$(field "$out" .dispatched_at)" 'dispatch is the spawn stamp'
  assert_equals "\"$(iso $((DISPATCH + 900)))\"" "$(field "$out" .ready_at)" 'ready is the first done line'
  assert_equals '"done-status"' "$(field "$out" .ready_source)" 'the ready source names the done line'
  assert_equals '"teardown"' "$(field "$out" .landed_source)" 'with no merge, landed is the teardown'
  [ "$(field "$out" '.landed_at | fromdateiso8601')" -ge "$before" ] || fail "landed_at predates the record: $out"
  assert_equals 'null' "$(field "$out" .estimate_min)" 'no estimate is recorded as null'
  pass 'record without a PR takes ready from the first done line and lands at teardown'
}

test_record_takes_a_scout_ready_time_from_its_report() {
  local d out
  d=$(make_case scout)
  add_task "$d" plan scout ""
  fm_write_meta "$d/home/state/plan.meta" "project=/p/widget" "kind=scout" "spawn_gen=s$DISPATCH.1.2"
  mkdir -p "$d/home/data/plan"
  : > "$d/home/data/plan/report.md"
  fm_touch_epoch $((DISPATCH + 700)) "$d/home/data/plan/report.md"
  effort "$d" record plan >/dev/null || fail "record failed for a scout"
  out=$(tail -1 "$d/home/data/effort-ledger.jsonl")
  assert_equals "\"$(iso $((DISPATCH + 700)))\"" "$(field "$out" .ready_at)" 'a scout is ready when its report was written'
  assert_equals '["report","scout"]' "$(field "$out" '[.ready_source,.kind]')" 'the ready source names the report'
  pass 'record takes a scout ready time from its report'
}

test_record_appends_once_per_task_incarnation() {
  local d
  d=$(make_case once)
  fm_write_meta "$d/home/state/t.meta" "kind=ship" "spawn_gen=s$DISPATCH.1.2"
  effort "$d" record t >/dev/null || fail "first record failed"
  assert_equals "already recorded t s$DISPATCH.1.2" "$(effort "$d" record t)" 'a repeat names the existing record'
  assert_equals 1 "$(wc -l < "$d/home/data/effort-ledger.jsonl" | tr -d ' ')" 'a retried cleanup counts the task once'
  pass 'record appends at most once per task incarnation'
}

test_refusals() {
  local d rc
  d=$(make_case refusals)
  set +e
  effort "$d" record missing >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'a task with no record'
  fm_write_meta "$d/home/state/mate.meta" "kind=secondmate"
  set +e
  effort "$d" record mate >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'a secondmate'
  set +e
  effort "$d" record ../t >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" 'an unsafe task id'
  assert_absent "$d/home/data/effort-ledger.jsonl" 'a refused record wrote the ledger'
  set +e
  effort "$d" stats --bogus >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" 'an unknown stats flag'
  pass 'missing tasks, secondmates, unsafe ids, and bad flags are refused'
}

# seed_record <case-dir> <task> <kind> <project> <model> <ready-min> <landed-min> <estimate|null>
seed_record() {
  printf '{"task":"%s","spawn_gen":"g","kind":"%s","project":"%s","model":"%s","dispatched_at":"%s","ready_at":"%s","landed_at":"%s","estimate_min":%s}\n' \
    "$2" "$3" "$4" "$5" "$(iso "$DISPATCH")" "$(iso $((DISPATCH + $6 * 60)))" "$(iso $((DISPATCH + $7 * 60)))" "$8" \
    >> "$1/home/data/effort-ledger.jsonl"
}

test_stats_prints_medians_p90_and_estimate_ratios() {
  local d out
  d=$(make_case stats)
  assert_equals 'effort ledger: no records yet' "$(effort "$d" stats)" 'an absent ledger says it has no records'
  seed_record "$d" a ship widget opus 10 30 20
  seed_record "$d" b ship widget opus 20 40 10
  seed_record "$d" c ship widget fable 30 50 null
  seed_record "$d" d scout widget fable 5 6 null
  seed_record "$d" e ship gadget opus 100 200 null
  out=$(effort "$d" stats) || fail "stats failed"
  printf '%s\n' "$out" | grep -E '^kind +ship +4  25m/100m +45m/200m +1.25x/2.00x$' >/dev/null \
    || fail "ship medians, p90s, or estimate ratios are wrong: $out"
  printf '%s\n' "$out" | grep -E '^kind +scout +1  5m/5m +6m/6m +-$' >/dev/null \
    || fail "a kind with no estimates should show no ratio: $out"
  printf '%s\n' "$out" | grep -E '^project +widget +4 ' >/dev/null || fail "stats has no per-project rows: $out"
  printf '%s\n' "$out" | grep -E '^model +fable +2  18m/30m ' >/dev/null || fail "stats has no per-model rows: $out"
  out=$(effort "$d" stats --project gadget) || fail "filtered stats failed"
  printf '%s\n' "$out" | grep -F 'effort ledger: 1 records' >/dev/null || fail "--project did not filter: $out"
  assert_equals 'effort ledger: no records yet' "$(effort "$d" stats --kind review)" 'a filter with no match has no records'
  pass 'stats prints medians, p90s, and estimate ratios by kind, project, and model'
}

test_backfill_recovers_pr_and_report_times_once() {
  local d out
  d=$(make_case backfill)
  mkdir -p "$d/home/data/old-plan"
  : > "$d/home/data/old-plan/report.md"
  fm_touch_epoch $((DISPATCH + 300)) "$d/home/data/old-plan/report.md"
  cat > "$d/home/data/done-archive.md" <<EOF
# Done archive

- [x] old-ship - widget: build https://github.com/o/widget/pull/9 (repo: o/widget) (kind: ship) (merged 2026-10-01)
  direct-PR. estimate=30m
  dispatch-facts at=$(iso "$DISPATCH" | sed 's/Z$/+0000/') beijing=x
- [x] old-plan - widget: plan (repo: widget) (kind: scout) (reported 2026-10-01)
  dispatch-facts at=$(iso "$DISPATCH" | sed 's/Z$/+0000/') beijing=x
- [x] no-facts - widget: older (repo: widget) (kind: ship) (merged 2026-08-01) https://github.com/o/widget/pull/1
- [x] no-ready - widget: local (repo: widget) (kind: ship) (done 2026-10-01)
  dispatch-facts at=$(iso "$DISPATCH" | sed 's/Z$/+0000/')
EOF
  FAKE_GH_PRS="https://github.com/o/widget/pull/9 $(iso $((DISPATCH + 600))) $(iso $((DISPATCH + 1800)))"
  export FAKE_GH_PRS
  effort "$d" backfill >/dev/null || fail "backfill failed"
  assert_equals '["old-plan","old-ship"]' "$(jq -cs '[.[].task] | sort' "$d/home/data/effort-ledger.jsonl")" \
    'only entries with a dispatch stamp and a recoverable ready time are backfilled'
  out=$(jq -c 'select(.task == "old-ship")' "$d/home/data/effort-ledger.jsonl")
  assert_equals "[\"$(iso "$DISPATCH")\",\"$(iso $((DISPATCH + 600)))\",\"$(iso $((DISPATCH + 1800)))\",30,\"widget\",true]" \
    "$(field "$out" '[.dispatched_at,.ready_at,.landed_at,.estimate_min,.project,.backfill]')" \
    'a backfilled ship takes its times from the forge'
  out=$(jq -c 'select(.task == "old-plan")' "$d/home/data/effort-ledger.jsonl")
  assert_equals "[\"$(iso $((DISPATCH + 300)))\",\"report\",null]" "$(field "$out" '[.ready_at,.ready_source,.landed_at]')" \
    'a backfilled scout takes its ready time from its report'
  effort "$d" backfill >/dev/null || fail "repeated backfill failed"
  assert_equals 2 "$(wc -l < "$d/home/data/effort-ledger.jsonl" | tr -d ' ')" 'a repeated backfill appends nothing'
  unset FAKE_GH_PRS
  pass 'backfill recovers forge and report times from the markdown backlog, once'
}

test_record_takes_ready_from_the_pr_and_keeps_the_dispatch_clock_across_a_relaunch
test_record_without_a_pr_uses_the_done_line_and_teardown_time
test_record_takes_a_scout_ready_time_from_its_report
test_record_appends_once_per_task_incarnation
test_refusals
test_stats_prints_medians_p90_and_estimate_ratios
test_backfill_recovers_pr_and_report_times_once
