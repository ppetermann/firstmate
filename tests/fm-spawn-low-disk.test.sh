#!/usr/bin/env bash
# Behavior tests for the free-space check before a Rust dispatch: a fresh ship
# or scout spawn for a project with a Cargo.toml warns below 20% free on the
# pool's filesystem and refuses below 10% unless --allow-low-disk is given
# (bin/fm-pool-disk-lib.sh owns the thresholds; bin/fm-spawn.sh runs the check).
#
# Every case drives the real bin/fm-spawn.sh with fake tmux, treehouse, and df.
# A refused spawn is judged by what it left behind - no task record, no
# rendered launch brief, no endpoint or pool call - not by wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-low-disk)

make_case() {  # <name> <rust|plain>
  local case_dir="$TMP_ROOT/$1" fakebin home
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  fm_fakebin_write "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
# The task window exists once spawn creates it, so a tmux target check after
# new-window finds it.
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "${FM_FAKE_CALL_LOG%/*}/windows" ] || cat "${FM_FAKE_CALL_LOG%/*}/windows" ;;
  new-window) printf 'fm-task-a\n' > "${FM_FAKE_CALL_LOG%/*}/windows" ;;
esac
exit 0
SH
  fm_fakebin_write "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  # df reports FM_FAKE_DF_USED and FM_FAKE_DF_AVAIL kilobytes for any path.
  fm_fakebin_write "$fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s %s %s 0%% /pool\n' "$((FM_FAKE_DF_USED + FM_FAKE_DF_AVAIL))" "$FM_FAKE_DF_USED" "$FM_FAKE_DF_AVAIL"
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/df"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  if [ "$2" = rust ]; then
    printf '[package]\nname = "fixture"\n' > "$case_dir/project/Cargo.toml"
    git -C "$case_dir/project" add Cargo.toml
    git -C "$case_dir/project" -c user.name=t -c user.email=t@example.invalid commit -qm rust
  fi
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data/task-a" "$case_dir/pools"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  cat > "$home/data/task-a/brief.md" <<'EOF'
# Task
## Captain's intent
Build the fixture.

## Firstmate spec
Exercise the free-space check.

# Definition of done
Delivery contract: mode=direct-PR
EOF
  git -C "$case_dir/project" worktree add --quiet -b wt-task-a "$case_dir/wt-task-a"
  printf '%s\n' "$case_dir"
}

run_spawn() {  # <case-dir> <used-kb> <avail-kb> [extra-arg...]
  local case_dir=$1 used=$2 avail=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_TREEHOUSE_POOL_ROOT="$case_dir/pools" FM_FAKE_DF_USED="$used" FM_FAKE_DF_AVAIL="$avail" \
    FM_FAKE_PANE_PATH="$case_dir/wt-task-a" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" task-a "$case_dir/project" --mode direct-PR --yolo off "$@" 2>&1
}

test_nearly_full_disk_refuses_a_rust_spawn_before_creating_anything() {
  local case_dir out rc=0
  case_dir=$(make_case refuse rust)
  out=$(run_spawn "$case_dir" 95000000 5000000) || rc=$?
  expect_code 1 "$rc" "a Rust spawn at 5% free was not refused: $out"
  assert_contains "$out" "spawn refused: disk nearly full for a Rust build: 4 GB free of 95 GB (5%) on /pool, below the 10% floor" \
    "the refusal did not name the free space"
  assert_contains "$out" "--allow-low-disk" "the refusal did not name the override"
  assert_absent "$case_dir/home/state/task-a.meta" "a refused spawn published a task record"
  assert_absent "$case_dir/home/data/task-a/launch-brief.md" "a refused spawn rendered a launch brief"
  [ ! -s "$case_dir/calls.log" ] || fail "a refused spawn touched the terminal or pool: $(cat "$case_dir/calls.log")"
  pass "a Rust spawn below 10% free is refused before any record, brief, endpoint, or pool call"
}

test_override_and_warning_still_launch() {
  local case_dir out rc=0
  case_dir=$(make_case override rust)
  out=$(run_spawn "$case_dir" 95000000 5000000 --allow-low-disk) || rc=$?
  expect_code 0 "$rc" "--allow-low-disk did not launch: $out"
  assert_contains "$out" "launching anyway on --allow-low-disk" "the override did not warn"
  assert_contains "$out" "spawned task-a" "the override did not launch"

  case_dir=$(make_case warn rust)
  out=$(run_spawn "$case_dir" 85000000 15000000) || rc=$?
  expect_code 0 "$rc" "a Rust spawn at 15% free was refused: $out"
  assert_contains "$out" "warning: disk space low for a Rust build: 14 GB free of 95 GB (15%) on /pool, below 20%" \
    "a spawn at 15% free did not warn"
  assert_contains "$out" "spawned task-a" "a spawn at 15% free did not launch"

  case_dir=$(make_case roomy rust)
  out=$(run_spawn "$case_dir" 50000000 50000000) || rc=$?
  expect_code 0 "$rc" "a Rust spawn at 50% free was refused: $out"
  assert_not_contains "$out" "for a Rust build" "a spawn with room to spare mentioned disk space"
  pass "--allow-low-disk launches below the floor with a warning, 10-20% free warns, and ample space is silent"
}

test_batch_forwards_the_override() {
  local case_dir out rc=0
  case_dir=$(make_case batch rust)
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_TREEHOUSE_POOL_ROOT="$case_dir/pools" FM_FAKE_DF_USED=95000000 FM_FAKE_DF_AVAIL=5000000 \
    FM_FAKE_PANE_PATH="$case_dir/wt-task-a" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "task-a=$case_dir/project" --harness codex --mode direct-PR --yolo off --allow-low-disk 2>&1) || rc=$?
  expect_code 0 "$rc" "a batch with --allow-low-disk did not launch: $out"
  assert_contains "$out" "launching anyway on --allow-low-disk" "the batch did not forward the override"
  pass "a batch spawn forwards --allow-low-disk to each pair"
}

test_non_rust_project_is_not_checked() {
  local case_dir out rc=0
  case_dir=$(make_case plain plain)
  out=$(run_spawn "$case_dir" 95000000 5000000) || rc=$?
  expect_code 0 "$rc" "a non-Rust spawn was refused for disk space: $out"
  assert_not_contains "$out" "for a Rust build" "a non-Rust spawn mentioned disk space"
  pass "a project without a Cargo.toml is dispatched without a disk check"
}

test_nearly_full_disk_refuses_a_rust_spawn_before_creating_anything
test_override_and_warning_still_launch
test_batch_forwards_the_override
test_non_rust_project_is_not_checked
