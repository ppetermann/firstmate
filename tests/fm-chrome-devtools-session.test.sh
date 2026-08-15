#!/usr/bin/env bash
# Behavior tests for per-task chrome-devtools-axi browser-session isolation.
#
# fm-spawn exports CHROME_DEVTOOLS_AXI_SESSION=fm-<task-id> into the worker's
# pane through the same send channel that ships GOTMPDIR, so every backend and
# harness inherits it before launch. Without a session name every caller shares
# the single default bridge and therefore ONE browser page, so two workers
# driving a browser at once silently read each other's state.
#
# fm-teardown stops that task's own named session so its bridge process does not
# outlive the task. Only its own session is stopped - never the "default"
# session (the captain's own), never a pattern-matched kill, and never failing
# or blocking teardown.
#
# The spawn side exercises the real fm-spawn.sh against a fake tmux that logs
# every send-keys payload (the launch-path regression pattern from
# fm-trace-context-spawn.test.sh). The teardown side exercises the real
# fm-teardown.sh against a fake FM_HOME with a nonexistent worktree (the
# cleanup-path regression pattern from fm-gotmp.test.sh) and a fake
# chrome-devtools-axi that logs its invocations.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Exempt the teardown subprocess from the gate-lifecycle refusal the way lib.sh
# would for an in-process call: the no-mistakes gate may run this suite from a
# gate worktree, which fm-gate-refuse-lib.sh would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-chrome-devtools-session)

# ---------------------------------------------------------------------------
# Spawn side: fake tmux logs every send-keys text payload, one per line, in
# send order, so the CHROME_DEVTOOLS_AXI_SESSION export and the launch literal
# are both observable and their ordering is checkable.
# ---------------------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

# run_spawn <home> <wt> <fakebin> <launchlog> <id> <proj> <extra-spawn-flags...>
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  shift 6
  : > "$launchlog"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:/usr/bin:/bin" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

# A spawn must export CHROME_DEVTOOLS_AXI_SESSION=fm-<id> into the pane before
# the launch literal, so the worker's chrome-devtools-axi calls use a per-task
# session inherited from the environment rather than the shared default bridge.
test_ship_spawn_exports_per_task_session() {
  local rec home proj wt fakebin launchlog id out status gl sl ll
  rec=$(make_spawn_case ship-session)
  IFS='|' read -r home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed"
  assert_contains "$out" "spawned $id" "ship spawn should report success"
  assert_grep "export CHROME_DEVTOOLS_AXI_SESSION=fm-$id" "$launchlog" \
    "ship spawn did not export the per-task chrome-devtools-axi session"
  # The export must land before the launch literal so the env is set when the
  # agent starts; compare line numbers in the send-order log.
  gl=$(grep -n '^export GOTMPDIR=' "$launchlog" | head -1 | cut -d: -f1)
  sl=$(grep -n '^export CHROME_DEVTOOLS_AXI_SESSION=' "$launchlog" | head -1 | cut -d: -f1)
  ll=$(grep -n 'claude' "$launchlog" | tail -1 | cut -d: -f1)
  [ -n "$gl" ] && [ -n "$sl" ] && [ -n "$ll" ] \
    || fail "launch log missing GOTMPDIR/session/launch lines"
  [ "$sl" -gt "$gl" ] || fail "session export must follow the GOTMPDIR site (gotmp=$gl session=$sl)"
  [ "$sl" -lt "$ll" ] || fail "session export must precede the launch literal (session=$sl launch=$ll)"
  pass "ship spawn exports CHROME_DEVTOOLS_AXI_SESSION=fm-<id> before the launch literal"
}

test_scout_spawn_exports_per_task_session() {
  local rec home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case scout-session)
  IFS='|' read -r home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed"
  assert_contains "$out" "spawned $id" "scout spawn should report success"
  assert_grep "export CHROME_DEVTOOLS_AXI_SESSION=fm-$id" "$launchlog" \
    "scout spawn did not export the per-task chrome-devtools-axi session"
  pass "scout spawn exports CHROME_DEVTOOLS_AXI_SESSION=fm-<id>"
}

# Two tasks running browser work at once must hold two different sessions, or a
# navigate by one silently returns the other's page.
test_distinct_task_ids_produce_distinct_sessions() {
  local rec_a rec_b
  local ha pa wa fa la ia hb pb wb fb lb ib
  local out sess_a sess_b
  rec_a=$(make_spawn_case distinct-a)
  rec_b=$(make_spawn_case distinct-b)
  IFS='|' read -r ha pa wa fa la ia <<EOF
$rec_a
EOF
  IFS='|' read -r hb pb wb fb lb ib <<EOF
$rec_b
EOF
  out=$(run_spawn "$ha" "$wa" "$fa" "$la" "$ia" "$pa" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "distinct-a spawn should succeed"
  sess_a=$(sed -n 's/^export CHROME_DEVTOOLS_AXI_SESSION=//p' "$la" | head -1)
  out=$(run_spawn "$hb" "$wb" "$fb" "$lb" "$ib" "$pb" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "distinct-b spawn should succeed"
  sess_b=$(sed -n 's/^export CHROME_DEVTOOLS_AXI_SESSION=//p' "$lb" | head -1)
  [ -n "$sess_a" ] || fail "distinct-a produced no session export"
  [ -n "$sess_b" ] || fail "distinct-b produced no session export"
  [ "$sess_a" != "$sess_b" ] \
    || fail "two different task ids produced the same session name ($sess_a)"
  pass "distinct task ids produce distinct chrome-devtools-axi session names"
}

# chrome-devtools-axi rejects session names longer than 64 chars, and task ids
# are valid up to 64 chars, so the plain fm-<id> form can exceed the limit. A
# maximum-length task id must still get a session name the tool accepts
# (1-64 chars from [A-Za-z0-9._-]), and teardown must stop exactly the session
# spawn exported - the round trip is the contract that keeps the bridge from
# leaking.
test_max_length_task_id_gets_valid_session_and_round_trips() {
  local name rec home proj wt fakebin launchlog id out status sess
  local fake tfakebin log stopped
  name="long-$(printf 'a%.0s' {1..56})"
  rec=$(make_spawn_case "$name")
  IFS='|' read -r home proj wt fakebin launchlog id <<EOF
$rec
EOF
  [ "${#id}" -eq 64 ] || fail "fixture task id should be 64 chars (got ${#id})"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with a 64-char task id should succeed"
  sess=$(sed -n 's/^export CHROME_DEVTOOLS_AXI_SESSION=//p' "$launchlog" | head -1)
  [ -n "$sess" ] || fail "spawn with a 64-char task id produced no session export"
  printf '%s' "$sess" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || fail "session name for a 64-char task id is not accepted by chrome-devtools-axi ($sess, len ${#sess})"
  case "$sess" in
    fm-*) ;;
    *) fail "session name for a 64-char task id lost its fm- prefix ($sess)" ;;
  esac
  fake=$(make_teardown_fake_root "$id")
  tfakebin=$(fm_fakebin "$TMP_ROOT/$id-fakebin")
  log="$TMP_ROOT/$id-cdaxi.log"
  : > "$log"
  write_fake_chrome_devtools_axi "$tfakebin"
  out=$(FM_FAKE_CDAXI_LOG="$log" run_teardown "$fake" "$tfakebin" "$id")
  status=$?
  expect_code 0 "$status" "teardown with a 64-char task id should complete"
  stopped=$(sed -n 's/ stop$//p' "$log" | head -1)
  [ "$stopped" = "$sess" ] \
    || fail "teardown stopped '$stopped' but spawn exported '$sess' - the bridge leaks"
  pass "a 64-char task id round-trips one valid session through spawn and teardown"
}

# Two long task ids that agree on the truncated prefix must still derive two
# different session names, or two concurrent workers with near-identical long
# ids silently share one browser again.
test_long_ids_sharing_prefix_derive_distinct_sessions() {
  local prefix a b sa sb
  prefix=$(printf 'p%.0s' {1..60})
  a="${prefix}-ax"
  b="${prefix}-bx"
  sa=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_chrome_devtools_session_name "$2"' _ "$ROOT" "$a") \
    || fail "session derivation failed for long id a"
  sb=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_chrome_devtools_session_name "$2"' _ "$ROOT" "$b") \
    || fail "session derivation failed for long id b"
  printf '%s' "$sa" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || fail "derived session for long id a is invalid ($sa)"
  printf '%s' "$sb" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || fail "derived session for long id b is invalid ($sb)"
  [ "$sa" != "$sb" ] \
    || fail "two long ids sharing a prefix derived the same session ($sa)"
  pass "long task ids sharing a truncated prefix derive distinct sessions"
}

# ---------------------------------------------------------------------------
# Teardown side: fake FM_HOME with the real teardown symlinked in and a
# nonexistent worktree so the dirty/treehouse guards skip straight to the
# per-task cleanup path. A fake chrome-devtools-axi logs every stop call with
# its session env so the tests assert exactly which session was stopped.
# ---------------------------------------------------------------------------

make_teardown_fake_root() {
  local id=$1
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/bin"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-tasks-axi-lib.sh" "$fake/bin/fm-tasks-axi-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # Nonexistent worktree so every dirty/treehouse guard skips to cleanup + state rm.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  printf '%s' "$fake"
}

# Fake chrome-devtools-axi: logs "<session> <subcommand>" for every invocation
# and optionally exits non-zero on stop to exercise the failure-tolerant path.
write_fake_chrome_devtools_axi() {
  local fakebin=$1
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
session="${CHROME_DEVTOOLS_AXI_SESSION:-}"
subcmd="${1:-}"
if [ -n "${FM_FAKE_CDAXI_LOG:-}" ]; then
  printf '%s %s\n' "$session" "$subcmd" >> "$FM_FAKE_CDAXI_LOG"
fi
if [ "$subcmd" = stop ] && [ "${FM_FAKE_CDAXI_STOP_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/chrome-devtools-axi"
}

run_teardown() {
  local fake=$1 fakebin=$2 id=$3
  shift 3
  env FM_HOME="$fake" FM_ROOT_OVERRIDE="$fake" \
    FM_GATE_REFUSE_BYPASS=1 \
    FM_FAKE_CDAXI_LOG="${FM_FAKE_CDAXI_LOG:-}" \
    FM_FAKE_CDAXI_STOP_FAIL="${FM_FAKE_CDAXI_STOP_FAIL:-0}" \
    PATH="$fakebin:/usr/bin:/bin" \
    bash "$fake/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

# Teardown must stop exactly the task's own fm-<id> session and never the
# captain's "default" session.
test_teardown_stops_own_session_never_default() {
  local id=td-session-z2 fake fakebin log out status stopped
  id=td-sess-z2
  fake=$(make_teardown_fake_root "$id")
  fakebin=$(fm_fakebin "$TMP_ROOT/$id-fakebin")
  log="$TMP_ROOT/$id-cdaxi.log"
  : > "$log"
  write_fake_chrome_devtools_axi "$fakebin"
  out=$(FM_FAKE_CDAXI_LOG="$log" run_teardown "$fake" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "teardown should complete when stopping the task session"
  [ -f "$log" ] || fail "fake chrome-devtools-axi was not invoked"
  stopped=$(sed -n 's/^fm-'"$id"' stop$/match/p' "$log" | head -1)
  [ "$stopped" = match ] \
    || fail "teardown did not stop the task's own session fm-$id (log: $(cat "$log"))"
  # The default session must NEVER appear in any stop call.
  ! grep -q '^default ' "$log" \
    || fail "teardown stopped the captain's default session (log: $(cat "$log"))"
  pass "teardown stops only the task's own session, never default"
}

# An absent chrome-devtools-axi must not fail or block teardown.
test_teardown_completes_when_tool_missing() {
  local id=td-missing-z3 fake fakebin out status
  id=td-miss-z3
  fake=$(make_teardown_fake_root "$id")
  fakebin=$(fm_fakebin "$TMP_ROOT/$id-fakebin")
  # Intentionally NO chrome-devtools-axi in fakebin; PATH excludes ~/.local/bin.
  out=$(run_teardown "$fake" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "teardown should complete when chrome-devtools-axi is absent"
  pass "teardown completes when the browser tool is missing"
}

# A failing stop command must not fail or block teardown.
test_teardown_completes_when_stop_fails() {
  local id=td-fail-z4 fake fakebin log out status
  id=td-fail-z4
  fake=$(make_teardown_fake_root "$id")
  fakebin=$(fm_fakebin "$TMP_ROOT/$id-fakebin")
  log="$TMP_ROOT/$id-cdaxi.log"
  : > "$log"
  write_fake_chrome_devtools_axi "$fakebin"
  out=$(FM_FAKE_CDAXI_LOG="$log" FM_FAKE_CDAXI_STOP_FAIL=1 run_teardown "$fake" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "teardown should complete when chrome-devtools-axi stop errors"
  pass "teardown completes when the browser-tool stop command fails"
}

test_ship_spawn_exports_per_task_session
test_scout_spawn_exports_per_task_session
test_distinct_task_ids_produce_distinct_sessions
test_max_length_task_id_gets_valid_session_and_round_trips
test_long_ids_sharing_prefix_derive_distinct_sessions
test_teardown_stops_own_session_never_default
test_teardown_completes_when_tool_missing
test_teardown_completes_when_stop_fails

echo "# all fm-chrome-devtools-session tests passed"
