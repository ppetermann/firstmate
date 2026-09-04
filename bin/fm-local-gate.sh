#!/usr/bin/env bash
# Token-free local validation gate for ship worktrees: run the repo's own
# check and test suite in a clean dependency context so the worker that wrote
# the code cannot pass on stale installed state. It is the committed CI run
# early: a red gate blocks the push (AGENTS.md section 7 owns the delivery
# contract).
# Usage:
#   fm-local-gate.sh <worktree-dir>
#     Bare human form: run the gate, manage no state marker.
#   fm-local-gate.sh <task-id> <worktree-dir>
#     Crew form (what the direct-PR definition of done tells the worker to
#     run): on success write state/<task-id>.gate-pass containing
#     head=<sha> ts=<epoch> for the worktree HEAD; on any failure remove any
#     stale marker so a red gate never rides an old pass.
# Exit codes: 0 gate passed, 1 gate failed (stderr names the failing step),
# 2 usage error (bad arguments, unresolvable worktree or state directory,
# worktree without a resolvable HEAD in the crew form).
# Repo detection (worktree root): Cargo.toml -> cargo path; package.json ->
# npm path; both -> cargo path wins with a printed note; neither -> gate
# failure at repo-detect listing the markers that were looked for.
# cargo path: the fmt rung runs host-side first (cargo fmt --all --
# --check; skipped with a note when rustfmt is absent - rustfmt only
# parses, never compiles, so it never needs the container); then, when a
# documented containerized-build helper exists (bin/dev.sh), every build
# command is delegated to it (bin/dev.sh clippy --all-targets --locked --
# -D warnings, then bin/dev.sh test --locked) because some hosts build
# nothing outside the container; otherwise cargo runs directly (cargo
# clippy --all-targets --locked -- -D warnings, then cargo test --locked).
# npm path: install, then run every script present among check, typecheck,
# and test (in that order) via npm run; absent scripts are skipped with a
# printed note, present ones must pass.
# Clean-context discipline: the gate never trusts the worktree's installed
# dependency state, because a worker re-checking its own tree grades its own
# homework. For npm that means npm ci (which deletes node_modules and
# reinstalls exactly from the lockfile) whenever it matters: the first gate
# run on a worktree and every run whose lockfile hash changed since the last
# gate install do the full npm ci, while an unchanged lockfile with
# node_modules already present skips the destructive reinstall with a
# printed note, accepting the documented tradeoff of trusting the previous
# gate install. npm install substitutes when npm ci is unsupported or no
# package-lock.json/npm-shrinkwrap.json exists. The lockfile hash marker
# lives inside the worktree's own git dir (per worktree, never committed);
# without one, every npm run is a full install. For cargo, the repo's own
# target dir plus cargo's content fingerprinting is the documented clean
# context, so no clean is forced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=
WORKTREE=
case $# in
  1) WORKTREE=$1 ;;
  2) ID=$1; WORKTREE=$2 ;;
  *)
    echo "error: usage: fm-local-gate.sh <worktree-dir> | fm-local-gate.sh <task-id> <worktree-dir>" >&2
    exit 2
    ;;
esac

# Same canonical rule as fm_task_id_path_safe in bin/fm-pr-lib.sh: the id
# becomes part of a state path and must never traverse or escape it.
if [ -n "$ID" ]; then
  case "$ID" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "error: invalid task id: $ID" >&2
      exit 2
      ;;
  esac
fi

RESOLVED=$(CDPATH='' cd -- "$WORKTREE" 2>/dev/null && pwd -P) || {
  echo "error: worktree directory cannot be resolved: $WORKTREE" >&2
  exit 2
}
WORKTREE=$RESOLVED

PASS_MARKER=
if [ -n "$ID" ]; then
  STATE_RESOLVED=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || {
    echo "error: firstmate state directory not found: $STATE" >&2
    exit 2
  }
  STATE=$STATE_RESOLVED
  PASS_MARKER="$STATE/$ID.gate-pass"
fi

fail_step() {  # <step>
  echo "gate failed: $1" >&2
  [ -z "$PASS_MARKER" ] || rm -f -- "$PASS_MARKER"
  exit 1
}

run_step() {  # <step> <command> [args...]
  local step=$1
  shift
  echo "==> $step: $*"
  "$@" || fail_step "$step"
}

file_hash() {  # <file> -> content hash on stdout
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1}'
  fi
}

# Absolute path of the per-worktree lockfile hash marker inside the git dir,
# or nothing when the worktree is not a git repository (every npm run is then
# a full install).
gate_lock_marker_path() {
  local d
  d=$(git rev-parse --git-dir 2>/dev/null) || return 0
  case "$d" in
    /*) printf '%s/fm-local-gate-lockhash\n' "$d" ;;
    *) printf '%s/%s/fm-local-gate-lockhash\n' "$PWD" "$d" ;;
  esac
}

npm_ci_supported() {
  npm ci --help >/dev/null 2>&1
}

# 0 present, 1 absent, 2 package.json unreadable or not valid JSON.
npm_script_state() {  # <script-name>
  node -e '
    const fs = require("fs");
    let pkg;
    try {
      pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    } catch (err) {
      process.exit(2);
    }
    const scripts = pkg && typeof pkg === "object" ? pkg.scripts : null;
    const present = !!(scripts && Object.prototype.hasOwnProperty.call(scripts, process.argv[1]));
    process.exit(present ? 0 : 1);
  ' "$1" 2>/dev/null
}

# npm install decision per the clean-context contract in the header. Runs
# with the worktree root as the current directory and LOCKFILE set.
gate_npm_install() {
  local current_hash marker_path marker_hash
  current_hash=$(file_hash "$LOCKFILE") || fail_step npm-install
  marker_path=$(gate_lock_marker_path)
  marker_hash=
  [ -z "$marker_path" ] || marker_hash=$(cat "$marker_path" 2>/dev/null)
  if [ -d node_modules ] && [ -n "$marker_path" ] && [ -n "$marker_hash" ] \
    && [ "$marker_hash" = "$current_hash" ]; then
    echo "note: $LOCKFILE unchanged since the last gate install and node_modules present - skipping the destructive reinstall (trusts the previous gate install)"
    return 0
  fi
  if [ ! -d node_modules ]; then
    echo "note: no node_modules present - full clean install"
  elif [ -z "$marker_path" ] || [ -z "$marker_hash" ]; then
    echo "note: first gate run on this worktree - full clean install"
  else
    echo "note: $LOCKFILE changed since the last gate install - full clean install"
  fi
  if npm_ci_supported; then
    run_step npm-install npm ci
  else
    echo "note: npm ci unsupported here - using npm install"
    run_step npm-install npm install
  fi
  [ -z "$marker_path" ] || printf '%s\n' "$current_hash" > "$marker_path"
}

cd -- "$WORKTREE" || {
  echo "error: cannot enter worktree: $WORKTREE" >&2
  exit 2
}

# The crew form records the gated HEAD, so a worktree without one is a usage
# error before any suite runs.
if [ -n "$PASS_MARKER" ] && ! git rev-parse HEAD >/dev/null 2>&1; then
  echo "error: worktree has no resolvable git HEAD (required for the pass marker): $WORKTREE" >&2
  exit 2
fi

HAS_CARGO=0
[ -f Cargo.toml ] && HAS_CARGO=1
HAS_NPM=0
[ -f package.json ] && HAS_NPM=1

if [ "$HAS_CARGO" = 0 ] && [ "$HAS_NPM" = 0 ]; then
  echo "error: no supported repo markers found in $WORKTREE (looked for Cargo.toml, package.json; found neither)" >&2
  fail_step repo-detect
fi

if [ "$HAS_CARGO" = 1 ]; then
  if [ "$HAS_NPM" = 1 ]; then
    echo "note: both Cargo.toml and package.json present - using the cargo path"
  fi
  # fmt runs host-side even when a containerized helper exists: rustfmt only
  # parses (never compiles), and helpers may mount the worktree read-only.
  if cargo fmt --version >/dev/null 2>&1; then
    run_step cargo-fmt cargo fmt --all -- --check
  else
    echo "note: rustfmt not on this host - fmt rung skipped (CI still gates it)"
  fi
  if [ -f bin/dev.sh ]; then
    echo "note: bin/dev.sh present - delegating every cargo command to the containerized-build helper"
    if [ -x bin/dev.sh ]; then
      run_step dev-clippy bin/dev.sh clippy --all-targets --locked -- -D warnings
      run_step dev-test bin/dev.sh test --locked
    else
      echo "note: bin/dev.sh is not executable - running it through bash"
      run_step dev-clippy bash bin/dev.sh clippy --all-targets --locked -- -D warnings
      run_step dev-test bash bin/dev.sh test --locked
    fi
  else
    command -v cargo >/dev/null 2>&1 || {
      echo "error: cargo not found on PATH" >&2
      fail_step cargo-clippy
    }
    run_step cargo-clippy cargo clippy --all-targets --locked -- -D warnings
    run_step cargo-test cargo test --locked
  fi
elif [ "$HAS_NPM" = 1 ]; then
  command -v npm >/dev/null 2>&1 || {
    echo "error: npm not found on PATH" >&2
    fail_step npm-install
  }
  command -v node >/dev/null 2>&1 || {
    echo "error: node not found on PATH" >&2
    fail_step npm-scripts
  }
  LOCKFILE=
  if [ -f package-lock.json ]; then
    LOCKFILE=package-lock.json
  elif [ -f npm-shrinkwrap.json ]; then
    LOCKFILE=npm-shrinkwrap.json
  fi
  if [ -n "$LOCKFILE" ]; then
    gate_npm_install
  else
    echo "note: no package-lock.json or npm-shrinkwrap.json - running npm install"
    run_step npm-install npm install
  fi
  for script_name in check typecheck test; do
    npm_script_state "$script_name"
    present=$?
    case $present in
      0) run_step "npm-$script_name" npm run "$script_name" ;;
      1) echo "note: no \"$script_name\" script in package.json - skipping" ;;
      *) fail_step npm-scripts ;;
    esac
  done
fi

if [ -n "$PASS_MARKER" ]; then
  HEAD_SHA=$(git rev-parse HEAD 2>/dev/null) || fail_step record-head
  MARKER_TMP=$(mktemp "$STATE/.fm-gate-$ID.XXXXXX") || {
    echo "error: cannot create pass marker temp file in $STATE" >&2
    exit 2
  }
  printf 'head=%s ts=%s\n' "$HEAD_SHA" "$(date +%s)" > "$MARKER_TMP"
  chmod 0600 "$MARKER_TMP"
  mv -f -- "$MARKER_TMP" "$PASS_MARKER"
  echo "gate passed: state/$ID.gate-pass"
else
  echo "gate passed"
fi
