#!/usr/bin/env bash
# tests/fm-pr-state.test.sh - behavior tests for bin/fm-pr-state.sh.
#
# A fake gh on PATH serves canned GitHub payloads (passing/failing/pending
# rollups, review verdicts, draft, merged); a fake glab serves the minimal
# GitLab state read. Covers the three-valued ready rule, the shared checks
# collapse, task-id resolution through the recorded pr= identity, the
# no-PR-recorded and malformed-argument refusals, loud UNKNOWN failures,
# and the --json shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATE_TOOL="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(dirname "$(command -v jq)") || fail "jq is required to test fm-pr-state"

make_case() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/home/state"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" --json "*)
    [ "${FM_TEST_GH_RC:-0}" = 0 ] || exit 1
    cat "${FM_TEST_GH_JSON:?}"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" --output json "*)
    [ "${FM_TEST_GLAB_RC:-0}" = 0 ] || exit 1
    cat "${FM_TEST_GLAB_JSON:?}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/glab"
  printf '%s\n' "$dir"
}

GH_URL=https://github.com/acme/widgets/pull/42

write_gh() {  # <file> <state> <draft> <review> <rollup-json>
  printf '{"state":"%s","isDraft":%s,"headRefOid":"0123456789abcdef0123456789abcdef01234567","reviewDecision":%s,"statusCheckRollup":%s}\n' \
    "$2" "$3" "$4" "$5" > "$1"
}

run_state() {  # <dir> <arg> [tool flags / extra env assignments] -> OUT, RC
  local dir=$1 arg=$2 a tool_args='' env_args=''
  shift 2
  for a in "$@"; do
    case $a in
      --json) tool_args="$tool_args $a" ;;
      *) env_args="$env_args $a" ;;
    esac
  done
  # shellcheck disable=SC2086  # fixture paths carry no spaces; both lists are controlled
  OUT=$(env PATH="$dir/fakebin:$JQ_DIR:$BASE_PATH" FM_HOME="$dir/home"$env_args "$STATE_TOOL" "$arg"$tool_args 2>"$dir/err")
  RC=$?
}

test_ready_rule_over_github_payloads() {
  local dir
  dir=$(make_case ready-rule)

  write_gh "$dir/passing-approved.json" OPEN false '"APPROVED"' \
    '[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/passing-approved.json"
  expect_code 0 "$RC" "approved passing verdict must succeed"
  assert_contains "$OUT" "state=OPEN checks=passing review=APPROVED draft=no" "verdict fields"
  assert_contains "$OUT" "head=0123456789abcdef0123456789abcdef01234567" "verdict head"
  assert_contains "$OUT" "ready=yes reason=ci green and review approved" "ready=yes verdict"

  write_gh "$dir/passing-noreview.json" OPEN false 'null' \
    '[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/passing-noreview.json"
  expect_code 0 "$RC" "no-review verdict must succeed"
  assert_contains "$OUT" "ready=checks" "ci-green no-review must be ready=checks"
  assert_contains "$OUT" "reason=ci green, no review verdict - check whether this repo has a binding reviewer" "no-review reason"

  write_gh "$dir/pending.json" OPEN false '"APPROVED"' \
    '[{"status":"IN_PROGRESS"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/pending.json"
  expect_code 0 "$RC" "pending verdict must succeed"
  assert_contains "$OUT" "checks=pending" "pending rollup collapse"
  assert_contains "$OUT" "ready=no reason=checks pending" "pending must fail on checks"

  write_gh "$dir/changes.json" OPEN false '"CHANGES_REQUESTED"' \
    '[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/changes.json"
  expect_code 0 "$RC" "changes-requested verdict must succeed"
  assert_contains "$OUT" "ready=no reason=review CHANGES_REQUESTED" "changes-requested must fail on review"

  write_gh "$dir/draft.json" OPEN true '"APPROVED"' \
    '[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/draft.json"
  expect_code 0 "$RC" "draft verdict must succeed"
  assert_contains "$OUT" "draft=yes" "draft flag must render"
  assert_contains "$OUT" "ready=no reason=draft" "draft must fail on draft"

  write_gh "$dir/merged.json" MERGED false '"APPROVED"' '[]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/merged.json"
  expect_code 0 "$RC" "merged verdict must succeed"
  assert_contains "$OUT" "state=MERGED checks=none" "merged state and empty rollup"
  assert_contains "$OUT" "ready=no reason=already merged" "merged must not be ready"

  # Rollup edges through the shared collapse: CANCELLED is failing.
  write_gh "$dir/cancelled.json" OPEN false '"none"' \
    '[{"status":"COMPLETED","conclusion":"CANCELLED"}]'
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/cancelled.json"
  expect_code 0 "$RC" "cancelled verdict must succeed"
  assert_contains "$OUT" "checks=failing" "cancelled conclusion must collapse to failing"
  pass "fm-pr-state: three-valued ready over GitHub payloads and rollup edges"
}

test_argument_resolution_and_failures() {
  local dir
  dir=$(make_case resolution)

  # A task id resolves through the recorded canonical pr= in the meta.
  printf 'kind=ship\npr=%s\nmode=direct-PR\n' "$GH_URL" > "$dir/home/state/task-a.meta"
  write_gh "$dir/passing-approved.json" OPEN false '"APPROVED"' \
    '[{"status":"COMPLETED","conclusion":"SUCCESS"}]'
  run_state "$dir" task-a FM_TEST_GH_JSON="$dir/passing-approved.json"
  expect_code 0 "$RC" "task-id resolution must succeed"
  assert_contains "$OUT" "pr=$GH_URL" "task-id verdict must carry the recorded url"
  assert_contains "$OUT" "ready=yes" "task-id verdict ready"

  # A meta without pr= refuses before any forge call.
  printf 'kind=ship\nmode=local-only\n' > "$dir/home/state/task-b.meta"
  run_state "$dir" task-b FM_TEST_GH_JSON="$dir/passing-approved.json"
  expect_code 1 "$RC" "no-PR meta must exit 1"
  assert_contains "$OUT" "pr=- state=UNKNOWN ready=no" "no-PR verdict shape"
  assert_contains "$OUT" "no PR recorded for task task-b" "no-PR reason names the task"

  # A malformed argument is a usage error.
  run_state "$dir" "not-a-url-or-id" FM_TEST_GH_JSON="$dir/passing-approved.json"
  expect_code 2 "$RC" "malformed argument must exit 2"

  # A failing forge read is loud: UNKNOWN shape, exit 1.
  run_state "$dir" "$GH_URL" FM_TEST_GH_JSON="$dir/passing-approved.json" FM_TEST_GH_RC=1
  expect_code 1 "$RC" "gh failure must exit 1"
  assert_contains "$OUT" "state=UNKNOWN ready=no" "gh failure verdict shape"
  assert_contains "$OUT" "reason=gh pr view failed" "gh failure reason"

  # --json emits the collapsed object.
  run_state "$dir" "$GH_URL" --json FM_TEST_GH_JSON="$dir/passing-approved.json"
  expect_code 0 "$RC" "--json flag must succeed"
  printf '%s' "$OUT" | jq -e '.pr and .state and .checks and .review and .draft and .head and .ready and .reason' >/dev/null 2>&1 \
    || fail "--json shape must parse with all fields: $OUT"
  [ "$(printf '%s' "$OUT" | jq -r .ready)" = yes ] || fail "--json ready must be yes"

  # GitLab: minimal state-only read via glab.
  printf '{"state":"opened","draft":false}\n' > "$dir/glab.json"
  run_state "$dir" https://gitlab.com/acme/group/widgets/-/merge_requests/7 FM_TEST_GLAB_JSON="$dir/glab.json"
  expect_code 0 "$RC" "gitlab minimal read must succeed"
  assert_contains "$OUT" "state=opened checks=unknown review=unknown ready=no" "gitlab minimal shape"
  assert_contains "$OUT" "fm-pr-merge.sh owns the full pre-merge battery" "gitlab reason points at the merge battery"

  # GitLab without glab installed is loud.
  mv "$dir/fakebin/glab" "$dir/glab.hidden"
  run_state "$dir" https://gitlab.com/acme/group/widgets/-/merge_requests/7 FM_TEST_GLAB_JSON="$dir/glab.json"
  expect_code 1 "$RC" "missing glab must exit 1"
  assert_contains "$OUT" "state=UNKNOWN ready=no reason=glab not found" "missing glab verdict"
  pass "fm-pr-state: task-id resolution, refusals, loud failures, json shape, gitlab minimal read"
}

test_ready_rule_over_github_payloads
test_argument_resolution_and_failures
