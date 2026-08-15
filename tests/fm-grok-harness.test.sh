#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

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
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok --mode no-mistakes --yolo off 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_grok_last_task_teardown_removes_global_hook() {
  local rec case_dir home proj wt fakebin grok_home id out status token hook hook_json
  rec=$(make_spawn_case retire-global)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before last-task teardown"
  hook="$grok_home/hooks/fm-turn-end.sh"
  hook_json="$grok_home/hooks/fm-turn-end.json"
  assert_present "$hook" "grok hook script should exist after spawn"
  assert_present "$hook_json" "grok hook json should exist after spawn"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok last-task teardown failed"

  assert_absent "$hook" "grok hook script survived last-task teardown"
  assert_absent "$hook_json" "grok hook json survived last-task teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d" \
    "grok registry dir survived last-task teardown"

  mkdir -p "$home/data/grok-respawn-x2"
  printf 'brief\n' > "$home/data/grok-respawn-x2/brief.md"
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "grok-respawn-x2")
  status=$?
  expect_code 0 "$status" "grok re-spawn after global hook removal should succeed"
  assert_present "$grok_home/hooks/fm-turn-end.sh" \
    "grok re-spawn did not reinstall the hook script"
  assert_present "$grok_home/hooks/fm-turn-end.json" \
    "grok re-spawn did not reinstall the hook json"
  pass "grok last-task teardown removes global hook; a fresh spawn reinstalls it"
}

test_grok_retire_waits_for_the_registry_lock() {
  local home hooks registry hook hook_json token lock ready proceed retired_rc holder retired i=0
  home="$TMP_ROOT/retire-lock"
  hooks="$home/hooks"
  registry="$hooks/fm-turn-end.d"
  hook="$hooks/fm-turn-end.sh"
  hook_json="$hooks/fm-turn-end.json"
  mkdir -p "$registry" "$home/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hook"
  printf '{"hooks":{"Stop":[]}}\n' > "$hook_json"
  token=fm.abcdefabcdef
  printf 'x\n' > "$registry/$token"
  lock="$registry.lock"
  ready="$home/lock-ready"
  proceed="$home/lock-proceed"
  retired_rc="$home/retire-rc"
  rm -f "$ready" "$proceed" "$proceed.release"
  (
    # shellcheck source=/dev/null
    FM_STATE_OVERRIDE="$home/state" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -s "$proceed" ]; do sleep 0.01; done
    # The racing spawn's locked critical section: mint plus hook write under
    # the held lock, exactly as fm-spawn's grok section does.
    : > "$registry/fm.ghijklghijkl"
    : > "$home/spawn-done"
    while [ ! -e "$proceed.release" ]; do sleep 0.01; done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; fail "could not stage the held grok registry lock"; }

  cat > "$home/retire.sh" <<'EOS'
#!/usr/bin/env bash
set -u
. "$FM_ROOT_SRC/bin/fm-wake-lib.sh"
. "$FM_ROOT_SRC/bin/fm-control-lib.sh"
fm_control_harness_turnend_maybe_retire_global grok "$FM_ROOT_SRC/bin"
echo $? > "$FM_RETIRED_RC"
EOS
  HOME="$home" GROK_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_SRC="$ROOT" FM_RETIRED_RC="$retired_rc" bash "$home/retire.sh" &
  retired=$!
  sleep 1
  if ! kill -0 "$retired" 2>/dev/null || [ -f "$retired_rc" ]; then
    : > "$proceed.release"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    wait "$retired" 2>/dev/null || true
    fail "grok retirement did not wait for the held registry lock"
  fi
  assert_present "$hook" "blocked grok retirement removed the hook script mid-race"
  # Let the frozen spawn-side critical section install its entry, then release.
  printf 'go\n' > "$proceed"
  i=0
  while [ ! -e "$home/spawn-done" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/spawn-done" ] || fail "staged grok install never completed under the held lock"
  : > "$proceed.release"
  wait "$holder" || fail "grok registry lock holder failed"
  wait "$retired" || fail "grok retiring subshell failed"
  [ "$(cat "$retired_rc")" = 0 ] || fail "grok retirement reported failure: $(cat "$retired_rc")"
  assert_present "$hook" "grok retirement racing a spawn removed the live entry's hook script"
  assert_present "$hook_json" "grok retirement racing a spawn removed the live entry's hook json"
  assert_present "$registry/fm.ghijklghijkl" "grok retirement racing a spawn destroyed the live entry"
  assert_present "$registry/$token" "grok retirement racing a spawn destroyed the preexisting entry"
  pass "grok retirement serializes with the spawn-side hook install"
}

test_grok_spawn_hook_write_holds_the_registry_lock() {
  local rec case_dir home proj wt fakebin grok_home id lock ready proceed spawn_pid i=0 rc token
  rec=$(make_spawn_case lockspawn)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rm -rf "/tmp/fm-$id"
  lock="$grok_home/hooks/fm-turn-end.d.lock"
  # The lock directory lives in the hooks parent, which a real spawn creates
  # before acquiring; stage it the same way.
  mkdir -p "$grok_home/hooks"
  ready="$case_dir/lock-ready"
  proceed="$case_dir/lock-proceed"
  rm -f "$ready" "$proceed"
  (
    # shellcheck source=/dev/null
    FM_STATE_OVERRIDE="$home/state" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -s "$proceed" ]; do sleep 0.01; done
  ) &
  local holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; fail "could not stage the held grok registry lock"; }

  run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id" \
    > "$case_dir/spawn.log" 2>&1 &
  spawn_pid=$!
  # /tmp/fm-<id> is created just before the harness wiring, so once it exists
  # an unlocked spawn would mint and write its hooks within milliseconds.
  i=0
  while [ ! -d "/tmp/fm-$id/gotmp" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -d "/tmp/fm-$id/gotmp" ] || { printf 'go\n' > "$proceed"; wait "$holder" 2>/dev/null || true; wait "$spawn_pid" 2>/dev/null || true; fail "spawn never reached its wiring stage"; }
  sleep 1
  if [ -n "$(ls "$grok_home/hooks/fm-turn-end.d" 2>/dev/null)" ]; then
    printf 'go\n' > "$proceed"
    wait "$holder" 2>/dev/null || true
    wait "$spawn_pid" 2>/dev/null || true
    rm -rf "/tmp/fm-$id"
    fail "grok spawn wrote its registry entry without holding the registry lock"
  fi
  if ! kill -0 "$spawn_pid" 2>/dev/null; then
    : > "$proceed"
    wait "$holder" 2>/dev/null || true
    rm -rf "/tmp/fm-$id"
    fail "grok spawn exited instead of waiting for the registry lock: $(cat "$case_dir/spawn.log")"
  fi

  printf 'go\n' > "$proceed"
  wait "$holder" || fail "grok registry lock holder failed"
  wait "$spawn_pid"; rc=$?
  rm -rf "/tmp/fm-$id"
  expect_code 0 "$rc" "grok spawn should complete after the registry lock releases"$'\n'"$(cat "$case_dir/spawn.log")"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" \
    "grok spawn did not register its token after the lock released"
  pass "fm-spawn: grok hook install waits for the registry lock and registers after release"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_grok_last_task_teardown_removes_global_hook
test_grok_retire_waits_for_the_registry_lock
test_grok_spawn_hook_write_holds_the_registry_lock
test_fm_lock_recognizes_grok_holder
