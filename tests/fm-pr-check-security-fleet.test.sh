#!/usr/bin/env bash
# tests/fm-pr-check-security-fleet.test.sh - this fleet's own PR-check cases,
# driven through the always-draft wrapper bin/fm-pr-draft-check.sh: a task
# worker's own invocation is refused, a draft is recorded, armed and ledgered,
# title/body lint and a direct-PR task's local-gate pass warnings are advisory,
# and a rejected check's durable notice survives a later-sorting check waking
# the same sweep. They live beside
# upstream's tests/fm-pr-check-security.test.sh so a take-in never re-resolves
# them inside it.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-draft-check.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-security-fleet)
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The fixture helpers below are copies of upstream's suite's.
make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/main "$(git -C "$dir/wt" rev-parse HEAD)"
  fm_fakebin_write "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  fm_fakebin_write "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "${GH_HOST:-}" >> "$FM_TEST_GH_LOG"
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' \
      "state=${FM_TEST_GH_GRAPHQL_STATE:-MERGED}" \
      "merged=${FM_TEST_GH_GRAPHQL_MERGED:-true}" \
      "queued=${FM_TEST_GH_GRAPHQL_QUEUED:-false}" \
      'base=main'
    exit 0
    ;;
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' "{\"state\":\"OPEN\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"baseRefName\":\"main\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]}"
        exit 0
        ;;
      *" --json title "*)
        printf '%s\n' "${FM_TEST_GH_TITLE:-}"
        exit 0
        ;;
      *" --json body "*)
        printf '%s\n' "${FM_TEST_GH_BODY:-}"
        exit 0
        ;;
      *" --json isDraft "*)
        printf '%s\n' "{\"isDraft\":${FM_TEST_GH_DRAFT:-false}}"
        exit 0
        ;;
      *headRefOid,reviewDecision*)
        printf '%s\n' "{\"headRefOid\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\",\"reviewDecision\":\"APPROVED\"}"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    [ -z "${FM_TEST_GH_MERGE_HOOK:-}" ] || "$FM_TEST_GH_MERGE_HOOK"
    exit 0
    ;;
esac
case " $* " in
  *" api repos/"*"/issues/"*"/comments?per_page=100 "*|*" api repos/"*"/pulls/"*"/reviews?per_page=100 "*|*" api repos/"*"/pulls/"*"/comments?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api repos/"*"/commits/"*"/check-runs?filter=all&per_page=100 "*)
    printf '%s\n' '[{"check_runs":[]}]'
    ;;
  *" api repos/"*"/commits/"*"/statuses?per_page=100 "*)
    printf '%s\n' '[[]]'
    ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*)
    ;;
  *" api --paginate repos/"*"/rules/branches/"*)
    printf '%s\n' '[]'
    ;;
  *" api repos/"*"/branches/"*)
    printf '%s\n' '{"name":"main","protected":false}'
    ;;
  *" api repos/"*"/pulls/"*)
    printf '%s\n' "{\"state\":\"open\",\"user\":{\"login\":\"author\"},\"head\":{\"sha\":\"${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}\"},\"draft\":false,\"mergeable\":true,\"merged_at\":null}"
    ;;
  *" api repos/"*)
    printf '%s\n' '{"permissions":{"push":false}}'
    ;;
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    [ -z "${FM_TEST_GH_STATE_STARTED:-}" ] || : > "$FM_TEST_GH_STATE_STARTED"
    [ "${FM_TEST_GH_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SLEEP"
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    ;;
esac
SH
  fm_fakebin_write "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit "${FM_TEST_GH_AXI_RC:-0}"
SH
  # Plain glab, reproducing the real CLI's contract: its field output on stdout
  # and exit 0 on success, and a non-zero exit with no stdout on any failure.
  fm_fakebin_write "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
[ "${FM_TEST_GLAB_FAIL:-0}" = 0 ] || exit 1
[ "${FM_TEST_GLAB_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GLAB_SLEEP"
printf 'title:\tfixture merge request\nstate:\t%s\nauthor:\tsomeone\n' "${FM_TEST_GLAB_STATE:-opened}"
SH
  # gerrit-axi, reproducing the real CLI's contract: one JSON record on stdout
  # and exit 0 on success, and a non-zero exit with no stdout on any failure.
  # Its defaults are the real server's readings for an OPEN change, and the
  # submit fields are settable independently of the status so a case can build
  # the reading a merged change and a merely submittable change share.
  fm_fakebin_write "$fakebin/gerrit-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GERRIT_AXI_LOG"
[ "${FM_TEST_GERRIT_FAIL:-0}" = 0 ] || exit 1
if [ -n "${FM_TEST_GERRIT_RAW:-}" ]; then
  printf '%s\n' "$FM_TEST_GERRIT_RAW"
  exit 0
fi
change=${FM_TEST_GERRIT_CHANGE:-${2:-0}}
printf '{"ok":true,"op":"show","count":1,"missing":[],"changes":[{"change":%s,"subject":%s,"project":"p","status":"%s","wip":false,"submit":"%s","submittable":%s,"blocked_on":"%s","patch_set":1,"revision":"%s","url":"%s"}]}\n' \
  "$change" \
  "${FM_TEST_GERRIT_SUBJECT:-\"fixture change\"}" \
  "${FM_TEST_GERRIT_STATUS:-NEW}" \
  "${FM_TEST_GERRIT_SUBMIT:-NOT_READY}" \
  "${FM_TEST_GERRIT_SUBMITTABLE:-false}" \
  "${FM_TEST_GERRIT_BLOCKED_ON:-Code-Review}" \
  "${FM_TEST_GERRIT_REVISION:-5f07a68436929a527ddc7abadc8ef1abceae40ed}" \
  "${FM_TEST_GERRIT_URL:-https://gerrit.example/c/group/apps/console/+/4201}"
SH
  # no-mistakes, answering only `axi status` the way the real CLI does from a
  # worker copy: a run object, then its branch_sync block. By default the run's
  # result is the copy's own passed HEAD and custody is returned; a case
  # overrides the outcome, the pipeline head, the next action, or makes the read
  # fail.
  fm_fakebin_write "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_NM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
[ "${FM_TEST_NM_FAIL:-0}" = 0 ] || exit 1
head=$(git rev-parse HEAD 2>/dev/null) || exit 1
pipeline=${FM_TEST_NM_PIPELINE_HEAD:-$head}
printf 'run:\n  id: "RUNFIXTURE"\n  branch: fm/task\n  status: completed\n  head_sha: %s\noutcome: %s\n' \
  "$pipeline" "${FM_TEST_NM_OUTCOME-passed}"
printf 'branch_sync:\n  state: %s\n  local:\n    head: %s\n  pipeline:\n    current_head: %s\n' \
  "${FM_TEST_NM_SYNC_STATE:-synchronized}" "$head" "$pipeline"
if [ -n "${FM_TEST_NM_NEXT_ACTION:-}" ]; then
  printf '  next_action:\n    code: %s\n    command: no-mistakes axi status\n' "$FM_TEST_NM_NEXT_ACTION"
fi
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/glab" "$fakebin/gerrit-axi"
  chmod +x "$fakebin/no-mistakes"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  : > "$dir/glab.log"
  : > "$dir/gerrit-axi.log"
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    FM_TEST_GERRIT_AXI_LOG="$dir/gerrit-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

# Runs one watcher under a hang guard that TERMs it and returns 124 once it has
# used sixty seconds of its own time. The guard pauses while the file named by
# FM_TEST_WATCH_BOUND_PAUSE exists, so a case that holds the watcher on work it
# injects, or makes it wait on concurrent work it started, charges that work's
# duration to itself instead of to the watcher.
# FM_TEST_CHECK_TIMEOUT sets the per-check timeout for a case that exercises it.
# Otherwise the product default applies: a tighter override silently kills a
# correct poll on a loaded machine, and the watcher then only retries it or
# exits on a later check's wake without the poll's result.
run_watcher_bounded() {
  local home=$1 fakebin=$2 check_interval=${FM_TEST_CHECK_INTERVAL:-0} watch_root=${FM_TEST_WATCH_ROOT:-$ROOT}
  local check_timeout_env=(-u FM_CHECK_TIMEOUT)
  [ -z "${FM_TEST_CHECK_TIMEOUT:-}" ] || check_timeout_env=("FM_CHECK_TIMEOUT=$FM_TEST_CHECK_TIMEOUT")
  shift 2
  perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $pause=shift; my $left=60; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now - $last unless length $pause && -e $pause; $last=$now; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.02 } exit($? >> 8)' \
    "${FM_TEST_WATCH_BOUND_PAUSE:-}" env "${check_timeout_env[@]}" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$watch_root" FM_CHECK_INTERVAL="$check_interval" \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$fakebin:$BASE_PATH" "$WATCH" "$@"
}

test_task_worker_arming_is_refused() {
  local dir rc
  dir=$(make_case task-worker-refused)
  write_task_meta "$dir"

  set +e
  FM_TASK_ID=other-task run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a task worker's own fm-pr-draft-check.sh invocation was accepted"
  grep -q '^pr=' "$dir/home/state/task-a.meta" && fail "a refused worker invocation still recorded pr metadata"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "a refused worker invocation still armed a check"
  grep -q FM_TASK_ID "$dir/stderr" || fail "the refusal did not name the task-worker marker"

  run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "firstmate's own arming was refused"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "firstmate's own arming did not pass the watcher's trust gate on the first try"
  pass "fm-pr-draft-check.sh refuses a task worker's own invocation and firstmate's own arming still authenticates first try"
}

test_rejected_check_notice_survives_a_later_waking_check() {
  local dir rc
  dir=$(make_case rejected-notice-durability)

  # aaa-bad sorts before every other check in this sweep; it exists on disk
  # but was never registered/trusted, so the watcher classifies it as an
  # unauthenticated state check and rejects it without running it.
  printf '#!/usr/bin/env bash\nprintf "should-not-run\\n"\n' > "$dir/home/state/aaa-bad.check.sh"
  chmod 0700 "$dir/home/state/aaa-bad.check.sh"

  # zzz-noise sorts after aaa-bad and is a properly registered custom check
  # that produces output, so the sweep's ordinary wake()+exit fires on it -
  # exactly the later-sorting check that used to discard the rejection.
  printf '#!/usr/bin/env bash\nprintf "noise\\n"\n' > "$dir/home/state/zzz-noise.check.sh"
  chmod 0700 "$dir/home/state/zzz-noise.check.sh"
  FM_HOME="$dir/home" "$REGISTER" zzz-noise >/dev/null \
    || fail "could not register the noise custom check"

  set +e
  run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "bounded watcher failed: $(cat "$dir/watch.err")"

  assert_grep 'unauthenticated-state-checks' "$dir/home/state/.wake-queue" \
    "the rejected check's durable row was lost to the later-sorting noisy check"
  pass "a rejected check's durable notice survives a later-sorting check waking the same sweep"
}

# The always-draft flow's worker reports `done: PR <url>` on a DRAFT, so the
# wrapper records and arms a draft, a ready, and an unreadable-draft pull
# request alike, and restores the fleet-ledger record the seam skips.
test_draft_pull_request_is_armed_through_the_wrapper() {
  local dir state
  for state in true false null; do
    dir=$(make_case "wrapper-draft-$state")
    write_task_meta "$dir"
    : > "$dir/home/config/fleet-ledger"
    FM_TEST_GH_DRAFT=$state run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
      > "$dir/stdout" 2> "$dir/stderr" || fail "draft=$state: the wrapper refused the pull request: $(cat "$dir/stderr")"
    grep -qxF 'pr=https://github.com/o/r/pull/9' "$dir/home/state/task-a.meta" \
      || fail "draft=$state: the pull request was not recorded"
    fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
      || fail "draft=$state: the merge poll was not armed"
    jq -e 'select(.event == "task.pr_ready" and .task == "task-a")' "$dir/home/state/fleet-ledger.jsonl" >/dev/null 2>&1 \
      || fail "draft=$state: the fleet ledger did not record the ready PR: $(cat "$dir/home/state/fleet-ledger.jsonl" 2>&1)"
  done
  # Without the wrapper, the unchanged PR check script still refuses a draft.
  if FM_TEST_GH_DRAFT=true FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_TEST_GUARD_LOG="$dir/guard.log" \
    FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/o/r/pull/10 > /dev/null 2> "$dir/direct.err"; then
    fail "the unchanged PR check script armed a draft on its own"
  fi
  pass "the wrapper records, arms and ledgers a draft, a ready, and an unreadable-draft pull request"
}

test_wrapper_prints_lint_lines() {
  local dir
  dir=$(make_case wrapper-lint-empty)
  write_task_meta "$dir"
  FM_TEST_GH_TITLE=fm/task-a run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "lint findings blocked arming: $(cat "$dir/stderr")"
  assert_grep 'PR_BODY_LINT: body is empty' "$dir/stdout" "an empty body was not linted"
  assert_grep 'PR_BODY_LINT: title is a task or branch id' "$dir/stdout" "a task-id title was not linted"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "a linted pull request was not armed"

  dir=$(make_case wrapper-lint-clean)
  write_task_meta "$dir"
  FM_TEST_GH_TITLE='Keep the watcher on upstream timeout surfacing' \
    FM_TEST_GH_BODY='Replaces the per-episode wake with the ordinary check notification.' \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/9 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "a clean pull request was refused: $(cat "$dir/stderr")"
  assert_no_grep 'PR_BODY_LINT' "$dir/stdout" "a clean title and body were linted"
  pass "the wrapper prints advisory title and body lint lines and arms regardless"
}

test_direct_pr_gate_pass_warning() {
  local dir state
  # Missing marker on a direct-PR task: advisory warning, arming still works.
  dir=$(make_case gate-warn-missing)
  state="$dir/home/state"
  fm_write_meta "$state/gate-a.meta" \
    "window=fm-gate-a" \
    "endpoint_task_id=gate-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" gate-a https://github.com/o/r/pull/31 \
    > "$dir/check.out" 2> "$dir/check.err" \
    || fail "missing gate marker must not block PR check: $(cat "$dir/check.err")"
  assert_grep "warning: direct-PR task gate-a has no local-gate pass marker" "$dir/check.err" \
    "missing gate marker must warn"
  assert_grep "armed: state/gate-a.check.sh" "$dir/check.out" \
    "gate warning must leave the merge poll armed"

  # Marker head matching the PR head: silent.
  dir=$(make_case gate-warn-match)
  state="$dir/home/state"
  fm_write_meta "$state/gate-b.meta" \
    "window=fm-gate-b" \
    "endpoint_task_id=gate-b" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  printf 'head=%s ts=1\n' "0123456789abcdef0123456789abcdef01234567" > "$state/gate-b.gate-pass"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" gate-b https://github.com/o/r/pull/32 \
    > "$dir/check.out" 2> "$dir/check.err" \
    || fail "matching gate marker must not block PR check: $(cat "$dir/check.err")"
  assert_no_grep "warning:" "$dir/check.err" \
    "a gate marker matching the PR head must not warn"

  # Marker head that drifted from the PR head: warn naming both.
  dir=$(make_case gate-warn-mismatch)
  state="$dir/home/state"
  fm_write_meta "$state/gate-c.meta" \
    "window=fm-gate-c" \
    "endpoint_task_id=gate-c" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  printf 'head=%s ts=1\n' "9999999999999999999999999999999999999999" > "$state/gate-c.gate-pass"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" gate-c https://github.com/o/r/pull/33 \
    > "$dir/check.out" 2> "$dir/check.err" \
    || fail "drifted gate marker must not block PR check: $(cat "$dir/check.err")"
  assert_grep "warning: direct-PR task gate-c gate pass head 9999999999999999999999999999999999999999 does not match PR head 0123456789abcdef0123456789abcdef01234567" "$dir/check.err" \
    "a gate marker not matching the PR head must warn"

  # Control: a task in another delivery mode without a marker never warns.
  dir=$(make_case gate-warn-other-mode)
  state="$dir/home/state"
  write_task_meta "$dir" gate-d
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" gate-d https://github.com/o/r/pull/34 \
    > "$dir/check.out" 2> "$dir/check.err" \
    || fail "a non-direct-PR task without a marker must not block PR check: $(cat "$dir/check.err")"
  assert_no_grep "warning:" "$dir/check.err" \
    "non-direct-PR tasks must never warn about a missing gate marker"
  pass "direct-PR gate pass warnings are advisory"
}

test_task_worker_arming_is_refused
test_draft_pull_request_is_armed_through_the_wrapper
test_wrapper_prints_lint_lines
test_rejected_check_notice_survives_a_later_waking_check
test_direct_pr_gate_pass_warning
