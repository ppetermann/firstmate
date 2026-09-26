#!/usr/bin/env bash
# tests/fm-worker-tmp-root.test.sh - the optional real-disk per-task temp root
# (config/worker-tmp-root; bin/fm-task-tmp-lib.sh owns the contract).
#
# The spawn cases drive the real bin/fm-spawn.sh against a fake pane and a real
# isolated git worktree, then EXECUTE the launch the pane received with the
# harness replaced by a probe that prints the temp variables it started with,
# so the assertions read what an agent would have seen rather than the command
# text. Teardown of a relocated root is covered in tests/fm-gotmp.test.sh
# beside the default-root cases.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-tmp-root)
DEFAULT_ROOTS=()

cleanup_default_roots() {
  local d
  for d in "${DEFAULT_ROOTS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap cleanup_default_roots EXIT

path_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# make_case <name> <id> -> "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>"
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

install_tmp_probe() {  # <fakebin>
  fm_fakebin_write "$1/codex" <<'SH'
#!/bin/sh
printf 'TMPDIR=%s TMP=%s TEMP=%s\n' "${TMPDIR-unset}" "${TMP-unset}" "${TEMP-unset}"
SH
  chmod +x "$1/codex"
}

# Replays the pane exports then the launch in a synthetic pane whose own TMPDIR
# is a contrary value, so a launch that merely inherited the pane is caught.
emitted_launch_tmp() {
  local launch preamble
  launch=$(cat "$LAUNCH_LOG")
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane TMPDIR=/contrary TMP=/contrary TEMP=/contrary \
    /bin/sh -c "$preamble
$launch"
}

test_config_absent_keeps_default_root() {
  local id=wtr-absent-a1 rec out status seen
  rec=$(make_case absent "$id")
  read_case "$rec"
  DEFAULT_ROOTS+=("/tmp/fm-$id")
  fm_test_remove_tree "/tmp/fm-$id"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without config/worker-tmp-root should succeed: $out"
  assert_grep "tasktmp=/tmp/fm-$id" "$HOME_DIR/state/$id.meta" \
    "config absent: the task record must keep the /tmp/fm-<id> root"
  assert_present "/tmp/fm-$id/gotmp" "config absent: the default root must still hold gotmp/"
  assert_absent "/tmp/fm-$id/tmp" "config absent: no TMPDIR directory may be created"
  assert_absent "/tmp/fm-$id/.fm-home" "config absent: the default root must carry no ownership marker"
  ! grep -Eq '(^|[^A-Z_])TMPDIR=' "$PANE_LOG" \
    || fail "config absent: the pane must not receive a TMPDIR export"
  ! grep -Eq '(^|[^A-Z_])TMPDIR=' "$LAUNCH_LOG" \
    || fail "config absent: the launch must not set TMPDIR"
  install_tmp_probe "$FAKEBIN_DIR"
  seen=$(emitted_launch_tmp) || fail "config absent: the emitted launch failed to run"
  assert_equals "TMPDIR=/contrary TMP=/contrary TEMP=/contrary" "$seen" \
    "config absent: the agent must keep the pane's own temp variables"
  pass "config absent: spawn keeps /tmp/fm-<id> with GOTMPDIR only and leaves TMPDIR alone"
}

test_config_present_relocates_and_exports() {
  local id=wtr-present-a1 rec out status seen base base_real root allowlist
  for allowlist in absent enabled; do
    rec=$(make_case "present-$allowlist" "$id")
    read_case "$rec"
    base="$CASE_DIR/disk/fm-tmp"
    printf '%s\n' "$base" > "$HOME_DIR/config/worker-tmp-root"
    [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
    status=$?
    expect_code 0 "$status" "spawn with config/worker-tmp-root (allowlist $allowlist) should succeed: $out"
    base_real=$(cd -P "$base" && pwd -P)
    root="$base_real/fm-$id"
    assert_grep "tasktmp=$root" "$HOME_DIR/state/$id.meta" \
      "config present: the task record must name the relocated root"
    assert_equals 700 "$(path_mode "$root")" "config present: the relocated root must be private"
    assert_equals 700 "$(path_mode "$base_real")" "config present: a created base must be private"
    assert_present "$root/gotmp" "config present: gotmp/ must live in the relocated root"
    assert_present "$root/tmp" "config present: tmp/ must exist for TMPDIR"
    assert_equals "$(cd -P "$HOME_DIR" && pwd -P)" "$(cat "$root/.fm-home")" \
      "config present: the root must record the home that created it"
    assert_grep "export GOTMPDIR=$root/gotmp" "$PANE_LOG" "config present: GOTMPDIR must follow the root"
    grep -Eq '^export TMPDIR=' "$PANE_LOG" \
      || fail "config present: the pane must receive the TMPDIR export"
    install_tmp_probe "$FAKEBIN_DIR"
    seen=$(emitted_launch_tmp) || fail "config present (allowlist $allowlist): the emitted launch failed to run"
    assert_equals "TMPDIR=$root/tmp TMP=$root/tmp TEMP=$root/tmp" "$seen" \
      "config present (allowlist $allowlist): the agent must start with every temp variable in its root"
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      TMPDIR=/contrary /bin/sh -c "$(cat "$LAUNCH_LOG")") \
      || fail "config present: the launch alone failed to run"
    assert_equals "TMPDIR=$root/tmp TMP=$root/tmp TEMP=$root/tmp" "$seen" \
      "config present (allowlist $allowlist): the launch must set the temp variables without the pane export"
  done
  pass "config present: the root moves to the configured disk, stays private, and every launch exports TMPDIR, TMP, and TEMP into it"
}

test_config_home_relative_value() {
  local id=wtr-tilde-a1 rec out status root
  rec=$(make_case tilde "$id")
  read_case "$rec"
  # fm_test_run_spawn launches with HOME=<home>/user-home.
  # shellcheck disable=SC2088 # The literal ~/ is the value under test.
  printf '%s\n' '~/tmp-disk' > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with a ~/ worker temp root should succeed: $out"
  root="$(cd -P "$HOME_DIR/user-home/tmp-disk" && pwd -P)/fm-$id"
  assert_grep "tasktmp=$root" "$HOME_DIR/state/$id.meta" \
    "a ~/ value must expand against the launching user's HOME"
  pass "config present: a ~/ value expands against the launching user's HOME"
}

test_secondmate_launch_exports_tmpdir() {
  local rec sm out status seen root
  rec=$(make_case secondmate sm-wtr)
  read_case "$rec"
  printf '%s\n' "$CASE_DIR/disk" > "$HOME_DIR/config/worker-tmp-root"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-wtr > "$sm/.fm-secondmate-home"
  printf 'charter for sm-wtr\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_case_spawn sm-wtr "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn with config/worker-tmp-root should succeed: $out"
  root="$(cd -P "$CASE_DIR/disk" && pwd -P)/fm-sm-wtr"
  install_tmp_probe "$FAKEBIN_DIR"
  seen=$(emitted_launch_tmp) || fail "secondmate: the emitted launch failed to run"
  assert_equals "TMPDIR=$root/tmp TMP=$root/tmp TEMP=$root/tmp" "$seen" \
    "a secondmate launch must start with its temp variables in its own root"
  assert_equals "$(cat "$HOME_DIR/config/worker-tmp-root")" "$(cat "$sm/config/worker-tmp-root")" \
    "the setting must be inherited into the secondmate home"
  pass "a secondmate launch exports TMPDIR into its own root and inherits the setting"
}

test_unsafe_roots_are_refused() {
  local id=wtr-unsafe-a1 rec out status base root
  # A pre-existing per-task root writable by others.
  rec=$(make_case unsafe-root "$id")
  read_case "$rec"
  base="$CASE_DIR/disk"
  mkdir -p "$base/fm-$id"
  chmod 700 "$base"
  chmod 777 "$base/fm-$id"
  printf '%s\n' "$base" > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a world-writable pre-existing task temp root"
  assert_contains "$out" "is not a private directory owned by this user" \
    "the refusal must name the unsafe task temp root"
  [ ! -s "$LAUNCH_LOG" ] || fail "spawn launched despite an unsafe task temp root"
  assert_absent "$base/fm-$id/.fm-home" "a refused root must not be claimed"

  # A pre-existing root that is a symlink.
  rec=$(make_case unsafe-link "$id")
  read_case "$rec"
  base="$CASE_DIR/disk"
  mkdir -p "$base" "$CASE_DIR/elsewhere"
  chmod 700 "$base"
  ln -s "$CASE_DIR/elsewhere" "$base/fm-$id"
  printf '%s\n' "$base" > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a symlinked task temp root"
  [ ! -s "$LAUNCH_LOG" ] || fail "spawn launched through a symlinked task temp root"
  assert_absent "$CASE_DIR/elsewhere/gotmp" "spawn wrote through a symlinked task temp root"

  # A base other users can write into.
  rec=$(make_case unsafe-base "$id")
  read_case "$rec"
  base="$CASE_DIR/disk"
  mkdir -p "$base"
  chmod 777 "$base"
  printf '%s\n' "$base" > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a world-writable worker temp base"
  assert_contains "$out" "not writable by group or others" "the refusal must name the unsafe base"
  [ ! -s "$LAUNCH_LOG" ] || fail "spawn launched under an unsafe worker temp base"
  chmod 700 "$base"

  # A root another home already claimed.
  rec=$(make_case foreign-root "$id")
  read_case "$rec"
  base="$CASE_DIR/disk"
  mkdir -p "$base/fm-$id"
  chmod 700 "$base" "$base/fm-$id"
  printf '%s\n' "$CASE_DIR/other-home" > "$base/fm-$id/.fm-home"
  printf '%s\n' "$base" > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reused a task temp root another home owns"
  assert_contains "$out" "belongs to another firstmate home" "the refusal must name the other owner"
  [ ! -s "$LAUNCH_LOG" ] || fail "spawn launched into another home's task temp root"

  # A malformed value refuses before any endpoint exists.
  rec=$(make_case malformed "$id")
  read_case "$rec"
  printf '%s\n' 'relative/path' > "$HOME_DIR/config/worker-tmp-root"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a relative worker temp root"
  assert_contains "$out" "config/worker-tmp-root must hold an absolute path" "the refusal must explain the value"
  assert_absent "$HOME_DIR/state/$id.meta" "a malformed value must refuse before any task record exists"
  pass "unsafe or foreign task temp roots, unsafe bases, and malformed values are refused before launch"
}

test_brief_carries_cache_rule_only_with_config() {
  local home kind brief
  for kind in ship scout; do
    home="$TMP_ROOT/brief-$kind"
    fm_test_spawn_home "$home"
    if [ "$kind" = ship ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-off "$home/projects/demo" --mode local-only >/dev/null 2>&1 \
        || fail "brief scaffold without config failed ($kind)"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-off "$home/projects/demo" --scout >/dev/null 2>&1 \
        || fail "brief scaffold without config failed ($kind)"
    fi
    brief="$home/data/brief-off/brief.md"
    assert_not_contains "$(cat "$brief")" "shared caches" "config absent: the $kind brief must be unchanged"
    printf '%s\n' "$home/disk" > "$home/config/worker-tmp-root"
    if [ "$kind" = ship ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-on "$home/projects/demo" --mode local-only >/dev/null 2>&1 \
        || fail "brief scaffold with config failed ($kind)"
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-on "$home/projects/demo" --scout >/dev/null 2>&1 \
        || fail "brief scaffold with config failed ($kind)"
    fi
    brief="$home/data/brief-on/brief.md"
    assert_contains "$(cat "$brief")" "Reuse the machine's shared caches (for example ~/.cache/huggingface" \
      "config present: the $kind brief must carry the cache rule"
    assert_contains "$(cat "$brief")" "never point a cache at your scratch or temp directory" \
      "config present: the $kind brief must forbid caches in the temp directory"
    printf '%s\n' 'not absolute' > "$home/config/worker-tmp-root"
    if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-bad "$home/projects/demo" --scout >/dev/null 2>&1; then
      fail "brief scaffold accepted a malformed worker temp root ($kind)"
    fi
    assert_absent "$home/data/brief-bad" "a malformed value must stop the scaffold before anything is written"
  done
  pass "ship and scout briefs carry the cache rule only when config/worker-tmp-root is set"
}

test_inherited_item_is_declared() {
  local items
  items=$(bash -c '. "$1"; fm_config_inherit_items' _ "$ROOT/bin/fm-config-inherit-lib.sh")
  assert_contains "$items" "config/worker-tmp-root" "the setting must be part of secondmate inheritance"
  pass "config/worker-tmp-root is declared inherited material"
}

test_orphan_report() {
  local home other base out lib
  lib="$ROOT/bin/fm-task-tmp-lib.sh"
  home="$TMP_ROOT/orphan-home"
  other="$TMP_ROOT/orphan-other-home"
  base="$TMP_ROOT/orphan-disk"
  mkdir -p "$home/state" "$other" "$base"
  home=$(cd -P "$home" && pwd -P)
  other=$(cd -P "$other" && pwd -P)
  base=$(cd -P "$base" && pwd -P)
  mkdir -p "$base/fm-live" "$base/fm-gone" "$base/fm-sibling" "$base/fm-deadhome" "$base/fm-nomarker"
  printf '%s\n' "$home" > "$base/fm-live/.fm-home"
  printf '%s\n' "$home" > "$base/fm-gone/.fm-home"
  head -c 4096 /dev/zero > "$base/fm-gone/leftover"
  printf '%s\n' "$other" > "$base/fm-sibling/.fm-home"
  printf '%s\n' "$TMP_ROOT/no-such-home" > "$base/fm-deadhome/.fm-home"
  printf 'tasktmp=%s\n' "$base/fm-live" > "$home/state/live.meta"
  out=$(bash -c '. "$1"; fm_task_tmp_orphans "$2" "$3" "$4"' _ "$lib" "$base" "$home" "$home/state")
  assert_contains "$out" "TASK_TMP_ORPHAN: $base/fm-gone (" "an unreferenced root of this home must be reported"
  assert_contains "$out" "no task record in this home names it" "the report must say why"
  assert_contains "$out" "TASK_TMP_ORPHAN: $base/fm-deadhome (" "a root whose home is gone must be reported"
  assert_contains "$out" "TASK_TMP_ORPHAN: $base/fm-nomarker (" "an unmarked root must be reported"
  assert_not_contains "$out" "fm-live" "a root a task record names must not be reported"
  assert_not_contains "$out" "fm-sibling" "another live home's root must not be reported"
  assert_present "$base/fm-gone/leftover" "the report must never delete anything"
  out=$(FM_TASK_TMP_ORPHAN_LIMIT=1 bash -c '. "$1"; fm_task_tmp_orphans "$2" "$3" "$4"' _ "$lib" "$base" "$home" "$home/state")
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^TASK_TMP_ORPHAN:')" \
    "a capped report prints the limit plus one count line"
  assert_contains "$out" "2 more orphaned task temp root(s)" "a capped report must count the rest"

  # Session start surfaces it through bootstrap's local detection, and only
  # when the setting exists.
  mkdir -p "$home/config" "$home/data"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK_PHASE=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "TASK_TMP_ORPHAN" "config absent: bootstrap must not scan for leftover roots"
  printf '%s\n' "$base" > "$home/config/worker-tmp-root"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK_PHASE=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "TASK_TMP_ORPHAN: $base/fm-gone (" "config present: bootstrap must report leftover roots"
  pass "leftover task temp roots are reported with sizes, capped, surfaced by bootstrap, and never deleted"
}

test_config_absent_keeps_default_root
test_config_present_relocates_and_exports
test_config_home_relative_value
test_secondmate_launch_exports_tmpdir
test_unsafe_roots_are_refused
test_brief_carries_cache_rule_only_with_config
test_inherited_item_is_declared
test_orphan_report
