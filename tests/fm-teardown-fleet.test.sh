#!/usr/bin/env bash
# tests/fm-teardown-fleet.test.sh - this fleet's own bin/fm-teardown.sh cases.
# They live beside upstream's tests/fm-teardown.test.sh so a take-in never
# re-resolves them inside it.
#
# The recorded grok/kimi turn-end token teardown reads before revoking a
# harness's global registry entry:
#   (z)  no token file / zero-byte token / populated token -> teardown proceeds
#   (aa) present, non-empty, unreadable token              -> REFUSE, state retained
# plus the global hook's removal with the last registered task, its survival
# while another task remains, and kimi's refusal to remove a non-empty registry.
# Cleanup records the task's effort (bin/fm-effort-ledger.sh), and a ledger it
# cannot write never stops the cleanup.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-fleet-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

# The fixture helpers below are copies of upstream's suite's.
# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  fm_fakebin_write "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  fm_fakebin_write "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  fm_fakebin_write "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  fm_fakebin_write "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # The bare `axi` overview answers FM_FAKE_AXI_OVERVIEW verbatim (empty by
  # default, so no repository resolves and the pipeline-spend record is
  # written as unavailable).
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  # When FM_FAKE_NM_EXPECT_HOME is set, the stub sees runs only from that
  # NM_HOME, as a per-workspace daemon would: any other home answers no run
  # and records no abort.
  fm_fakebin_write "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_NM_EXPECT_HOME:-}" ] && [ "${NM_HOME:-}" != "$FM_FAKE_NM_EXPECT_HOME" ]; then
  exit 0
fi
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '')
        printf '%s\n' "${FM_FAKE_AXI_OVERVIEW:-}" ;;
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

# Run teardown with the harness registry homes pointed inside the case dir, so the
# grok/kimi turn-end auth entries teardown revokes are the fixture's own and never
# the runner's real ~/.grok or ~/.kimi-code. GROK_HOME is set explicitly rather than
# left to its $HOME default so an ambient GROK_HOME cannot leak in.
# Args: case_dir [extra args...]
run_teardown_with_harness_homes() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE keeps teardown's backlog and effort-ledger writes in the
  # case dir rather than the code root's own home.
  mkdir -p "$case_dir/data"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  HOME="$case_dir/harness-home" \
  GROK_HOME="$case_dir/harness-home/.grok" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Where a harness's global turn-end registry entry lands under the fake HOME above.
# Args: case_dir harness
turnend_auth_dir() {
  local case_dir=$1 harness=$2
  case "$harness" in
    grok) printf '%s\n' "$case_dir/harness-home/.grok/hooks/fm-turn-end.d" ;;
    kimi) printf '%s\n' "$case_dir/harness-home/.kimi-code/fm-turn-end.d" ;;
    *) return 1 ;;
  esac
}

# The recorded turn-end token (state/<id>.<harness>-turnend-token) names the global
# registry entry teardown revokes. bin/fm-spawn.sh writes it with a plain redirect,
# which truncates to zero bytes before the token lands, so a crash, a kill, or ENOSPC
# in that window leaves an EMPTY token file behind. An empty token names no registry
# entry, so it is the same nothing-to-revoke case as no token file at all and must not
# wedge teardown - the pre-fix read treated EOF-on-empty as a read failure, and both
# call sites abort teardown before any state is removed, so the task could never be
# torn down again. All three states are asserted against the same teardown entry point
# so the empty case cannot pass just because teardown ignores tokens entirely.
test_turnend_token_states_do_not_wedge_teardown() {
  local harness case_dir auth_dir token_path rc
  for harness in grok kimi; do
    case_dir=$(make_case "turnend-$harness-absent")
    write_meta "$case_dir" local-only ship
    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "turnend-$harness-absent: teardown should succeed with no recorded token"
    assert_absent "$case_dir/state/task-x1.meta" \
      "turnend-$harness-absent: teardown left the task meta behind"

    case_dir=$(make_case "turnend-$harness-empty")
    write_meta "$case_dir" local-only ship
    token_path="$case_dir/state/task-x1.$harness-turnend-token"
    : > "$token_path"
    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" \
      "turnend-$harness-empty: zero-byte token wedged teardown (stderr: $(cat "$case_dir/stderr"))"
    assert_absent "$token_path" "turnend-$harness-empty: empty token state survived teardown"
    assert_absent "$case_dir/state/task-x1.meta" \
      "turnend-$harness-empty: teardown left the task meta behind"

    case_dir=$(make_case "turnend-$harness-populated")
    write_meta "$case_dir" local-only ship
    token_path="$case_dir/state/task-x1.$harness-turnend-token"
    printf 'fm.abcdefabcdef\n' > "$token_path"
    auth_dir=$(turnend_auth_dir "$case_dir" "$harness")
    mkdir -p "$auth_dir"
    : > "$auth_dir/fm.abcdefabcdef"
    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "turnend-$harness-populated: teardown should succeed with a recorded token"
    assert_absent "$auth_dir/fm.abcdefabcdef" \
      "turnend-$harness-populated: registry entry survived teardown"
    assert_absent "$token_path" "turnend-$harness-populated: token state survived teardown"
  done
  pass "absent, zero-byte, and populated turn-end tokens all let teardown proceed"
}

# The counterpart to the case above: tolerating an EMPTY token must not tolerate a
# token that is present and non-empty but cannot be read, because that one really
# does leave an unrevoked registry entry behind. Teardown must fail loudly and keep
# every durable record so it can be retried once the file is readable.
test_unreadable_turnend_token_refuses_before_removing_state() {
  local harness case_dir auth_dir token_path rc
  for harness in grok kimi; do
    case_dir=$(make_case "turnend-$harness-unreadable")
    write_meta "$case_dir" local-only ship
    token_path="$case_dir/state/task-x1.$harness-turnend-token"
    printf 'fm.abcdefabcdef\n' > "$token_path"
    auth_dir=$(turnend_auth_dir "$case_dir" "$harness")
    mkdir -p "$auth_dir"
    : > "$auth_dir/fm.abcdefabcdef"
    chmod 000 "$token_path"
    if [ -r "$token_path" ]; then
      chmod 600 "$token_path"
      echo "skip: file modes do not deny reads here (running privileged); cannot stage an unreadable token"
      return 0
    fi

    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    chmod 600 "$token_path"
    expect_code 1 "$rc" "turnend-$harness-unreadable: teardown should fail on an unreadable token"
    assert_present "$auth_dir/fm.abcdefabcdef" \
      "turnend-$harness-unreadable: teardown dropped the registry entry it could not resolve"
    assert_present "$case_dir/state/task-x1.meta" \
      "turnend-$harness-unreadable: teardown removed task state despite the failure"
  done
  pass "an unreadable non-empty turn-end token still fails teardown before any state removal"
}

# Install grok's global hook files (hook script + json + registry dir) so teardown's
# maybe-retire has something to remove. Args: case_dir
install_grok_global_hook() {
  local case_dir=$1 grok_home auth_dir
  grok_home="$case_dir/harness-home/.grok"
  auth_dir="$grok_home/hooks/fm-turn-end.d"
  mkdir -p "$auth_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$grok_home/hooks/fm-turn-end.sh"
  printf '{"hooks":{"Stop":[]}}\n' > "$grok_home/hooks/fm-turn-end.json"
}

# Install kimi's global hook via the real installer so remove validates cleanly.
# Args: case_dir
install_kimi_global_hook() {
  local case_dir=$1 home config_dir
  home="$case_dir/harness-home"
  config_dir="$home/.kimi-code"
  mkdir -p "$config_dir"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$config_dir/config.toml"
  HOME="$home" "$ROOT/bin/fm-kimi-turnend-hook.sh" install \
    || fail "kimi hook install failed during test setup"
}

# The last grok/kimi task teardown removes the global hook files, not just the
# per-task registry entry. For each harness: install the global hook, populate
# the registry with exactly one entry matching the task's token, run teardown,
# and assert the global files are gone. A fresh spawn after removal reinstalls.
test_last_turnend_task_teardown_removes_global_hook() {
  local harness case_dir auth_dir token_path rc grok_home config_dir
  for harness in grok kimi; do
    case_dir=$(make_case "retire-last-$harness")
    write_meta "$case_dir" local-only ship
    token_path="$case_dir/state/task-x1.$harness-turnend-token"
    printf 'fm.abcdefabcdef\n' > "$token_path"
    auth_dir=$(turnend_auth_dir "$case_dir" "$harness")
    if [ "$harness" = grok ]; then
      install_grok_global_hook "$case_dir"
    else
      install_kimi_global_hook "$case_dir"
    fi
    mkdir -p "$auth_dir"
    : > "$auth_dir/fm.abcdefabcdef"

    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "retire-last-$harness: teardown should succeed"
    assert_absent "$auth_dir/fm.abcdefabcdef" \
      "retire-last-$harness: registry entry survived teardown"

    if [ "$harness" = grok ]; then
      grok_home="$case_dir/harness-home/.grok"
      assert_absent "$grok_home/hooks/fm-turn-end.sh" \
        "retire-last-$harness: grok hook script survived last-task teardown"
      assert_absent "$grok_home/hooks/fm-turn-end.json" \
        "retire-last-$harness: grok hook json survived last-task teardown"
      assert_absent "$grok_home/hooks/fm-turn-end.d" \
        "retire-last-$harness: grok registry dir survived last-task teardown"
    else
      config_dir="$case_dir/harness-home/.kimi-code"
      assert_absent "$config_dir/fm-turn-end.sh" \
        "retire-last-kimi: kimi hook script survived last-task teardown"
      assert_absent "$config_dir/fm-turn-end.d" \
        "retire-last-kimi: kimi registry dir survived last-task teardown"
      ! grep -q 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config_dir/config.toml" \
        || fail "retire-last-kimi: config.toml Firstmate region survived last-task teardown"
    fi
  done
  pass "last grok/kimi task teardown retires the global hook files"
}

# A non-last teardown (other tasks' tokens still in the registry) preserves the
# global hook files. For each harness: install the global hook, populate the
# registry with TWO entries, run teardown (removes one), and assert the global
# files survive along with the remaining entry.
test_non_last_turnend_task_teardown_preserves_global_hook() {
  local harness case_dir auth_dir token_path rc grok_home config_dir
  for harness in grok kimi; do
    case_dir=$(make_case "retire-nonlast-$harness")
    write_meta "$case_dir" local-only ship
    token_path="$case_dir/state/task-x1.$harness-turnend-token"
    printf 'fm.abcdefabcdef\n' > "$token_path"
    auth_dir=$(turnend_auth_dir "$case_dir" "$harness")
    if [ "$harness" = grok ]; then
      install_grok_global_hook "$case_dir"
    else
      install_kimi_global_hook "$case_dir"
    fi
    mkdir -p "$auth_dir"
    : > "$auth_dir/fm.abcdefabcdef"
    : > "$auth_dir/fm.ghijklghijkl"

    set +e
    run_teardown_with_harness_homes "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 0 "$rc" "retire-nonlast-$harness: teardown should succeed"
    assert_absent "$auth_dir/fm.abcdefabcdef" \
      "retire-nonlast-$harness: removed task's entry survived teardown (should not)"
    assert_present "$auth_dir/fm.ghijklghijkl" \
      "retire-nonlast-$harness: remaining task's entry was swept by teardown"

    if [ "$harness" = grok ]; then
      grok_home="$case_dir/harness-home/.grok"
      assert_present "$grok_home/hooks/fm-turn-end.sh" \
        "retire-nonlast-$harness: grok hook script was removed while tasks remain"
      assert_present "$grok_home/hooks/fm-turn-end.json" \
        "retire-nonlast-$harness: grok hook json was removed while tasks remain"
    else
      config_dir="$case_dir/harness-home/.kimi-code"
      assert_present "$config_dir/fm-turn-end.sh" \
        "retire-nonlast-kimi: kimi hook script was removed while tasks remain"
      grep -q 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config_dir/config.toml" \
        || fail "retire-nonlast-kimi: config.toml Firstmate region was removed while tasks remain"
    fi
  done
  pass "non-last grok/kimi task teardown preserves the global hook files"
}

# Kimi's remove subcommand refuses when the registry is non-empty, so a
# spawn-teardown race can never sweep another task's auth token via rmtree.
test_kimi_hook_remove_refuses_nonempty_registry() {
  local home config_dir hook_dir registry rc out
  home="$TMP_ROOT/kimi-remove-nonempty"
  config_dir="$home/.kimi-code"
  hook_dir="$config_dir"
  registry="$config_dir/fm-turn-end.d"
  mkdir -p "$config_dir"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$config_dir/config.toml"
  HOME="$home" "$ROOT/bin/fm-kimi-turnend-hook.sh" install \
    || fail "kimi hook install failed during test setup"
  mkdir -p "$registry"
  : > "$registry/fm.aaaaaaaaaaaa"

  set +e
  out=$(HOME="$home" "$ROOT/bin/fm-kimi-turnend-hook.sh" remove 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "kimi remove accepted a non-empty registry"
  assert_contains "$out" "not empty" "kimi remove non-empty refusal lacked its reason"
  assert_present "$registry/fm.aaaaaaaaaaaa" \
    "kimi remove deleted a registry entry despite refusing"
  assert_present "$hook_dir/fm-turn-end.sh" \
    "kimi remove deleted the hook script despite refusing"

  rm -f "$registry/fm.aaaaaaaaaaaa"
  set +e
  HOME="$home" "$ROOT/bin/fm-kimi-turnend-hook.sh" remove 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "kimi remove should succeed once the registry is empty"
  assert_absent "$hook_dir/fm-turn-end.sh" \
    "kimi remove did not remove the hook script after the registry emptied"
  pass "kimi remove refuses a non-empty registry and succeeds once it is empty"
}

# Cleanup appends the task's dispatch, ready, and landed times, with the
# planner's backlog estimate, to the effort ledger (bin/fm-effort-ledger.sh)
# while the task record and status still exist.
test_teardown_records_the_task_effort() {
  local case_dir rc=0 ledger
  case_dir=$(make_case effort-ledger)
  write_meta "$case_dir" local-only ship
  land_shippable_commit "$case_dir"
  seed_backlog_in_flight "$case_dir"
  tasks-axi update task-x1 --body "local-only. estimate=40m" --file "$case_dir/data/backlog.md" >/dev/null
  printf 'working [at=1792900000]: setup\ndone [at=1792901200]: ready in branch\n' > "$case_dir/state/task-x1.status"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "effort-ledger: teardown should succeed"
  ledger=$case_dir/data/effort-ledger.jsonl
  assert_present "$ledger" "effort-ledger: teardown left no effort record"
  jq -e '
    .task == "task-x1" and .kind == "ship" and .mode == "local-only"
    and .dispatched_at == "2026-10-25T03:46:40Z" and .ready_at == "2026-10-25T04:06:40Z"
    and .ready_source == "done-status" and .landed_source == "teardown" and .estimate_min == 40
  ' "$ledger" >/dev/null || fail "effort-ledger: the recorded effort is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "effort-ledger: teardown kept the task record"
  pass "teardown records the task's effort before removing its record"
}

# A ledger that cannot be written warns and never stops the cleanup.
test_teardown_continues_when_the_effort_ledger_cannot_be_written() {
  local case_dir rc=0
  case_dir=$(make_case effort-ledger-unwritable)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/data/effort-ledger.jsonl"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "effort-ledger-unwritable: teardown should succeed"
  assert_grep "could not record task-x1's effort" "$case_dir/stderr" \
    "effort-ledger-unwritable: teardown did not warn about the failed record"
  assert_absent "$case_dir/state/task-x1.meta" "effort-ledger-unwritable: teardown kept the task record"
  pass 'teardown continues when the effort ledger cannot be written'
}

test_turnend_token_states_do_not_wedge_teardown
test_unreadable_turnend_token_refuses_before_removing_state
test_teardown_records_the_task_effort
test_teardown_continues_when_the_effort_ledger_cannot_be_written
test_last_turnend_task_teardown_removes_global_hook
test_non_last_turnend_task_teardown_preserves_global_hook
test_kimi_hook_remove_refuses_nonempty_registry
