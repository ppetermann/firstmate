#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# The fm_fakebin_write cases below pin the fixture write carrier, which now
# lives in tests/fakebin-write.sh so the suites that cannot source tests/lib.sh
# can still reach it; that file's header owns its contract. What makes the
# carrier MANDATORY rather than merely available is bin/fm-lint.sh's
# fixture-write purity check, pinned by tests/fm-lint.test.sh against the
# corpus in tests/assets/fixture-write-purity-corpus.tsv.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout fakebin rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  fakebin=$(fm_fakebin "$dir/standalone")
  fm_fake_exit0 "$fakebin" pi
  fm_fakebin_write "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    git -C "$2" log -1 --format=%s > "${FM_TEST_STANDALONE_COMMIT:?}"
    exit 1
  fi
  shift
done
SH
  chmod +x "$fakebin/tmux"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  bash -eus -- "$ROOT/tests/herdr-test-safety.sh" "$dir/global-herdr" <<'SH' || exit 1
. "$1"
git init -q "$2"
git -C "$2" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m initial
[ "$(git -C "$2" log -1 --format=%s)" = initial ]
SH
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  rc=0
  FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=HEAD \
    FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated \
    FM_TEST_STANDALONE_COMMIT="$dir/global-standalone-commit" PATH="$fakebin:$PATH" \
    bash "$ROOT/tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh" \
    > "$dir/standalone.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "standalone fixture did not stop at the tmux launch"
  assert_grep 'could not start isolated Pi session' "$dir/standalone.log" \
    "standalone fixture failed before the tmux launch: $(cat "$dir/standalone.log")"
  [ "$(cat "$dir/global-standalone-commit")" = 'test: initial instruction contract' ] \
    || fail "standalone fixture did not create its initial commit"
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

# 2026-09-15: a fixture symlinked a fakebin `jq` entry to the real host jq, and
# a later `cat > <fakebin>/jq` in the same test followed that symlink and
# overwrote the real binary with a stub. fm_fakebin_write (tests/lib.sh) is the
# carrier that answers that shape; its header owns what it does and does not
# cover. The three cases below pin its two guarantees and, separately, the
# routing that carries them to the shared fixture helpers.

test_fakebin_write_replaces_symlinked_entry() {
  local dir="$TMP_ROOT/symlink-trap" fakebin outside real_tool before after
  fakebin=$(fm_fakebin "$dir")
  outside="$dir/outside-host-tools"
  mkdir -p "$outside"
  real_tool="$outside/jq"
  printf '#!/usr/bin/env bash\necho real jq output\n' > "$real_tool"
  chmod +x "$real_tool"
  before=$(cat "$real_tool")

  ln -s "$real_tool" "$fakebin/jq"
  fm_fakebin_write "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  [ -e "$real_tool" ] || fail "writing through a symlinked fakebin entry deleted the real tool it pointed at"
  after=$(cat "$real_tool")
  [ "$before" = "$after" ] || fail "writing through a symlinked fakebin entry altered the real tool's bytes"
  [ ! -L "$fakebin/jq" ] || fail "fakebin entry should be a regular file after fm_fakebin_write, not still a symlink"
  [ -f "$fakebin/jq" ] || fail "fakebin entry should exist as a regular file after fm_fakebin_write"
  assert_grep 'exit 0' "$fakebin/jq" "fakebin entry did not receive the stub content"
  pass "fm_fakebin_write replaces a symlinked fixture entry instead of writing through it to the real tool"
}

# The other half of the same defect, and the half unlinking cannot answer: the
# fakebin ENTRY is an ordinary name but its DIRECTORY is a symlink to somewhere
# real. Unlinking there would delete the real file outright, so the carrier has
# to refuse. The temp base is moved under the fixture for the duration of the
# call so "outside the temp base" is reproduced exactly as a live repository
# checkout sits outside it, without this case going anywhere near a real one.
test_fakebin_write_refuses_symlinked_parent_directory() {
  local dir="$TMP_ROOT/symlink-parent" real before after err rc=0
  mkdir -p "$dir/outside/bin" "$dir/fixture" "$dir/tempbase"
  real="$dir/outside/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\n# a real repository script\n' > "$real"
  before=$(cat "$real")
  ln -s "$dir/outside/bin" "$dir/fixture/bin"

  err=$(printf '#!/usr/bin/env bash\nexit 0\n' |
    TMPDIR="$dir/tempbase" fm_fakebin_write "$dir/fixture/bin/fm-guard.sh" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "fm_fakebin_write wrote through a symlinked parent directory instead of refusing"
  [ -e "$real" ] || fail "fm_fakebin_write DELETED the real file its symlinked parent directory pointed at"
  after=$(cat "$real")
  [ "$before" = "$after" ] || fail "fm_fakebin_write altered the real file its symlinked parent directory pointed at"
  case $err in
    *"$dir/outside/bin/fm-guard.sh"*) ;;
    *) fail "the refusal did not name where the write would really have landed: $err" ;;
  esac
  pass "fm_fakebin_write refuses a write whose directory is a symlink out of the fixture, naming the real destination"
}

# The routing is the load-bearing part, and it is the part nothing else pins:
# fm_fakebin_write can stay perfect while any single helper quietly goes back to
# a bare `cat >` redirect, and every assertion above still passes. So exercise
# each routed helper for real against a fixture entry symlinked to a file
# outside it. A helper that stops routing fails here, by name.
#
# The table is a hand-kept inventory of the routed writes, not a discovered one:
# it catches a helper that STOPS routing, and a new helper has to be added here
# to be covered at all. What catches a helper, or any other suite, that never
# routed in the first place is bin/fm-lint.sh's fixture-write purity check.
# Row format: <label>|<library>|<entry it writes>|<snippet>. The entry may name
# a subdirectory when the helper writes into one, as a fixture home's bin/ is. The snippet runs in a child shell with that library sourced and
# DIR, FAKEBIN, TMP_ROOT and NAME pointing at the planted fixture, so each
# helper is driven through its own public signature, never through its source
# text.
# The snippets are deliberately single-quoted: $FAKEBIN, $DIR and $NAME must
# reach the child shell literally and expand there, against the planted
# fixture, not here against this suite's own scope.
# shellcheck disable=SC2016
FM_ROUTED_FAKEBIN_HELPERS=(
  'fm_fake_exit0|lib.sh|jq|fm_fake_exit0 "$FAKEBIN" jq'
  'fm_fake_crash_injector|lib.sh|fm-crash-inject|fm_fake_crash_injector "$FAKEBIN"'
  'fm_fake_blind_ancestry|lib.sh|ps|fm_fake_blind_ancestry "$FAKEBIN"'
  'fm_fake_version_tool|lib.sh|node|fm_fake_version_tool "$FAKEBIN" node FM_TEST_ROUTING_VERSION 1.2.3'
  'fm_test_fake_no_mistakes|fixtures.sh|no-mistakes|fm_test_fake_no_mistakes "$FAKEBIN"'
  'fm_test_fake_gh|fixtures.sh|gh|fm_test_fake_gh "$FAKEBIN"'
  'fm_test_fake_tmux_spawn|fixtures.sh|tmux|fm_test_fake_tmux_spawn "$FAKEBIN"'
  'fm_test_fake_tmux_send|fixtures.sh|tmux|fm_test_fake_tmux_send "$FAKEBIN"'
  'fm_test_fake_ssh|fixtures.sh|fake-ssh|fm_test_fake_ssh "$FAKEBIN"'
  'fm_test_fake_sleep_noop|fixtures.sh|sleep|fm_test_fake_sleep_noop "$FAKEBIN"'
  'fm_test_fake_sleep_log|fixtures.sh|sleep|fm_test_fake_sleep_log "$FAKEBIN"'
  'make_fake_crew_state|wake-helpers.sh|fm-crew-state.sh|make_fake_crew_state "$FAKEBIN"'
  'make_case|wake-helpers.sh|tmux|make_case "$NAME"'
  'make_supercase|wake-helpers.sh|tmux|make_supercase "$NAME"'
  'make_bordered_case|wake-helpers.sh|tmux|make_bordered_case "$NAME"'
  'make_fake_tmux_tmux|secondmate-helpers.sh|tmux|make_fake_tmux "$DIR"'
  'make_fake_tmux_treehouse|secondmate-helpers.sh|treehouse|make_fake_tmux "$DIR"'
  'make_firstmate_git_root|secondmate-helpers.sh|bin/fm-guard.sh|make_firstmate_git_root "$FAKEBIN"'
)

assert_routed_helper_protects_real_tool() {  # <label> <library> <entry> <snippet>
  local label=$1 lib=$2 entry=$3 snippet=$4
  local dir="$TMP_ROOT/routing/$label" real before after rc=0

  rm -rf "$dir"
  # A routed helper may write into a subdirectory of the fixture (a fixture
  # home's bin/, say), so plant the entry at whatever depth it names.
  case $entry in
    */*) mkdir -p "$dir/fakebin/${entry%/*}" "$dir/outside/${entry%/*}" ;;
    *) mkdir -p "$dir/fakebin" "$dir/outside" ;;
  esac
  real="$dir/outside/$entry"
  printf '#!/usr/bin/env bash\necho real %s\n' "$entry" > "$real"
  chmod +x "$real"
  before=$(cat "$real")
  ln -s "$real" "$dir/fakebin/$entry"

  FM_ROUTING_DIR="$dir" FM_ROUTING_NAME="$label" bash -c '
    set -u
    . "$1"
    DIR=$FM_ROUTING_DIR
    FAKEBIN=$DIR/fakebin
    TMP_ROOT=$(dirname "$DIR")
    NAME=$FM_ROUTING_NAME
    eval "$2"
  ' _ "$ROOT/tests/$lib" "$snippet" >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || fail "$lib: $label did not run to completion (rc=$rc)"
  [ -e "$real" ] || fail "$lib: $label deleted the real tool its fixture entry pointed at - it is not routed through fm_fakebin_write"
  after=$(cat "$real")
  [ "$before" = "$after" ] || fail "$lib: $label wrote through a symlinked fixture entry and altered the real tool - it is not routed through fm_fakebin_write"
  if [ ! -f "$dir/fakebin/$entry" ] || [ -L "$dir/fakebin/$entry" ]; then
    fail "$lib: $label left $entry a symlink instead of replacing it with a regular file"
  fi
}

test_shared_fixture_helpers_route_their_stub_writes() {
  local row label lib entry snippet
  for row in "${FM_ROUTED_FAKEBIN_HELPERS[@]}"; do
    IFS='|' read -r label lib entry snippet <<<"$row"
    assert_routed_helper_protects_real_tool "$label" "$lib" "$entry" "$snippet"
  done
  pass "all ${#FM_ROUTED_FAKEBIN_HELPERS[@]} inventoried fixture-helper stub writes still go through fm_fakebin_write"
}

# --append is the shape the migration needed that the carrier did not yet have:
# a handful of fixtures extend a stub they already wrote rather than replacing
# it. It keeps the parent guarantee and adds one of its own, because appending
# through a leaf symlink has no "the caller owns this entry" reading the way
# replacing it does - it can only mean the caller believed it owned bytes that
# actually live in the real tool.
test_fakebin_write_append_extends_an_entry_it_owns() {
  local dir="$TMP_ROOT/append" fakebin body
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_write "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf first\n
SH
  fm_fakebin_write --append "$fakebin/ps" <<'SH'
printf second\n
SH
  body=$(cat "$fakebin/ps")
  case $body in
    *first*second*) ;;
    *) fail "fm_fakebin_write --append did not extend the entry, got: $body" ;;
  esac
  [ -f "$fakebin/ps" ] || fail "appended fakebin entry should be a regular file"
  pass "fm_fakebin_write --append extends a fixture entry it already wrote"
}

test_fakebin_write_append_refuses_a_symlinked_entry() {
  local dir="$TMP_ROOT/append-symlink" fakebin outside real_tool before after err rc=0
test_no_mistakes_init_doctor_markers
test_no_mistakes_init_doctor_markers
  fakebin=$(fm_fakebin "$dir")
  outside="$dir/outside-host-tools"
  mkdir -p "$outside"
  real_tool="$outside/jq"
  printf '#!/usr/bin/env bash\necho real jq output\n' > "$real_tool"
  chmod +x "$real_tool"
  before=$(cat "$real_tool")
  ln -s "$real_tool" "$fakebin/jq"

  err=$(printf 'appended\n' | fm_fakebin_write --append "$fakebin/jq" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "fm_fakebin_write --append wrote through a symlinked entry instead of refusing"
  after=$(cat "$real_tool")
  [ "$before" = "$after" ] || fail "fm_fakebin_write --append altered the real tool its fixture entry pointed at"
  case $err in
    *"$real_tool"*) ;;
    *) fail "the refusal did not name the real file the append would have reached: $err" ;;
  esac
  pass "fm_fakebin_write --append refuses a symlinked fixture entry instead of appending to the real tool"
}

test_fakebin_write_append_refuses_a_symlinked_parent_directory() {
  local dir="$TMP_ROOT/append-parent" real before after err rc=0
  mkdir -p "$dir/outside/bin" "$dir/fixture" "$dir/tempbase"
  real="$dir/outside/bin/fm-guard.sh"
  printf '#!/usr/bin/env bash\n# a real repository script\n' > "$real"
  before=$(cat "$real")
  ln -s "$dir/outside/bin" "$dir/fixture/bin"

  err=$(printf 'appended\n' |
    TMPDIR="$dir/tempbase" fm_fakebin_write --append "$dir/fixture/bin/fm-guard.sh" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "fm_fakebin_write --append wrote through a symlinked parent directory instead of refusing"
  after=$(cat "$real")
  [ "$before" = "$after" ] || fail "fm_fakebin_write --append altered the real file its symlinked parent pointed at"
  case $err in
    *"$dir/outside/bin/fm-guard.sh"*) ;;
    *) fail "the refusal did not name where the append would really have landed: $err" ;;
  esac
  pass "fm_fakebin_write --append refuses a write whose directory is a symlink out of the fixture"
}

# The carrier is reachable without tests/lib.sh, which is the whole reason it
# moved into its own file: seven suites drive real Herdr or real quota tooling
# and cannot take the library's traps, umask and Git isolation, but still write
# stubs into a fixture tool directory. Source it the way they do - in a child
# shell with no library at all - and drive it against a planted symlink.
test_fakebin_write_is_reachable_without_the_test_library() {
  local dir="$TMP_ROOT/standalone-carrier" real before after rc=0
  mkdir -p "$dir/fakebin" "$dir/outside"
  real="$dir/outside/jq"
  printf '#!/usr/bin/env bash\necho real jq\n' > "$real"
  chmod +x "$real"
  before=$(cat "$real")
  ln -s "$real" "$dir/fakebin/jq"

  bash -c '
    set -u
    [ -z "${FM_TEST_LIB_SOURCED:-}" ] || { echo "the test library leaked into the child shell" >&2; exit 2; }
    . "$1"
    printf "stub\n" | fm_fakebin_write "$2/fakebin/jq"
  ' _ "$ROOT/tests/fakebin-write.sh" "$dir" || rc=$?

  [ "$rc" -eq 0 ] || fail "sourcing tests/fakebin-write.sh alone did not provide a working carrier (rc=$rc)"
  [ -e "$real" ] || fail "the standalone carrier deleted the real tool its fixture entry pointed at"
  after=$(cat "$real")
  [ "$before" = "$after" ] || fail "the standalone carrier wrote through the symlink and altered the real tool"
  [ ! -L "$dir/fakebin/jq" ] || fail "the standalone carrier left the entry a symlink"
  assert_grep stub "$dir/fakebin/jq" "the standalone carrier did not write the stub"
  pass "tests/fakebin-write.sh provides the carrier on its own, with no tests/lib.sh"
}

# Unlinking is what makes the leaf answer safe, and it is also what nearly broke
# the migration onto this carrier: fixtures write a stub once with a chmod +x
# and then rewrite it per case with no chmod at all, which a plain `cat >`
# truncation kept executable and a naive unlink-then-write did not. Replacing an
# entry must therefore leave its mode exactly where the redirect would have.
test_fakebin_write_preserves_the_replaced_entrys_mode() {
  local dir="$TMP_ROOT/mode" fakebin outside real_tool before after
  fakebin=$(fm_fakebin "$dir")

  fm_fakebin_write "$fakebin/tool" <<'SH'
#!/usr/bin/env bash
echo first
SH
  chmod +x "$fakebin/tool"
  before=$(stat -Lc %a "$fakebin/tool" 2>/dev/null || stat -Lf %Lp "$fakebin/tool")
  fm_fakebin_write "$fakebin/tool" <<'SH'
#!/usr/bin/env bash
echo second
SH
  after=$(stat -Lc %a "$fakebin/tool" 2>/dev/null || stat -Lf %Lp "$fakebin/tool")
  [ "$before" = "$after" ] \
    || fail "rewriting a fixture entry changed its mode from $before to $after"
  [ -x "$fakebin/tool" ] || fail "rewriting an executable fixture entry left it non-executable"
  [ "$("$fakebin/tool")" = second ] || fail "the rewritten entry did not run the new stub"

  # Replacing a symlinked real tool should leave a stub as runnable as the tool.
  outside="$dir/outside"
  mkdir -p "$outside"
  real_tool="$outside/jq"
  printf '#!/usr/bin/env bash\necho real jq\n' > "$real_tool"
  chmod +x "$real_tool"
  ln -s "$real_tool" "$fakebin/jq"
  fm_fakebin_write "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
echo stub jq
SH
  [ -x "$fakebin/jq" ] || fail "replacing a symlinked real tool left the stub non-executable"
  [ "$("$fakebin/jq")" = 'stub jq' ] || fail "the replacement stub did not run"
  [ "$(cat "$real_tool")" = "$(printf '#!/usr/bin/env bash\necho real jq')" ] \
    || fail "replacing the symlinked entry altered the real tool"

  # A path that did not exist takes the umask default, as the redirect would.
  fm_fakebin_write "$fakebin/fresh" <<'SH'
new
SH
  [ ! -x "$fakebin/fresh" ] || fail "a newly created fixture entry should not be executable by itself"
  pass "fm_fakebin_write keeps the mode of the entry it replaces and defaults a new one"
}

# A host whose `sleep` is a multicall coreutils (uutils on Ubuntu 26.04) refuses
# to run under a foreign name, so a harness-named symlink to it never becomes a
# live process. The fake `sleep` below models that refusal on any host, which
# keeps this case meaningful where CI's own `sleep` is single-purpose.
test_agent_standin_survives_a_multicall_sleep() (
  local dir="$TMP_ROOT/standin" fakebin real_sleep standin pid
  real_sleep=$(command -v sleep) || fail "sleep not found"
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_write "$fakebin/sleep" <<SH
#!/usr/bin/env bash
case "\${0##*/}" in
  sleep) exec "$real_sleep" "\$@" ;;
  *) echo "Requested utility \${0##*/} does not match executable name" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/sleep"
  ln -s "$fakebin/sleep" "$dir/pi"
  "$fakebin/sleep" 0 || fail "the fake multicall sleep must run under its own name"
  if "$dir/pi" 0 2>/dev/null; then
    fail "the fake multicall sleep must refuse a harness name, or this case proves nothing"
  fi

  if standin=$(PATH="$fakebin:$(fm_test_base_path_sans "$PATH" cc gcc)" fm_agent_standin "$dir/nocc"); then
    fail "without a compiler, a multicall sleep must not be offered as a stand-in, got '$standin'"
  fi
  assert_absent "$dir/nocc/standin" "a refused stand-in must not be left behind"

  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "skip: no C compiler, so the compiled stand-in half of the multicall case cannot run"
    pass "agent stand-in: a multicall sleep is refused rather than offered as a stand-in"
    exit 0
  fi
  standin=$(PATH="$fakebin:$PATH" fm_agent_standin "$dir/cc") \
    || fail "with a compiler, a multicall host sleep must still yield a stand-in"
  ln -s "$standin" "$dir/cc/pi"
  "$dir/cc/pi" 60 &
  pid=$!
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "the stand-in must stay alive under a harness name"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "agent stand-in: a multicall sleep is refused, and the compiled stand-in survives a harness name"
)

# An inherited absolute GIT_DIR (a linked-worktree hook exports one) overrides
# `git -C`, so fixture setup would commit, move refs, and register worktrees in
# the caller's repository; GIT_INDEX_FILE and GIT_COMMON_DIR redirect the index
# and refs the same way, and GIT_WORK_TREE breaks the setup outright. Each entry
# point runs fm-teardown.test.sh's Git setup with each variable aimed in turn at
# a disposable ambient clone, which must come through unchanged.
test_inherited_git_location_isolation() (
  local dir="$TMP_ROOT/git-location" before after var value helper rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  fm_git_init_commit "$dir/ambient"
  git -C "$dir/ambient" worktree add -q --detach "$dir/linked" main
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  cat > "$dir/setup.sh" <<'SH'
case_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-location.XXXXXX")
git init -q --bare "$case_dir/origin.git"
git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
echo seed > "$case_dir/_seed/seed.txt"
git -C "$case_dir/_seed" add seed.txt
git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q -m "origin baseline"
git -C "$case_dir/_seed" push -q origin main
git clone -q "$case_dir/origin.git" "$case_dir/project"
git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
[ "$(git -C "$case_dir/wt" log -1 --format=%s)" = "origin baseline" ]
SH
  { printf '#!/usr/bin/env bash\nset -eu\n'; cat "$dir/setup.sh"; } > "$dir/runner/tests/fm-test-run.test.sh"
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"

  ambient_state() {
    git -C "$dir/ambient" for-each-ref --format='%(refname) %(objectname)'
    git -C "$dir/ambient" worktree list --porcelain
    git -C "$dir/ambient" ls-files --stage
    git -C "$dir/linked" ls-files --stage
  }

  before=$(ambient_state)
  for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR; do
    case $var in
      GIT_DIR) value=$(git -C "$dir/linked" rev-parse --absolute-git-dir) ;;
      GIT_WORK_TREE) value="$dir/linked" ;;
      GIT_INDEX_FILE) value=$(git -C "$dir/linked" rev-parse --path-format=absolute --git-path index) ;;
      GIT_COMMON_DIR) value=$(git -C "$dir/linked" rev-parse --path-format=absolute --git-common-dir) ;;
    esac
    for helper in lib herdr-test-safety runner-1 runner-2; do
      rc=0
      case $helper in
        runner-*)
          env "$var=$value" TMPDIR="$dir" "$dir/runner/bin/fm-test-run.sh" --jobs "${helper#runner-}" \
            tests/fm-test-run.test.sh > "$dir/out.log" 2>&1 || rc=$?
          [ "$rc" != 0 ] || assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/out.log" \
            "$helper did not execute the Git fixture under $var" ;;
        *)
          # shellcheck disable=SC2016 # expanded by the child bash
          env "$var=$value" TMPDIR="$dir" bash -eu -c '. "$1"; . "$2"' _ "$ROOT/tests/$helper.sh" "$dir/setup.sh" \
            > "$dir/out.log" 2>&1 || rc=$? ;;
      esac
      # The ambient check comes first: it is the escape this case exists to catch.
      after=$(ambient_state)
      [ "$before" = "$after" ] \
        || fail "$helper fixture setup under $var changed the ambient repository: $(diff <(echo "$before") <(echo "$after"))"
      [ "$rc" = 0 ] || fail "$helper fixture setup failed under $var: $(cat "$dir/out.log")"
    done
  done
  pass "shared helpers and runner keep fixture Git off an inherited repository location"
)

# A suite started from a Herdr-hosted terminal inherits the launcher's identity,
# its terminal marker, and a supervisor's home/state overrides. Sourcing the
# library must leave none of them for a fixture to bind to, and a value a case
# exports afterwards must still be honored.
test_inherited_launcher_env_is_cleared() (
  local dir="$TMP_ROOT/launcher-env" decoy out rc=0
  decoy="$dir/decoy-home"
  mkdir -p "$decoy/config" "$dir/own-home" "$dir/empty-config"
  printf 'paseo\n' > "$decoy/config/backend"
  # shellcheck disable=SC2016 # expanded by the child bash
  out=$(env -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier \
    HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_TAB_ID=w1:t1 HERDR_WORKSPACE_ID=w1 \
    HERDR_SOCKET_PATH="$decoy/herdr.sock" HERDR_SESSION=host \
    HERDR_BIN_PATH="$decoy/herdr" TERM_PROGRAM=rex FM_BACKEND=paseo \
    FM_HOME="$decoy" FM_ROOT="$decoy" FM_ROOT_OVERRIDE="$decoy" \
    FM_STATE_OVERRIDE="$decoy/state" FM_DATA_OVERRIDE="$decoy/data" \
    FM_CONFIG_OVERRIDE="$decoy/config" FM_PROJECTS_OVERRIDE="$decoy/projects" \
    bash -c '
    set -u
    . "$1/tests/lib.sh"
    for name in HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HERDR_SOCKET_PATH HERDR_SESSION HERDR_BIN_PATH TERM_PROGRAM FM_BACKEND \
      FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
      FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do
      [ -z "${!name+x}" ] || { echo "$name survived tests/lib.sh"; exit 1; }
    done
    (
      . "$ROOT/bin/fm-backend.sh"
      [ "$FM_BACKEND_CONFIG_DIR" = "$ROOT/config" ] \
        || { echo "cleared home still resolves config at $FM_BACKEND_CONFIG_DIR"; exit 1; }
    ) || exit 1
    (
      export FM_CONFIG_OVERRIDE="$2/empty-config" REX_BLOCK=block
      . "$ROOT/bin/fm-backend.sh"
      backend=$(fm_backend_name)
      case "$backend" in
        herdr|rex|paseo) echo "inherited launcher still selects $backend"; exit 1 ;;
      esac
    ) || exit 1
    (
      export FM_CONFIG_OVERRIDE="$2/empty-config" HERDR_ENV=1
      . "$ROOT/bin/fm-backend.sh"
      [ "$(fm_backend_name)" = herdr ] \
        || { echo "a launcher identity exported after sourcing was ignored"; exit 1; }
    ) || exit 1
    (
      export FM_CONFIG_OVERRIDE="$2/empty-config" FM_BACKEND=paseo
      . "$ROOT/bin/fm-backend.sh"
      [ "$(fm_backend_name)" = paseo ] \
        || { echo "a backend exported after sourcing was ignored"; exit 1; }
    ) || exit 1
    (
      export FM_HOME="$2/own-home"
      . "$ROOT/bin/fm-backend.sh"
      [ "$FM_BACKEND_CONFIG_DIR" = "$2/own-home/config" ] \
        || { echo "a home exported after sourcing was ignored"; exit 1; }
    ) || exit 1
  ' _ "$ROOT" "$dir" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "inherited launcher environment reached a fixture: $out"
  pass "tests/lib.sh clears an inherited launcher environment and honors later exports"
)

test_git_config_isolation || fail "Git fixture config isolation"
test_inherited_launcher_env_is_cleared || fail "launcher environment isolation"
test_inherited_git_location_isolation || fail "Git fixture location isolation"
test_agent_standin_survives_a_multicall_sleep || fail "agent stand-in multicall case"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
test_fakebin_write_replaces_symlinked_entry
test_fakebin_write_refuses_symlinked_parent_directory
test_shared_fixture_helpers_route_their_stub_writes
test_fakebin_write_preserves_the_replaced_entrys_mode
test_fakebin_write_append_extends_an_entry_it_owns
test_fakebin_write_append_refuses_a_symlinked_entry
test_fakebin_write_append_refuses_a_symlinked_parent_directory
test_fakebin_write_is_reachable_without_the_test_library
