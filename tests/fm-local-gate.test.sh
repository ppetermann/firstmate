#!/usr/bin/env bash
# Behavior tests for bin/fm-local-gate.sh.
#
# Covers repo detection branches, the crew (two-arg) vs bare (one-arg) forms,
# pass-marker write/remove semantics, the host-side cargo fmt rung, the
# bin/dev.sh delegation branch, npm script-presence detection, the npm
# clean-context install decision, the pnpm, make, and python paths with the
# Python clean-context install decision, the documentation-only no-ladder
# pass, and failure propagation with the failing step named.
# cargo, npm, pnpm, make, uv, bin/dev.sh, and the .venv interpreter are
# PATH-mocked per fixture; python3 is a wrapper that mocks only venv creation
# and delegates everything else to the real python3; node and git are real,
# matching the repo's existing test practice (node is a required firstmate
# tool and already used unguarded in tests/).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-local-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-gate)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The npm path parses package.json with the real node, which the stripped
# BASE_PATH must therefore expose through the fixture fakebin.
NODE_BIN=$(command -v node) || fail "node is required to test fm-local-gate"
PYTHON_BIN=$(command -v python3) || fail "python3 is required to test fm-local-gate"
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
  fm_fakebin_write "$dir/fakebin/cargo" <<'SH'
#!/usr/bin/env bash
[ $# -ge 1 ] || exit 0
printf 'cargo %s\n' "$*" >> "${FM_TEST_CARGO_LOG:?}"
case "$1" in
  clippy) exit "${FM_TEST_CARGO_RC_CLIPPY:-0}" ;;
  test) exit "${FM_TEST_CARGO_RC_TEST:-0}" ;;
  fmt)
    [ "${2:-}" = --version ] && exit "${FM_TEST_CARGO_RC_FMT_VERSION:-0}"
    exit "${FM_TEST_CARGO_RC_FMT:-0}" ;;
esac
exit 0
SH
  fm_fakebin_write "$dir/fakebin/npm" <<'SH'
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
  fm_fakebin_write "$dir/fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "${FM_TEST_TOOL_LOG:?}"
case "${1:-}" in
  install) exit "${FM_TEST_PNPM_INSTALL_RC:-0}" ;;
  run)
    case "${2:-}" in
      test) exit "${FM_TEST_PNPM_TEST_RC:-0}" ;;
    esac ;;
esac
exit 0
SH
  fm_fakebin_write "$dir/fakebin/make" <<'SH'
#!/usr/bin/env bash
target=
vars=
for arg in "$@"; do
  case "$arg" in
    VENV=*) venv=${arg#VENV=}; vars="$vars $arg" ;;
    *=*) vars="$vars $arg" ;;
    *) target=$arg ;;
  esac
done
printf 'make %s\n' "$target" >> "${FM_TEST_TOOL_LOG:?}"
[ -z "$vars" ] || printf 'make-vars %s:%s\n' "$target" "$vars" >> "${FM_TEST_TOOL_LOG:?}"
case "$target" in
  install) mkdir -p "${venv:-.venv}" ;;
  check) exit "${FM_TEST_MAKE_CHECK_RC:-0}" ;;
esac
exit 0
SH
  # The interpreter a created .venv holds: logs its module calls.
  fm_fakebin_write "$dir/fakebin/venv-python" <<'SH'
#!/usr/bin/env bash
printf 'venv-python %s\n' "$*" >> "${FM_TEST_TOOL_LOG:?}"
case "${2:-}" in
  pytest) exit "${FM_TEST_PYTEST_RC:-0}" ;;
esac
exit 0
SH
  fm_fakebin_write "$dir/fakebin/uv" <<'SH'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "${FM_TEST_TOOL_LOG:?}"
mkdir -p "${UV_PROJECT_ENVIRONMENT:?}/bin" \
  && cp "${FM_TEST_FAKEBIN:?}/venv-python" "$UV_PROJECT_ENVIRONMENT/bin/python"
exit 0
SH
  fm_fakebin_write "$dir/fakebin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -c ] && [ "\${2:-}" = "import ensurepip, venv" ]; then
  exit "\${FM_TEST_PY3_VENV_RC:-0}"
fi
if [ "\${1:-}" = -m ] && [ "\${2:-}" = venv ]; then
  printf 'python3 %s\n' "\$*" >> "\${FM_TEST_TOOL_LOG:?}"
  mkdir -p "\$3/bin" && cp "\${FM_TEST_FAKEBIN:?}/venv-python" "\$3/bin/python"
  exit 0
fi
exec "$PYTHON_BIN" "\$@"
SH
  chmod +x "$dir/fakebin/cargo" "$dir/fakebin/npm" "$dir/fakebin/pnpm" \
    "$dir/fakebin/make" "$dir/fakebin/venv-python" "$dir/fakebin/uv" \
    "$dir/fakebin/python3"
  ln -s "$NODE_BIN" "$dir/fakebin/node"
  : > "$dir/cargo.log"
  : > "$dir/npm.log"
  : > "$dir/tool.log"
  printf '%s\n' "$dir"
}

# Invoke the gate inside a fixture with the mocks on PATH and the fixture
# home active. Sets GATE_OUT and GATE_RC and leaves stderr in <dir>/gate.err.
run_gate() {  # <fixture-dir> [gate args...]
  local dir=$1
  shift
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_TOOL_LOG="$dir/tool.log" \
    FM_TEST_FAKEBIN="$dir/fakebin" \
    "$GATE" "$@" 2> "$dir/gate.err")
  GATE_RC=$?
}

# run_gate with extra environment assignments: <fixture-dir> <VAR=value>... -- [gate args...]
run_gate_env() {
  local dir=$1
  local -a envs=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  GATE_OUT=$(env PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_TOOL_LOG="$dir/tool.log" \
    FM_TEST_FAKEBIN="$dir/fakebin" "${envs[@]}" \
    "$GATE" "$@" 2> "$dir/gate.err")
  GATE_RC=$?
}

commit_all() {  # <fixture-dir>
  git -C "$1/wt" add -A
  git -C "$1/wt" -c user.email=gate@test -c user.name=gate commit -q -m files
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
  assert_grep "cargo fmt --all -- --check" "$dir/cargo.log" \
    "direct cargo path must run the fmt rung"
  case "$(head -n 1 "$dir/cargo.log")" in
    "cargo fmt"*) ;;
    *) fail "the fmt rung must run before the build commands" ;;
  esac
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

test_fmt_rung() {
  local dir
  # A red fmt names cargo-fmt and stops before the build commands.
  dir=$(make_fixture fmt-fail)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_CARGO_RC_FMT=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 1 "$GATE_RC" "red fmt must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: cargo-fmt" \
    "red fmt must name cargo-fmt"
  assert_no_grep "cargo clippy" "$dir/cargo.log" \
    "a failed fmt must stop before clippy"

  # rustfmt absent: the rung is skipped with a note and the suite continues.
  dir=$(make_fixture fmt-absent)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  GATE_OUT=$(PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_TEST_CARGO_LOG="$dir/cargo.log" FM_TEST_NPM_LOG="$dir/npm.log" \
    FM_TEST_DEV_LOG="$dir/dev.log" FM_TEST_CARGO_RC_FMT_VERSION=1 \
    "$GATE" task-a "$dir/wt" 2> "$dir/gate.err")
  GATE_RC=$?
  expect_code 0 "$GATE_RC" "absent rustfmt must not fail the gate"
  assert_contains "$GATE_OUT" "rustfmt not on this host" \
    "absent rustfmt must be noted as a skip"
  assert_no_grep "cargo fmt --all" "$dir/cargo.log" \
    "absent rustfmt must skip the fmt run"
  assert_grep "cargo clippy" "$dir/cargo.log" \
    "the suite must continue after the fmt skip"
  assert_grep "cargo test --locked" "$dir/cargo.log" \
    "the suite must continue after the fmt skip"

  pass "fm-local-gate: host-side cargo fmt rung"
}

test_dev_sh_delegation() {
  local dir
  dir=$(make_fixture dev-sh)
  printf '%s\n' '[package]' > "$dir/wt/Cargo.toml"
  mkdir -p "$dir/wt/bin"
  fm_fakebin_write "$dir/wt/bin/dev.sh" <<SH
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
  assert_grep "cargo fmt --all -- --check" "$dir/cargo.log" \
    "the fmt rung must run host-side even under dev.sh delegation"
  assert_no_grep "cargo clippy" "$dir/cargo.log" \
    "delegation must never run host cargo clippy"
  assert_no_grep "cargo test" "$dir/cargo.log" \
    "delegation must never run host cargo test"

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
  fm_fakebin_write "$dir/wt/bin/dev.sh" <<SH
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
  assert_no_grep "cargo clippy" "$dir/cargo.log" \
    "non-executable dev.sh must not fall back to host cargo clippy"
  assert_no_grep "cargo test" "$dir/cargo.log" \
    "non-executable dev.sh must not fall back to host cargo test"

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

# --- pnpm path ---------------------------------------------------------------

test_pnpm_path() {
  local dir
  dir=$(make_fixture pnpm-path)
  write_pkg "$dir" '{"scripts":{"check":"x","test":"y"}}'
  printf '%s\n' 'lockfileVersion: 9.0' > "$dir/wt/pnpm-lock.yaml"

  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "pnpm repo must pass with green scripts"
  assert_contains "$GATE_OUT" "using the pnpm path" "pnpm path must be announced"
  assert_grep "pnpm install --frozen-lockfile" "$dir/tool.log" \
    "pnpm path must install with the lockfile frozen"
  assert_grep "pnpm run check" "$dir/tool.log" "pnpm path must run the check script"
  assert_grep "pnpm run test" "$dir/tool.log" "pnpm path must run the test script"
  assert_no_grep "pnpm run typecheck" "$dir/tool.log" \
    "absent typecheck script must not run under pnpm"
  [ ! -s "$dir/npm.log" ] || fail "a pnpm repo must never run npm"
  [ -f "$dir/home/state/task-a.gate-pass" ] || fail "pnpm pass must write the marker"

  # A stray package-lock.json does not pull a pnpm repo onto the npm path.
  printf '%s\n' '{}' > "$dir/wt/package-lock.json"
  : > "$dir/tool.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "pnpm repo with a stray npm lockfile must still pass"
  assert_grep "pnpm install --frozen-lockfile" "$dir/tool.log" \
    "pnpm-lock.yaml must select pnpm over a stray package-lock.json"
  [ ! -s "$dir/npm.log" ] || fail "a stray npm lockfile must not run npm"

  # A red frozen install names pnpm-install and removes the marker.
  run_gate_env "$dir" FM_TEST_PNPM_INSTALL_RC=1 -- task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "red pnpm install must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: pnpm-install" \
    "red pnpm install must name pnpm-install"
  [ ! -e "$dir/home/state/task-a.gate-pass" ] \
    || fail "a red pnpm install must remove the pass marker"

  # A red test script names pnpm-test.
  run_gate_env "$dir" FM_TEST_PNPM_TEST_RC=1 -- task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "red pnpm test must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: pnpm-test" \
    "red pnpm test must name pnpm-test"

  pass "fm-local-gate: pnpm path"
}

# --- make path ---------------------------------------------------------------

test_make_python_path() {
  local dir venv
  dir=$(make_fixture make-python)
  printf '%s\n' '[project]' 'name = "x"' > "$dir/wt/pyproject.toml"
  printf '%s\n' 'VENV ?= .venv' 'PYTHON ?= python3' 'install:' '	true' \
    'check: lint test' '	true' 'lint:' '	true' 'test:' '	true' > "$dir/wt/Makefile"
  mkdir -p "$dir/wt/.venv"
  : > "$dir/wt/.venv/worker-owned"
  venv="$dir/wt/.git/fm-local-gate-venv"

  # First run: clean install through make install, then the check ladder.
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "Python Makefile repo must pass with a green ladder"
  assert_grep "make install" "$dir/tool.log" "Python make path must run make install"
  assert_grep "make check" "$dir/tool.log" "make path must run the check ladder"
  assert_no_grep "make lint" "$dir/tool.log" \
    "a check target is the ladder: lint must not run a second time"
  assert_no_grep "make test" "$dir/tool.log" \
    "a check target is the ladder: test must not run a second time"
  assert_grep "make-vars install: PYTHON=python3 VENV=$venv" "$dir/tool.log" \
    "make install must get the gate interpreter and the gate venv"
  assert_grep "make-vars check: PYTHON=python3 VENV=$venv" "$dir/tool.log" \
    "make check must get the same gate venv"
  [ -d "$venv" ] || fail "make install must build the gate venv"
  [ -f "$dir/wt/.venv/worker-owned" ] || fail "the worker's own .venv must be left alone"
  [ -f "$dir/home/state/task-a.gate-pass" ] || fail "make pass must write the marker"

  # Unchanged inputs with the gate venv present: the reinstall is skipped.
  : > "$dir/tool.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "unchanged Python inputs must pass"
  assert_contains "$GATE_OUT" "skipping the reinstall" \
    "unchanged Python inputs must skip with the tradeoff note"
  assert_no_grep "make install" "$dir/tool.log" \
    "unchanged Python inputs must not reinstall"
  assert_grep "make check" "$dir/tool.log" "the ladder must still run"

  # Changed inputs: .venv is removed and make install runs again.
  : > "$venv/stale"
  printf '%s\n' 'version = "2"' >> "$dir/wt/pyproject.toml"
  : > "$dir/tool.log"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "changed Python inputs must pass"
  assert_grep "make install" "$dir/tool.log" "changed inputs must reinstall"
  [ ! -e "$venv/stale" ] || fail "changed inputs must rebuild the gate venv"
  [ -f "$dir/wt/.venv/worker-owned" ] || fail "a rebuild must leave the worker's .venv alone"

  # A red check names make-check.
  run_gate_env "$dir" FM_TEST_MAKE_CHECK_RC=1 -- task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "red make check must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: make-check" \
    "red make check must name make-check"

  pass "fm-local-gate: Python Makefile path and clean-context install"
}

test_make_python_interpreter() {
  local dir
  # The newest workflow python-version that can build a venv wins.
  dir=$(make_fixture make-python-interp)
  printf '%s\n' '[project]' 'name = "x"' > "$dir/wt/pyproject.toml"
  printf '%s\n' 'PYTHON ?= python3' 'check:' '	true' > "$dir/wt/Makefile"
  mkdir -p "$dir/wt/.github/workflows"
  printf '%s\n' 'jobs:' '  t:' '    strategy:' '      matrix:' \
    '        python-version: ["3.11", "3.12", "3.13"]' > "$dir/wt/.github/workflows/ci.yml"
  # python3.13 exists but cannot build a venv; python3.12 can.
  fm_fakebin_write "$dir/fakebin/python3.13" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  fm_fakebin_write "$dir/fakebin/python3.12" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && echo "Python 3.12.9"
exit 0
SH
  chmod +x "$dir/fakebin/python3.13" "$dir/fakebin/python3.12"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "interpreter selection must pass"
  assert_grep "make-vars check: PYTHON=python3.12" "$dir/tool.log" \
    "the newest venv-capable workflow interpreter must be passed as PYTHON"
  assert_contains "$GATE_OUT" "gate interpreter: python3.12" \
    "the chosen interpreter must be announced"

  # No candidate can build a venv: python-venv names every candidate.
  dir=$(make_fixture make-python-no-venv)
  printf '%s\n' '[project]' 'name = "x"' > "$dir/wt/pyproject.toml"
  printf '%s\n' 'PYTHON ?= python3' 'check:' '	true' > "$dir/wt/Makefile"
  run_gate_env "$dir" FM_TEST_PY3_VENV_RC=1 -- task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "no venv-capable interpreter must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: python-venv" \
    "no venv-capable interpreter must name python-venv"
  assert_contains "$(gate_err "$dir")" "tried: python3" \
    "the failure must name the candidates tried"
  assert_no_grep "make check" "$dir/tool.log" "the ladder must not run without an interpreter"

  pass "fm-local-gate: Python interpreter selection from the workflow matrix"
}

test_make_plain_path() {
  local dir
  # No pyproject.toml: lint and test targets run, install never does.
  dir=$(make_fixture make-plain)
  printf '%s\n' 'PREFIX := /usr/local' 'install:' '	true' 'lint:' '	true' \
    'test:' '	true' > "$dir/wt/Makefile"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "Makefile lint/test repo must pass"
  assert_grep "make lint" "$dir/tool.log" "make path must run lint"
  assert_grep "make test" "$dir/tool.log" "make path must run test"
  assert_no_grep "make install" "$dir/tool.log" \
    "without pyproject.toml make install must never run"
  case "$(head -n 1 "$dir/tool.log")" in
    "make lint") ;;
    *) fail "lint must run before test" ;;
  esac

  # A Makefile without ladder targets is unrecognised, never a silent pass.
  dir=$(make_fixture make-no-ladder)
  printf '%s\n' 'check := yes' 'build:' '	true' > "$dir/wt/Makefile"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "a Makefile with no ladder targets must fail"
  assert_contains "$(gate_err "$dir")" "gate failed: repo-detect" \
    "a Makefile with no ladder targets must fail at repo-detect"
  assert_contains "$(gate_err "$dir")" "defines none of the check, lint, or test targets" \
    "the repo-detect failure must name the Makefile gap"
  [ ! -s "$dir/tool.log" ] || fail "an unrecognised repo must run nothing"

  pass "fm-local-gate: plain Makefile path and unrecognised Makefile"
}

# --- python path (pyproject.toml without a Makefile ladder) --------------------

test_python_path() {
  local dir
  dir=$(make_fixture python-pip)
  printf '%s\n' '[project]' 'name = "x"' '[project.optional-dependencies]' \
    'dev = ["pytest", "ruff"]' '[tool.ruff]' 'line-length = 100' \
    > "$dir/wt/pyproject.toml"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "pyproject repo must pass with green lint and tests"
  assert_grep "python3 -m venv $dir/wt/.git/fm-local-gate-venv" "$dir/tool.log" \
    "pip path must create the gate venv"
  assert_grep "venv-python -m pip install -e .[dev]" "$dir/tool.log" \
    "pip path must install the dev extra"
  assert_grep "venv-python -m ruff check ." "$dir/tool.log" \
    "configured ruff must lint"
  assert_grep "venv-python -m pytest" "$dir/tool.log" "python path must run pytest"
  [ -f "$dir/home/state/task-a.gate-pass" ] || fail "python pass must write the marker"

  # A red pytest names python-test.
  run_gate_env "$dir" FM_TEST_PYTEST_RC=1 -- task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "red pytest must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: python-test" \
    "red pytest must name python-test"

  # No dev extra and no ruff: plain editable install, lint skipped.
  dir=$(make_fixture python-bare)
  printf '%s\n' '[project]' 'name = "x"' > "$dir/wt/pyproject.toml"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "bare pyproject repo must pass"
  grep -qx -- "venv-python -m pip install -e ." "$dir/tool.log" \
    || fail "no dev extra must install the project alone"
  assert_no_grep "ruff" "$dir/tool.log" "unconfigured ruff must not run"
  assert_contains "$GATE_OUT" "ruff not configured" "the lint skip must be noted"

  # uv.lock: uv sync --locked, no venv of the gate's own.
  dir=$(make_fixture python-uv)
  printf '%s\n' '[project]' 'name = "x"' > "$dir/wt/pyproject.toml"
  printf '%s\n' 'version = 1' > "$dir/wt/uv.lock"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "uv repo must pass"
  assert_grep "uv sync --locked" "$dir/tool.log" "uv.lock must sync from the lockfile"
  assert_no_grep "python3 -m venv" "$dir/tool.log" "uv path must not create its own venv"
  assert_grep "venv-python -m pytest" "$dir/tool.log" "uv path must run pytest"

  # Invalid TOML fails python-config instead of passing.
  dir=$(make_fixture python-bad-toml)
  printf '%s\n' '[project' > "$dir/wt/pyproject.toml"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "invalid pyproject.toml must fail the gate"
  assert_contains "$(gate_err "$dir")" "gate failed: python-config" \
    "invalid pyproject.toml must name python-config"

  pass "fm-local-gate: python path (pip, uv, lint detection)"
}

# --- documentation-only no-ladder pass -----------------------------------------

test_docs_only() {
  local dir head marker_line
  dir=$(make_fixture docs-only)
  mkdir -p "$dir/wt/docs/img" "$dir/wt/.github/workflows"
  printf '%s\n' '# Title' > "$dir/wt/README.md"
  printf '%s\n' 'text' > "$dir/wt/docs/guide.md"
  printf '%s\n' 'png' > "$dir/wt/docs/img/a.PNG"
  printf '%s\n' 'MIT' > "$dir/wt/LICENSE"
  printf '%s\n' 'node_modules' > "$dir/wt/.gitignore"
  printf '%s\n' 'on: push' > "$dir/wt/.github/workflows/lint.yml"
  commit_all "$dir"
  head=$(git -C "$dir/wt" rev-parse HEAD)

  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "a documentation-only repo must pass"
  assert_contains "$GATE_OUT" "explicit no-ladder pass" \
    "the docs-only pass must say no ladder ran"
  marker_line=$(cat "$dir/home/state/task-a.gate-pass" 2>/dev/null)
  case "$marker_line" in
    "head=$head ts="*[0-9]) ;;
    *) fail "docs-only pass must record the head (got: $marker_line)" ;;
  esac
  [ ! -s "$dir/tool.log" ] && [ ! -s "$dir/npm.log" ] && [ ! -s "$dir/cargo.log" ] \
    || fail "a docs-only pass must run no tool"

  # An untracked non-documentation file makes it unrecognised.
  printf '%s\n' 'echo hi' > "$dir/wt/build.sh"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "docs plus a script must not pass as docs-only"
  assert_contains "$(gate_err "$dir")" "gate failed: repo-detect" \
    "docs plus a script must fail at repo-detect"
  assert_contains "$(gate_err "$dir")" "not documentation-only: build.sh" \
    "the failure must name the first non-documentation file"
  [ ! -e "$dir/home/state/task-a.gate-pass" ] \
    || fail "a repo-detect failure must remove the pass marker"

  # A requirements file is a build input, not documentation.
  rm -f "$dir/wt/build.sh"
  printf '%s\n' 'requests' > "$dir/wt/requirements.txt"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 1 "$GATE_RC" "requirements.txt must not count as documentation"
  assert_contains "$(gate_err "$dir")" "not documentation-only: requirements.txt" \
    "the failure must name requirements.txt"

  # Ignored files do not count against docs-only.
  rm -f "$dir/wt/requirements.txt"
  mkdir -p "$dir/wt/node_modules"
  printf '%s\n' 'x' > "$dir/wt/node_modules/index.js"
  run_gate "$dir" task-a "$dir/wt"
  expect_code 0 "$GATE_RC" "ignored files must not block the docs-only pass"

  pass "fm-local-gate: documentation-only no-ladder pass"
}

test_usage_and_arg_forms
test_repo_detection
test_cargo_path
test_fmt_rung
test_dev_sh_delegation
test_npm_suite
test_npm_clean_context
test_marker_semantics
test_pnpm_path
test_make_python_path
test_make_python_interpreter
test_make_plain_path
test_python_path
test_docs_only
