#!/usr/bin/env bash
# Behavior tests for bin/fm-local-gate.sh.
#
# Covers repo detection branches, the crew (two-arg) vs bare (one-arg) forms,
# pass-marker write/remove semantics, the bin/dev.sh delegation branch, npm
# script-presence detection, the npm clean-context install decision, and
# failure propagation with the failing step named.
# cargo, npm, and bin/dev.sh are PATH-mocked per fixture; node and git are
# real, matching the repo's existing test practice (node is a required
# firstmate tool and already used unguarded in tests/).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-local-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-gate)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The npm path parses package.json with the real node, which the stripped
# BASE_PATH must therefore expose through the fixture fakebin.
NODE_BIN=$(command -v node) || fail "node is required to test fm-local-gate"
GATE_OUT=
GATE_RC=

# Build one fixture: a throwaway home with a state dir, a fakebin holding the
# cargo/npm mocks, and a git-initialized worktree. Echoes the fixture dir.
make_fixture() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/home/state" "$dir/wt"
  git -C "$dir/wt" -c init.defaultBranch=main init -q
  git -C "$dir/wt" -c user.email=gate@test -c user.name=gate commit -q \
    --allow-empty -m init
  cat > "$dir/fakebin/cargo" <<'SH'
#!/usr/bin/env bash
[ $# -ge 1 ] || exit 0
printf 'cargo %s\n' "$*" >> "${FM_TEST_CARGO_LOG:?}"
case "$1" in
  clippy) exit "${FM_TEST_CARGO_RC_CLIPPY:-0}" ;;
  test) exit "${FM_TEST_CARGO_RC_TEST:-0}" ;;
esac
exit 0
SH
  cat > "$dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
[ $# -ge 1 ] || exit 0
if [ "$1" = ci ] && [ "${2:-}" = --help ]; then
  exit "${FM_TEST_NPM_CI_HELP:-0}"
fi
printf 'npm %s\n' "$*" >> "${FM_TEST_NPM_LOG:?}"
case "$1" in
  ci|install) exit "${FM_TEST_NPM_INSTALL_RC:-0}" ;;
  run)
    case "$2" in
      check) exit "${FM_TEST_NPM_CHECK_RC:-0}" ;;
      typecheck) exit "${FM_TEST_NPM_TYPECHECK_RC:-0}" ;;
      test) exit "${FM_TEST_NPM_TEST_RC:-0}" ;;
    esac
    exit "${FM_TEST_NPM_RUN_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/cargo" "$dir/fakebin/npm"
  ln -s "$NODE_BIN" "$dir/fakebin/node"
  : > "$dir/cargo.log"
  : > "$dir/npm.log"
  printf '%s\n' "$dir"
}

# Invoke the gate inside a fixture with the mocks on PATH and the fixture
# home active. Sets GATE_OUT and GATE_RC and leaves stderr in <dir>/gate.err.
run_gate() {  # <fixture-dir> [gate args...]
  local dir=$1
  shift
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" \
    "$GATE" "$@" 2> "$dir/gate.err")
  GATE_RC=$?
}

gate_err() {  # <fixture-dir>
  cat "$1/gate.err"
}

write_pkg() {  # <dir> <package.json content>
  printf '%s\n' "$2" > "$1/wt/package.json"
}

# --- usage and argument forms -----------------------------------------------

test_usage_and_arg_forms() {
  local dir
  dir=$(make_fixture usage-forms)

  run_gate "$dir"
  expect_code 2 "$GATE_RC" "no arguments must be a usage error"
  assert_contains "$(gate_err "$dir")" "usage:" "no-args error must print usage"

  run_gate "$dir" -h
  expect_code 0 "$GATE_RC" "-h must print usage and exit 0"
  assert_contains "$GATE_OUT" "Usage:" "-h output must contain the usage block"

  run_gate "$dir" wt extra1 extra2
  expect_code 2 "$GATE_RC" "three arguments must be a usage error"

  run_gate "$dir" ../evil wt
  expect_code 2 "$GATE_RC" "a path-traversing task id must be rejected"

  run_gate "$dir" task-a "$TMP_ROOT/usage-forms/no-such-dir"
  expect_code 2 "$GATE_RC" "an unresolvable worktree must be a usage error"

  # The crew form needs an existing state directory.
  mkdir -p "$dir/empty-home"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/empty-home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 2 "$GATE_RC" "crew form with a missing state dir must be a usage error"
  assert_contains "$(gate_err "$dir")" "state directory not found" \
    "missing state dir error must name the problem"

  pass "fm-local-gate: usage, argument forms, and input validation"
}

# --- repo detection branches -------------------------------------------------

test_repo_detection() {
  local dir
  dir=$(make_fixture repo-detect)

  # Neither marker: failing step named, message lists what was looked for.
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "an empty worktree must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: repo-detect" \
    "empty worktree must fail at repo-detect"
  assert_contains "$(gate_err "$dir")" "Cargo.toml" "error must list Cargo.toml"
  assert_contains "$(gate_err "$dir")" "package.json" "error must list package.json"

  # Both markers: cargo path wins with a printed note.
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  write_pkg "$dir" '{"scripts":{"test":"x"}}'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "both markers must gate via the cargo path"
  assert_contains "$GATE_OUT" "using the cargo path" \
    "both markers must print the cargo-wins note"
  assert_grep "cargo clippy" "$dir/cargo.log" "cargo path must run clippy"
  assert_no_grep "npm ci" "$dir/npm.log" \
    "both-marker fixture must not run npm install (the npm ci probe is unlogged)"

  # package.json only: npm path.
  dir=$(make_fixture repo-detect-npm)
  write_pkg "$dir" '{"scripts":{"test":"x"}}'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "package.json-only worktree must gate via the npm path"
  assert_no_grep "cargo clippy" "$dir/cargo.log" \
    "npm worktree must not invoke cargo"
  assert_grep "npm run test" "$dir/npm.log" "npm path must run the test script"

  pass "fm-local-gate: repo detection branches"
}

# --- cargo path: direct runs, dev.sh delegation, failure naming --------------

test_cargo_path() {
  local dir head
  dir=$(make_fixture cargo-path)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"

  run_gate "$dir" "$dir/wt"
  expect_code 0 "$GATE_RC" "cargo path must pass with green clippy and test"
  assert_grep "cargo clippy --all-targets --locked -- -D warnings" "$dir/cargo.log" \
    "direct cargo path must run clippy with warnings denied"
  assert_grep "cargo test --locked" "$dir/cargo.log" \
    "direct cargo path must run locked tests"
  [ ! -e "$dir/home/state/task-a.gate-pass" ] \
    || fail "bare form must not write a pass marker"
  pass "fm-local-gate: direct cargo path"

  # Clippy failure names cargo-clippy.
  dir=$(make_fixture cargo-clippy-fail)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_CARGO_RC_CLIPPY=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 1 "$GATE_RC" "red clippy must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: cargo-clippy" \
    "red clippy must name cargo-clippy"
  assert_no_grep "cargo test" "$dir/cargo.log" \
    "a failed clippy must stop before cargo test"

  # Test failure names cargo-test and removes a stale pass marker.
  head=$(git -C "$dir/wt" rev-parse HEAD)
  mkdir -p "$dir/home/state"
  printf 'head=%s ts=1\n' "$head" > "$dir/home/state/task-a.gate-pass"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_CARGO_RC_TEST=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 1 "$GATE_RC" "red cargo test must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: cargo-test" \
    "red cargo test must name cargo-test"
  [ ! -e "$dir/home/state/task-a.gate-pass" ] \
    || fail "a failing gate run must remove the stale pass marker"

  pass "fm-local-gate: cargo failure propagation and stale marker removal"
}

test_dev_sh_delegation() {
  local dir
  dir=$(make_fixture dev-sh)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  mkdir -p "$dir/wt/bin"
  cat > "$dir/wt/bin/dev.sh" <<SH
#!/usr/bin/env bash
printf 'dev.sh %s\n' "\$*" >> "\$FM_TEST_DEV_LOG"
case "\$1" in
  clippy) exit "\${FM_TEST_DEV_RC_CLIPPY:-0}" ;;
  test) exit "\${FM_TEST_DEV_RC_TEST:-0}" ;;
esac
exit 0
SH
  chmod +x "$dir/wt/bin/dev.sh"
  : > "$dir/dev.log"

  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "dev.sh delegation must pass with a green helper"
  assert_grep "dev.sh clippy --all-targets --locked -- -D warnings" "$dir/dev.log" \
    "dev.sh must receive the clippy command"
  assert_grep "dev.sh test --locked" "$dir/dev.log" \
    "dev.sh must receive the test command"
  [ ! -s "$dir/cargo.log" ] \
    || fail "dev.sh delegation must never run bare cargo on the host"

  # A red delegated clippy names dev-clippy.
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_DEV_RC_CLIPPY=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 1 "$GATE_RC" "red dev.sh clippy must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: dev-clippy" \
    "red dev.sh clippy must name dev-clippy"

  # A non-executable dev.sh still gets delegated, through bash.
  dir=$(make_fixture dev-sh-noexec)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  mkdir -p "$dir/wt/bin"
  cat > "$dir/wt/bin/dev.sh" <<SH
#!/usr/bin/env bash
printf 'dev.sh %s\n' "\$*" >> "\$FM_TEST_DEV_LOG"
exit 0
SH
  : > "$dir/dev.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "non-executable dev.sh must still be delegated"
  assert_contains "$GATE_OUT" "not executable" \
    "non-executable dev.sh must print a note"
  assert_grep "dev.sh clippy" "$dir/dev.log" \
    "non-executable dev.sh must still run its commands"
  [ ! -s "$dir/cargo.log" ] \
    || fail "non-executable dev.sh must not fall back to host cargo"

  pass "fm-local-gate: bin/dev.sh delegation branch"
}

# --- npm path: script presence, install decision, failure naming -------------

test_npm_suite() {
  local dir marker
  dir=$(make_fixture npm-suite)

  # Only check and test exist: typecheck skipped with a note.
  write_pkg "$dir" '{"scripts":{"check":"svelte-check","test":"vitest"}}'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "npm path must pass with green scripts"
  assert_grep "npm run check" "$dir/npm.log" "check script must run"
  assert_grep "npm run test" "$dir/npm.log" "test script must run"
  assert_no_grep "npm run typecheck" "$dir/npm.log" \
    "absent typecheck script must not run"
  assert_contains "$GATE_OUT" "no \"typecheck\" script" \
    "absent script skip must be noted"

  # Malformed package.json fails the scripts step instead of passing silently.
  dir=$(make_fixture npm-malformed)
  write_pkg "$dir" '{ not json'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "malformed package.json must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: npm-scripts" \
    "malformed package.json must name npm-scripts"

  # A red check script names npm-check.
  dir=$(make_fixture npm-check-fail)
  write_pkg "$dir" '{"scripts":{"check":"x"}}'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_NPM_CHECK_RC=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 1 "$GATE_RC" "red npm check must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: npm-check" \
    "red npm check must name npm-check"

  # npm ci unsupported: npm install substitutes, with a note.
  dir=$(make_fixture npm-ci-unsupported)
  write_pkg "$dir" '{"scripts":{}}'
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_NPM_CI_HELP=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 0 "$GATE_RC" "unsupported npm ci must still pass via npm install"
  assert_contains "$GATE_OUT" "npm install" \
    "npm ci fallback must be visible in the output"
  assert_no_grep "npm ci" "$dir/npm.log" \
    "unsupported npm ci must not run (only the unlogged probe may ask)"

  # No lockfile at all: npm install with a note.
  dir=$(make_fixture npm-no-lock)
  write_pkg "$dir" '{"scripts":{}}'
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 0 "$GATE_RC" "lockfile-less npm repo must gate via npm install"
  assert_contains "$GATE_OUT" "no package-lock.json or npm-shrinkwrap.json" \
    "missing lockfile must be noted"

  pass "fm-local-gate: npm suite branches"
}

test_npm_clean_context() {
  local dir marker
  dir=$(make_fixture npm-clean-context)
  write_pkg "$dir" '{"scripts":{}}'
  printf '%s\n' '{"lockfileVersion":1}' > "$dir/wt/package-lock.json"
  marker="$dir/wt/.git/fm-local-gate-lockhash"

  # First run: no node_modules, so a full npm ci.
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "first npm run must pass"
  assert_contains "$GATE_OUT" "full clean install" \
    "first run must announce the full clean install"
  assert_grep "npm ci" "$dir/npm.log" "first run must run npm ci"
  [ -f "$marker" ] || fail "a full gate install must record the lockfile hash marker"

  # Second run, unchanged lockfile with node_modules present: skip reinstall.
  mkdir -p "$dir/wt/node_modules"
  : > "$dir/npm.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "unchanged-lock run must pass"
  assert_contains "$GATE_OUT" "skipping the destructive reinstall" \
    "unchanged lockfile must skip with the documented tradeoff note"
  assert_no_grep "npm ci" "$dir/npm.log" \
    "unchanged lockfile must not reinstall (npm ci)"
  assert_no_grep "npm install" "$dir/npm.log" \
    "unchanged lockfile must not reinstall (npm install)"

  # Lockfile changed: full npm ci again.
  printf '%s\n' '{"lockfileVersion":2}' > "$dir/wt/package-lock.json"
  : > "$dir/npm.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "changed-lock run must pass"
  assert_grep "npm ci" "$dir/npm.log" "changed lockfile must run npm ci again"

  pass "fm-local-gate: npm clean-context install decision"
}

# --- crew-form pass marker semantics -----------------------------------------

test_marker_semantics() {
  local dir head marker marker_line
  dir=$(make_fixture marker-semantics)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  marker="$dir/home/state/task-a.gate-pass"
  head=$(git -C "$dir/wt" rev-parse HEAD)

  # Two-arg success writes head=<sha> ts=<epoch> with mode 0600.
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "crew form must pass"
  [ -f "$marker" ] || fail "crew form success must write the pass marker"
  marker_line=$(cat "$marker")
  case "$marker_line" in
    "head=$head ts="*[0-9]) ;;
    *) fail "pass marker must be 'head=<head-sha> ts=<epoch>' (got: $marker_line)" ;;
  esac
  if [ "$(uname)" = Darwin ]; then
    [ "$(stat -f %Lp "$marker")" = 600 ] || fail "pass marker must be mode 0600"
  else
    [ "$(stat -c %a "$marker")" = 600 ] || fail "pass marker must be mode 0600"
  fi

  # Bare one-arg success on the same worktree writes nothing.
  run_gate "$dir" "$dir/wt"
  expect_code 0 "$GATE_RC" "bare form must pass"
  assert_contains "$GATE_OUT" "gate passed" "bare form must announce the pass"
  case "$GATE_OUT" in
    *gate-pass*) fail "bare form must not announce a marker" ;;
  esac

  # Crew form without a resolvable HEAD is a usage error before any suite.
  dir=$(make_fixture marker-no-head)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  rm -rf "$dir/wt/.git"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 2 "$GATE_RC" "crew form without git HEAD must be a usage error"
  assert_contains "$(gate_err "$dir")" "no resolvable git HEAD" \
    "missing HEAD error must name the problem"
  [ ! -s "$dir/cargo.log" ] \
    || fail "a HEAD-less crew form must fail before running any suite step"

  pass "fm-local-gate: pass marker semantics for both invocation forms"
}

test_usage_and_arg_forms
test_repo_detection
test_cargo_path
test_dev_sh_delegation
test_npm_suite
test_npm_clean_context
test_marker_semantics
