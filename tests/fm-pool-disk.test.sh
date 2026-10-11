#!/usr/bin/env bash
# Behavior tests for worker-pool disk housekeeping (bin/fm-pool-disk-lib.sh owns
# the contract): the pool-return trim of a Rust copy, its wiring into
# bin/fm-teardown.sh, the idle-copy sweep in bin/fm-pool-sweep.sh, and the
# free-space verdict a Rust dispatch reads.
#
# Every target/ here is a small fixture tree with the shape Cargo writes, and
# cargo-sweep, treehouse, tmux, and df are logging stand-ins, so nothing
# real is built, swept, or measured.
# Library snippets are single-quoted on purpose: they expand inside the shell
# that sourced bin/fm-pool-disk-lib.sh, not here.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-pool-disk-lib.sh"
SWEEP="$ROOT/bin/fm-pool-sweep.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-disk)

blob() {  # <path> [exec]
  mkdir -p "$(dirname "$1")"
  head -c 8192 /dev/zero > "$1"
  [ "${2:-}" != exec ] || chmod +x "$1"
}

# A Rust project clone: Cargo.toml at its top and target/ ignored.
make_rust_project() {  # <dir>
  fm_git_init_commit "$1"
  printf '[package]\nname = "fixture"\n' > "$1/Cargo.toml"
  printf 'target/\n' > "$1/.gitignore"
  git -C "$1" add Cargo.toml .gitignore
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm rust
}

# The target/ shape Cargo leaves behind, plus a nested firmware workspace whose
# own target must never be touched.
seed_target() {  # <copy>
  local t="$1/target"
  blob "$t/debug/incremental/fixture-1a2b/s-abc/obj.o"
  blob "$t/debug/deps/fixture-0123abcd" exec
  blob "$t/debug/deps/libfoo-0123abcd.rlib" exec
  blob "$t/debug/deps/libfoo-0123abcd.rmeta"
  blob "$t/debug/deps/fixture-0123abcd.d"
  blob "$t/debug/deps/libserde_derive-77aa.so" exec
  blob "$t/debug/build/foo-99/build-script-build" exec
  blob "$t/debug/fixture" exec
  blob "$t/release/incremental/fixture-3c4d/s-def/obj.o"
  blob "$t/release/deps/fixture-cafe0001" exec
  blob "$1/pane/target/debug/incremental/pane-1/s-1/obj.o"
  blob "$1/pane/target/debug/deps/pane-0001" exec
}

assert_trimmed() {  # <copy> <description>
  local t="$1/target"
  assert_absent "$t/debug/incremental" "$2: debug incremental cache survived"
  assert_absent "$t/release/incremental" "$2: release incremental cache survived"
  assert_absent "$t/debug/deps/fixture-0123abcd" "$2: test executable survived"
  assert_absent "$t/release/deps/fixture-cafe0001" "$2: release executable survived"
  assert_kept "$1" "$2"
}

# Everything the trim must keep, in every mode.
assert_kept() {  # <copy> <description>
  local t="$1/target"
  assert_present "$t/debug/deps/libfoo-0123abcd.rlib" "$2: compiled library removed"
  assert_present "$t/debug/deps/libfoo-0123abcd.rmeta" "$2: library metadata removed"
  assert_present "$t/debug/deps/fixture-0123abcd.d" "$2: dep-info removed"
  assert_present "$t/debug/deps/libserde_derive-77aa.so" "$2: proc-macro library removed"
  assert_present "$t/debug/build/foo-99/build-script-build" "$2: build-script output removed"
  assert_present "$t/debug/fixture" "$2: file outside deps removed"
  assert_present "$1/pane/target/debug/incremental/pane-1/s-1/obj.o" "$2: nested workspace cache removed"
  assert_present "$1/pane/target/debug/deps/pane-0001" "$2: nested workspace executable removed"
}

assert_untouched() {  # <copy> <description>
  assert_present "$1/target/debug/incremental/fixture-1a2b/s-abc/obj.o" "$2: incremental cache removed"
  assert_present "$1/target/debug/deps/fixture-0123abcd" "$2: executable removed"
  assert_kept "$1" "$2"
}

lib() {  # <shell snippet> [arg...] - run in bash with the library sourced; args are $1...
  local snippet=$1
  shift
  bash -c ". \"\$0\"; $snippet" "$LIB" "$@"
}

# --- pool-return trim -------------------------------------------------------

test_trim_removes_caches_and_executables_and_keeps_libraries() {
  local copy="$TMP_ROOT/trim/copy" out rc=0
  make_rust_project "$copy"
  seed_target "$copy"
  out=$(lib 'fm_pool_trim_copy "$1" dry-run' "$copy" 2>&1) || rc=$?
  expect_code 0 "$rc" "dry-run trim failed: $out"
  assert_contains "$out" "would free" "dry run did not report what it would free"
  assert_contains "$out" "(2 incremental cache dir(s), 2 executable(s))" "dry run counted the wrong set"
  assert_untouched "$copy" "dry-run trim"
  out=$(lib 'fm_pool_trim_copy "$1" apply' "$copy" 2>&1) || rc=$?
  expect_code 0 "$rc" "trim failed: $out"
  assert_contains "$out" "trim: $copy: freed" "trim did not report what it freed"
  assert_trimmed "$copy" "trim"
  pass "the pool-return trim removes incremental caches and linked executables, keeps every library, and leaves nested workspaces alone"
}

test_trim_only_touches_ignored_rust_targets() {
  local base="$TMP_ROOT/trim-guards" out
  make_rust_project "$base/unignored"
  seed_target "$base/unignored"
  git -C "$base/unignored" rm -q --cached .gitignore
  rm "$base/unignored/.gitignore"
  out=$(lib 'fm_pool_trim_copy "$1" apply' "$base/unignored" 2>&1)
  assert_equals "" "$out" "a target/ git does not ignore was reported"
  assert_untouched "$base/unignored" "unignored target"

  make_rust_project "$base/linked"
  seed_target "$base/linked-real"
  ln -s "$base/linked-real/target" "$base/linked/target"
  lib 'fm_pool_trim_copy "$1" apply' "$base/linked" >/dev/null 2>&1
  assert_untouched "$base/linked-real" "symlinked target"

  fm_git_init_commit "$base/not-rust"
  printf 'target/\n' > "$base/not-rust/.gitignore"
  seed_target "$base/not-rust"
  lib 'fm_pool_trim_copy "$1" apply' "$base/not-rust" >/dev/null 2>&1
  assert_untouched "$base/not-rust" "copy without Cargo.toml"

  expect_code 2 "$(lib 'fm_pool_trim_copy "$1" sideways; echo $?' "$base/linked" 2>/dev/null)" \
    "an unknown trim mode was accepted"
  pass "the trim leaves a target/ alone unless it is a real, git-ignored target of a Cargo project"
}

test_trim_reports_undeletable_paths_and_still_succeeds() {
  local copy="$TMP_ROOT/trim-stuck/copy" out rc=0
  if [ "$(id -u)" = 0 ]; then
    pass "SKIP: running as root, so a read-only directory cannot simulate root-owned output"
    return 0
  fi
  make_rust_project "$copy"
  seed_target "$copy"
  chmod a-w "$copy/target/release"
  out=$(lib 'fm_pool_trim_copy "$1" apply' "$copy" 2>&1) || rc=$?
  chmod u+w "$copy/target/release"
  expect_code 0 "$rc" "a trim with undeletable paths failed: $out"
  assert_contains "$out" "1 path(s) could not be deleted" "the surviving path was not reported"
  assert_contains "$out" "docker run --rm -v '$copy/target':/w alpine rm -rf /w/release/incremental" \
    "the report did not give the root-container removal command"
  assert_present "$copy/target/release/incremental" "the read-only directory's entry vanished"
  assert_absent "$copy/target/debug/incremental" "the trim stopped at the first undeletable path"
  assert_absent "$copy/target/debug/deps/fixture-0123abcd" "the trim stopped at the first undeletable path"
  pass "an undeletable path is reported with its removal command and never fails the trim"
}

# --- free-space verdict -----------------------------------------------------

fake_df() {  # <dir> <used-kb> <avail-kb>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fakebin_write "$fakebin/df" <<SH
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake %s %s %s 0%% /pool\n' "$(($2 + $3))" "$2" "$3"
SH
  chmod +x "$fakebin/df"
  printf '%s\n' "$fakebin"
}

verdict_for() {  # <case> <used-kb> <avail-kb>
  local fakebin
  fakebin=$(fake_df "$TMP_ROOT/df-$1" "$2" "$3")
  PATH="$fakebin:$PATH" lib 'fm_pool_disk_free / && printf "%s|%s\n" "$(fm_pool_disk_verdict)" "$FM_POOL_DISK_SUMMARY"'
}

test_free_space_verdict_thresholds() {
  local out fakebin
  out=$(verdict_for ok 750000000 250000000)
  assert_equals "ok|238 GB free of 953 GB (25%) on /pool" "$out" "25% free"
  assert_equals "ok" "$(verdict_for edge20 80 20 | cut -d'|' -f1)" "exactly 20% free"
  assert_equals "warn" "$(verdict_for warn 85 15 | cut -d'|' -f1)" "15% free"
  assert_equals "warn" "$(verdict_for edge10 90 10 | cut -d'|' -f1)" "exactly 10% free"
  assert_equals "refuse" "$(verdict_for refuse 95 5 | cut -d'|' -f1)" "5% free"
  fakebin=$(fm_fakebin "$TMP_ROOT/df-broken")
  fm_fakebin_write "$fakebin/df" <<'SH'
#!/usr/bin/env bash
echo 'df: cannot read' >&2
exit 1
SH
  chmod +x "$fakebin/df"
  PATH="$fakebin:$PATH" lib 'fm_pool_disk_free /' && fail "an unreadable df produced a reading"
  pass "free space warns below 20% and refuses below 10%, and an unreadable df yields no verdict"
}

# --- idle-copy sweep --------------------------------------------------------

# A pool of six copies of one Rust project, laid out <pool>/<slot>/<repo> with
# Treehouse's state file, a root Firstmate home, and stand-ins for treehouse
# (status read from $FM_FAKE_TH_STATUS) and cargo-sweep (arguments logged).
make_pool_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin slot
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pools/proj-abc"
  make_rust_project "$dir/project"
  for slot in 1 2 3 4 5 6; do
    git -C "$dir/project" worktree add -q --detach "$dir/pools/proj-abc/$slot/project"
    [ "$slot" = 6 ] || seed_target "$dir/pools/proj-abc/$slot/project"
  done
  printf '{"worktrees":[]}\n' > "$dir/pools/proj-abc/treehouse-state.json"
  status_json "$dir" > "$dir/th-status.json"
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_write "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "status --json" ] || exit 3
[ -n "${FM_FAKE_TH_FAIL:-}" ] && exit 1
cat "$FM_FAKE_TH_STATUS"
SH
  fm_fakebin_write "$fakebin/cargo-sweep" <<'SH'
#!/usr/bin/env bash
printf '%s | cwd=%s\n' "$*" "$PWD" >> "$FM_FAKE_SWEEP_LOG"
SH
  chmod +x "$fakebin/treehouse" "$fakebin/cargo-sweep"
  : > "$dir/sweep.log"
  # Slot 4 is claimed by a task; slot 5 is named by a task record without a claim.
  printf 'task=holder\nhome=%s\n' "$dir/home" > "$dir/pools/proj-abc/4/.fm-slot-owner"
  fm_write_meta "$dir/home/state/legacy.meta" "worktree=$dir/pools/proj-abc/5/project" "kind=ship"
  printf '%s\n' "$dir"
}

# Slot 1 and 4-6 available, slot 2 in use by a process, slot 3 leased.
status_json() {  # <case-dir>
  local p="$1/pools/proj-abc"
  printf '[{"name":"1","path":"%s/1/project","status":"available","lease_holder":"","processes":[]},' "$p"
  printf '{"name":"2","path":"%s/2/project","status":"in-use","lease_holder":"","processes":[{"pid":1,"name":"cargo"}]},' "$p"
  printf '{"name":"3","path":"%s/3/project","status":"available","lease_holder":"fm-home","processes":[]},' "$p"
  printf '{"name":"4","path":"%s/4/project","status":"available","lease_holder":"","processes":[]},' "$p"
  printf '{"name":"5","path":"%s/5/project","status":"available","lease_holder":"","processes":[]},' "$p"
  printf '{"name":"6","path":"%s/6/project","status":"available","lease_holder":"","processes":[]}]\n' "$p"
}

run_sweep() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
    FM_TREEHOUSE_POOL_ROOT="$dir/pools" FM_FAKE_TH_STATUS="$dir/th-status.json" \
    FM_FAKE_SWEEP_LOG="$dir/sweep.log" PATH="$dir/fakebin:$PATH" \
    "$SWEEP" "$@" 2>&1
}

test_sweep_touches_only_idle_rust_copies() {
  local dir out rc=0 p
  dir=$(make_pool_case sweep-idle)
  p="$dir/pools/proj-abc"
  out=$(run_sweep "$dir") || rc=$?
  expect_code 0 "$rc" "the sweep failed: $out"
  assert_equals "sweep --maxsize 15GB $p/1/project | cwd=$p/1/project
sweep --time 2 $p/1/project | cwd=$p/1/project" "$(cat "$dir/sweep.log")" \
    "the sweep ran cargo-sweep on something other than the one idle copy"
  assert_contains "$out" "skip: $p/2/project: treehouse reports it in-use" "the in-use copy was not reported"
  assert_contains "$out" "skip: $p/3/project: leased to fm-home" "the leased copy was not reported"
  assert_contains "$out" "skip: $p/4/project: claimed by task holder" "the claimed copy was not reported"
  assert_contains "$out" "skip: $p/5/project: named by task record $dir/home/state/legacy.meta" \
    "the copy a task record names was not reported"
  assert_not_contains "$out" "$p/6/project" "a copy without a Rust target was considered"
  assert_contains "$out" "sweep: checked 5 Rust copies under $dir/pools" "the summary miscounted"

  : > "$dir/sweep.log"
  out=$(run_sweep "$dir" --dry-run --max-size 5GB --age-days 3) || rc=$?
  expect_code 0 "$rc" "the dry-run sweep failed: $out"
  assert_equals "sweep --dry-run --maxsize 5GB $p/1/project | cwd=$p/1/project
sweep --dry-run --time 3 $p/1/project | cwd=$p/1/project" "$(cat "$dir/sweep.log")" \
    "the dry run did not pass --dry-run and the chosen cap and age"
  assert_contains "$out" "(dry run, nothing removed)" "the dry run did not say it removed nothing"
  pass "the sweep caps and ages only copies Treehouse, slot claims, and task records all show idle"
}

test_sweep_fails_safe_on_unreadable_state_and_held_locks() {
  local dir out p lock ready holder i=0
  dir=$(make_pool_case sweep-safe)
  p="$dir/pools/proj-abc"
  out=$(FM_FAKE_TH_FAIL=1 run_sweep "$dir")
  [ ! -s "$dir/sweep.log" ] || fail "the sweep ran with an unreadable Treehouse status: $(cat "$dir/sweep.log")"
  assert_contains "$out" "skip: $p/1/project: treehouse status is unreadable" "the unreadable status was not reported"

  printf 'not a claim\n' > "$p/1/.fm-slot-owner"
  out=$(run_sweep "$dir")
  [ ! -s "$dir/sweep.log" ] || fail "the sweep ran on a copy with an unreadable claim"
  assert_contains "$out" "skip: $p/1/project: its slot-owner claim is unreadable" "the unreadable claim was not reported"
  rm "$p/1/.fm-slot-owner"

  lock=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$dir/project")
  ready="$dir/lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "could not stage a held project lock"
  out=$(run_sweep "$dir")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -s "$dir/sweep.log" ] || fail "the sweep ran while a spawn held the project lock"
  assert_contains "$out" "skip: $p/1/project: a spawn or cleanup holds the project lock" "the held lock was not reported"
  pass "an unreadable Treehouse status, an unreadable claim, or a held project lock skips the copy"
}

test_sweep_usage_and_missing_tool() {
  local dir out rc
  dir=$(make_pool_case sweep-usage)
  rc=0; run_sweep "$dir" --max-size >/dev/null || rc=$?
  expect_code 2 "$rc" "a missing --max-size value was accepted"
  rc=0; run_sweep "$dir" --age-days 0 >/dev/null || rc=$?
  expect_code 2 "$rc" "a zero age was accepted"
  rc=0; run_sweep "$dir" --max-size lots >/dev/null || rc=$?
  expect_code 2 "$rc" "a malformed size was accepted"
  rm "$dir/fakebin/cargo-sweep"
  rc=0
  out=$(FM_HOME="$dir/home" FM_TREEHOUSE_POOL_ROOT="$dir/pools" \
    PATH="$dir/fakebin:$(fm_test_base_path_sans "$PATH" cargo-sweep)" "$SWEEP" 2>&1) || rc=$?
  expect_code 1 "$rc" "a sweep without cargo-sweep did not refuse: $out"
  assert_contains "$out" "cargo-sweep is not installed" "the missing tool was not named"
  pass "the sweep refuses malformed options and a missing cargo-sweep"
}

test_trim_form_applies_only_to_an_idle_copy() {
  local dir out rc=0 p
  dir=$(make_pool_case trim-cli)
  p="$dir/pools/proj-abc"
  out=$(run_sweep "$dir" trim --dry-run "$p/1/project") || rc=$?
  expect_code 0 "$rc" "the dry-run trim form failed: $out"
  assert_contains "$out" "would free" "the dry-run trim form did not report"
  assert_untouched "$p/1/project" "dry-run trim form"
  out=$(run_sweep "$dir" trim "$p/1/project") || rc=$?
  expect_code 0 "$rc" "the trim form failed: $out"
  assert_trimmed "$p/1/project" "trim form"
  out=$(run_sweep "$dir" trim "$p/2/project") || rc=$?
  assert_contains "$out" "skip: $p/2/project: treehouse reports it in-use" "the busy copy was not refused"
  assert_untouched "$p/2/project" "trim form on a busy copy"
  [ ! -s "$dir/sweep.log" ] || fail "the trim form ran cargo-sweep"
  pass "the trim form trims an idle copy and leaves a busy one alone"
}

# --- teardown wiring --------------------------------------------------------

make_teardown_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool/1"
  make_rust_project "$dir/project"
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  seed_target "$dir/pool/1/project"
  seed_target "$dir/project"
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_write "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_fakebin_write "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_RUNTIME_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  : > "$dir/runtime.log"
  printf '%s\n' "$dir"
}

run_teardown() {  # <case-dir> <id>
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$1/runtime.log" \
    PATH="$1/fakebin:$PATH" "$TEARDOWN" "$2" --force 2>&1
}

test_teardown_trims_the_returned_copy_only() {
  local dir id=rust-task out rc=0
  dir=$(make_teardown_case teardown-trim)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=scout"
  printf 'task=%s\nhome=%s\n' "$id" "$dir/home" > "$dir/pool/1/.fm-slot-owner"
  out=$(run_teardown "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "teardown of a Rust pool copy failed: $out"
  assert_contains "$out" "trim: $dir/pool/1/project: freed" "teardown did not report the trim"
  assert_trimmed "$dir/pool/1/project" "teardown"
  assert_untouched "$dir/project" "the project clone during teardown"
  grep -Fq "treehouse return" "$dir/runtime.log" || fail "teardown did not return the copy: $(cat "$dir/runtime.log")"

  dir=$(make_teardown_case teardown-reassigned)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/pool/1/project" "project=$dir/project" "kind=scout"
  printf 'task=someone-else\nhome=%s\n' "$dir/home" > "$dir/pool/1/.fm-slot-owner"
  out=$(run_teardown "$dir" "$id") || rc=$?
  expect_code 0 "$rc" "teardown of a reassigned copy failed: $out"
  assert_untouched "$dir/pool/1/project" "a copy another task has claimed"
  pass "teardown trims the Rust copy it returns, and never the project clone or a copy another task claimed"
}

test_trim_removes_caches_and_executables_and_keeps_libraries
test_trim_only_touches_ignored_rust_targets
test_trim_reports_undeletable_paths_and_still_succeeds
test_free_space_verdict_thresholds
test_sweep_touches_only_idle_rust_copies
test_sweep_fails_safe_on_unreadable_state_and_held_locks
test_sweep_usage_and_missing_tool
test_trim_form_applies_only_to_an_idle_copy
test_teardown_trims_the_returned_copy_only
