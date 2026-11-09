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
# Repo detection (worktree root), first match wins:
#   1. Cargo.toml -> cargo path (also when package.json is present, with a
#      printed note).
#   2. package.json -> pnpm path when pnpm-lock.yaml exists, else npm path.
#   3. A Makefile (Makefile, makefile, GNUmakefile) defining a check, lint,
#      or test target -> make path.
#   4. pyproject.toml -> python path.
#   5. Every file is documentation -> docs-only: no ladder, an explicit
#      pass that still records the pass marker.
#   6. Anything else, including an empty worktree or a Makefile with none of
#      those targets -> gate failure at repo-detect listing the markers that
#      were looked for. The gate never passes a repo it failed to recognise.
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
# pnpm path: pnpm install --frozen-lockfile (with modules-purge confirmation
# off, so a node_modules left in another layout is rebuilt instead of
# prompting), then the same check, typecheck, test script rule via pnpm run.
# npm is never run on a pnpm repo: its installer crashes on pnpm's
# node_modules layout.
# make path: a Makefile target is a line starting "<name>:" (not ":=").
# When pyproject.toml is also present the repo is Python: a Makefile that
# declares VENV ?= gets VENV=<gate venv> on every make call and one that
# declares PYTHON ?= gets PYTHON=<gate interpreter> (both below), and its
# install target, if defined, is the install rung (make install) under the
# Python clean-context rule below. Without pyproject.toml no install target
# is run, because there it may mean installing onto the host. Then make
# check when a check target exists - the repo's own CI-equivalent ladder, as
# the Python repos' Makefiles declare it - otherwise make lint and make
# test, each when defined. The gate does not execute .github/workflows
# itself: those files mix in publish, container, and forge-only steps, so
# the repo's own ladder target is the CI-equivalent entry point.
# python path (pyproject.toml without a Makefile ladder): with uv.lock, uv
# sync --locked builds the gate venv exactly from the lockfile; otherwise
# the gate interpreter's -m venv creates it and pip install -e ".[dev]"
# fills it when a dev extra is declared, else pip install -e .; then ruff
# check . when ruff is configured (a [tool.ruff] table, ruff.toml, or
# .ruff.toml), then python -m pytest, both from the gate venv. A missing
# tool fails its step by name.
# Gate venv: fm-local-gate-venv inside the worktree's own git dir (per
# worktree, never committed, outside the source tree, never the worker's own
# .venv); .venv in the worktree when it is not a git repository.
# Gate interpreter: the python-version values the repo's .github/workflows
# name, newest first as python3.<minor>, then python3; the first on PATH
# that can build a venv (imports ensurepip and venv) wins, and none fails
# python-venv naming every candidate tried.
# docs-only: every file git tracks or would track (untracked files not
# ignored count) is documentation - Markdown, reStructuredText, AsciiDoc,
# plain text, images, PDF, license and notice files, git and editor config,
# or anything under .github/. At least one such file must exist.
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
# without one, every npm run is a full install. pnpm install
# --frozen-lockfile is its own clean context: it relinks node_modules to
# exactly the lockfile and prunes anything extraneous, so it runs every
# time. Python follows the npm rule with its own marker over the dependency
# inputs present (pyproject.toml, uv.lock, poetry.lock, setup.py, setup.cfg,
# the Makefile, requirements*.txt, *constraints*.txt): on a first run or a
# changed hash the gate venv is removed and the install rung runs, while an
# unchanged hash with the gate venv present skips it with a note. A Makefile
# that does not declare VENV ?= installs where it chooses, so make install
# then runs every time. uv sync --locked runs every time, since it already
# makes the gate venv match the
# lockfile exactly. For cargo, the repo's own
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

# Absolute path of a per-worktree install hash marker inside the git dir, or
# nothing when the worktree is not a git repository (every install is then a
# full one).
gate_marker_path() {  # <marker-name>
  local d
  d=$(git rev-parse --git-dir 2>/dev/null) || return 0
  case "$d" in
    /*) printf '%s/%s\n' "$d" "$1" ;;
    *) printf '%s/%s/%s\n' "$PWD" "$d" "$1" ;;
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
  marker_path=$(gate_marker_path fm-local-gate-lockhash)
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

# Run every script present among check, typecheck, and test via <tool> run.
run_package_scripts() {  # <npm|pnpm>
  local tool=$1 script_name present
  for script_name in check typecheck test; do
    npm_script_state "$script_name"
    present=$?
    case $present in
      0) run_step "$tool-$script_name" "$tool" run "$script_name" ;;
      1) echo "note: no \"$script_name\" script in package.json - skipping" ;;
      *) fail_step "$tool-scripts" ;;
    esac
  done
}

make_has_target() {  # <target>
  grep -Eq "^$1[[:space:]]*:([^=]|\$)" "$MAKEFILE"
}

# Content hash over every Python dependency input present, in a fixed order.
python_deps_hash() {
  local f out=
  for f in pyproject.toml uv.lock poetry.lock setup.py setup.cfg "$MAKEFILE" \
    requirements*.txt *constraints*.txt; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    out="$out$f=$(file_hash "$f") "
  done
  printf '%s\n' "$out"
}

# Python clean-context install decision per the header: remove the gate venv
# and run the install command on a first run or changed inputs, skip
# otherwise.
python_clean_install() {  # <command> [args...]
  local current_hash marker_path marker_hash
  current_hash=$(python_deps_hash)
  marker_path=$(gate_marker_path fm-local-gate-pyhash)
  marker_hash=
  [ -z "$marker_path" ] || marker_hash=$(cat "$marker_path" 2>/dev/null)
  if [ -d "$GATE_VENV" ] && [ -n "$marker_path" ] && [ -n "$marker_hash" ] \
    && [ "$marker_hash" = "$current_hash" ]; then
    echo "note: Python dependency inputs unchanged since the last gate install and the gate venv present - skipping the reinstall (trusts the previous gate install)"
    return 0
  fi
  if [ ! -d "$GATE_VENV" ]; then
    echo "note: no gate venv yet - full clean install into $GATE_VENV"
  elif [ -z "$marker_path" ] || [ -z "$marker_hash" ]; then
    echo "note: first gate run on this worktree - rebuilding the gate venv for a full clean install"
  else
    echo "note: Python dependency inputs changed since the last gate install - rebuilding the gate venv for a full clean install"
  fi
  rm -rf -- "$GATE_VENV"
  "$@"
  [ -z "$marker_path" ] || printf '%s\n' "$current_hash" > "$marker_path"
}

# Python minor versions the repo's workflows name, newest first.
workflow_python_versions() {
  [ -d .github/workflows ] || return 0
  find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
    -exec grep -h 'python-version' {} + 2>/dev/null \
    | grep -oE '3\.[0-9]+' | sort -t. -k2,2nr -u
}

# Sets GATE_PYTHON to the first candidate that can build a venv, or fails.
select_gate_python() {
  local v candidate tried=
  for candidate in $(workflow_python_versions | sed 's/^/python/') python3; do
    case " $tried " in *" $candidate "*) continue ;; esac
    tried="${tried:+$tried }$candidate"
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" -c 'import ensurepip, venv' >/dev/null 2>&1; then
      GATE_PYTHON=$candidate
      v=$("$candidate" --version 2>&1)
      echo "note: gate interpreter: $candidate (${v:-unknown version})"
      return 0
    fi
  done
  echo "error: no Python interpreter on PATH can build a venv (tried: $tried)" >&2
  fail_step python-venv
}

# 0 yes, 1 no, 2 pyproject.toml unreadable or not valid TOML. Parses with
# tomllib (python3 3.11+); an older or absent python3 falls back to a line scan for a
# [tool.ruff] table or a dev = entry under [project.optional-dependencies].
pyproject_has() {  # dev-extra|ruff
  local rc
  python3 -c '
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
try:
    with open("pyproject.toml", "rb") as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(2)
if sys.argv[1] == "dev-extra":
    extras = (data.get("project") or {}).get("optional-dependencies") or {}
    sys.exit(0 if "dev" in extras else 1)
sys.exit(0 if "ruff" in (data.get("tool") or {}) else 1)
' "$1" 2>/dev/null
  rc=$?
  case $rc in 0|1|2) return "$rc" ;; esac
  [ -r pyproject.toml ] || return 2
  if [ "$1" = dev-extra ]; then
    awk '
      /^[[:space:]]*\[/ { in_extras = ($0 ~ /^[[:space:]]*\[project\.optional-dependencies\][[:space:]]*$/); next }
      in_extras && /^[[:space:]]*"?dev"?[[:space:]]*=/ { found = 1 }
      END { exit found ? 0 : 1 }
    ' pyproject.toml
  else
    grep -Eq '^[[:space:]]*\[tool\.ruff([].])' pyproject.toml
  fi
}

python_pip_install() {
  local extra=.
  pyproject_has dev-extra
  case $? in
    0) extra='.[dev]' ;;
    1) echo "note: no dev extra declared in pyproject.toml - installing the project alone" ;;
    *) fail_step python-config ;;
  esac
  run_step python-venv "$GATE_PYTHON" -m venv "$GATE_VENV"
  run_step python-install "$GATE_VENV/bin/python" -m pip install -e "$extra"
}

is_doc_file() {  # <repo-relative path>
  local base=${1##*/} rc=1
  case "$1" in .github/*) return 0 ;; esac
  shopt -s nocasematch
  case "$base" in
    requirements*.txt|*constraints*.txt|cmakelists.txt) rc=1 ;;
    *.md|*.markdown|*.mdx|*.rst|*.adoc|*.asciidoc|*.txt|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp|*.ico|*.pdf) rc=0 ;;
    license|license.*|licence|licence.*|copying|copying.*|notice|notice.*|authors|authors.*|codeowners) rc=0 ;;
    .gitignore|.gitattributes|.gitmodules|.mailmap|.editorconfig|.markdownlint*) rc=0 ;;
  esac
  shopt -u nocasematch
  return $rc
}

# 0 when the tree holds at least one file and every file is documentation;
# otherwise 1 with the first non-documentation file in NON_DOC_FILE.
NON_DOC_FILE=
docs_only_tree() {
  local f seen=0 list
  if git rev-parse --git-dir >/dev/null 2>&1; then
    list=$(git ls-files --cached --others --exclude-standard) || return 1
  else
    list=$(find . -path ./.git -prune -o -type f -print) || return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f=${f#./}
    if ! is_doc_file "$f"; then
      NON_DOC_FILE=$f
      return 1
    fi
    seen=1
  done <<EOF
$list
EOF
  [ "$seen" = 1 ]
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

MAKEFILE=
for candidate in GNUmakefile makefile Makefile; do
  if [ -f "$candidate" ]; then
    MAKEFILE=$candidate
    break
  fi
done

REPO_KIND=
if [ -f Cargo.toml ]; then
  REPO_KIND=cargo
  if [ -f package.json ]; then
    echo "note: both Cargo.toml and package.json present - using the cargo path"
  fi
elif [ -f package.json ]; then
  REPO_KIND=npm
  [ ! -f pnpm-lock.yaml ] || REPO_KIND=pnpm
elif [ -n "$MAKEFILE" ] && { make_has_target check || make_has_target lint || make_has_target test; }; then
  REPO_KIND="make"
elif [ -f pyproject.toml ]; then
  REPO_KIND=python
elif docs_only_tree; then
  REPO_KIND=docs
fi

if [ -z "$REPO_KIND" ]; then
  echo "error: no supported repo markers found in $WORKTREE (looked for Cargo.toml, package.json, a Makefile with a check, lint, or test target, pyproject.toml, or a documentation-only tree; found none)" >&2
  [ -z "$MAKEFILE" ] || echo "note: $MAKEFILE defines none of the check, lint, or test targets" >&2
  [ -z "$NON_DOC_FILE" ] || echo "note: not documentation-only: $NON_DOC_FILE" >&2
  fail_step repo-detect
fi

GATE_PYTHON=
GATE_VENV=$(gate_marker_path fm-local-gate-venv)
[ -n "$GATE_VENV" ] || GATE_VENV="$PWD/.venv"

case $REPO_KIND in
cargo)
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
  ;;
npm)
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
  run_package_scripts npm
  ;;
pnpm)
  echo "note: pnpm-lock.yaml present - using the pnpm path"
  command -v pnpm >/dev/null 2>&1 || {
    echo "error: pnpm not found on PATH" >&2
    fail_step pnpm-install
  }
  command -v node >/dev/null 2>&1 || {
    echo "error: node not found on PATH" >&2
    fail_step pnpm-scripts
  }
  run_step pnpm-install pnpm install --frozen-lockfile --config.confirm-modules-purge=false
  run_package_scripts pnpm
  ;;
make)
  command -v make >/dev/null 2>&1 || {
    echo "error: make not found on PATH" >&2
    fail_step make-detect
  }
  MAKE_VARS=()
  if [ -f pyproject.toml ]; then
    if grep -Eq '^PYTHON[[:space:]]*\?=' "$MAKEFILE"; then
      select_gate_python
      MAKE_VARS+=("PYTHON=$GATE_PYTHON")
    fi
    if grep -Eq '^VENV[[:space:]]*\?=' "$MAKEFILE"; then
      MAKE_VARS+=("VENV=$GATE_VENV")
      if make_has_target install; then
        python_clean_install run_step make-install make ${MAKE_VARS[@]+"${MAKE_VARS[@]}"} install
      fi
    elif make_has_target install; then
      echo "note: $MAKEFILE does not declare VENV ?= - make install runs every time into the environment it chooses"
      run_step make-install make ${MAKE_VARS[@]+"${MAKE_VARS[@]}"} install
    fi
    make_has_target install \
      || echo "note: $MAKEFILE defines no install target - the ladder runs against the environment its own targets set up"
  fi
  if make_has_target check; then
    run_step make-check make ${MAKE_VARS[@]+"${MAKE_VARS[@]}"} check
  else
    for target in lint test; do
      if make_has_target "$target"; then
        run_step "make-$target" make ${MAKE_VARS[@]+"${MAKE_VARS[@]}"} "$target"
      else
        echo "note: no \"$target\" target in $MAKEFILE - skipping"
      fi
    done
  fi
  ;;
python)
  if [ -f uv.lock ]; then
    command -v uv >/dev/null 2>&1 || {
      echo "error: uv.lock present but uv not found on PATH" >&2
      fail_step uv-sync
    }
    run_step uv-sync env UV_PROJECT_ENVIRONMENT="$GATE_VENV" uv sync --locked
  else
    select_gate_python
    python_clean_install python_pip_install
  fi
  pyproject_has ruff
  ruff_state=$?
  if [ "$ruff_state" = 2 ]; then
    fail_step python-config
  elif [ "$ruff_state" = 0 ] || [ -f ruff.toml ] || [ -f .ruff.toml ]; then
    run_step python-lint "$GATE_VENV/bin/python" -m ruff check .
  else
    echo "note: ruff not configured - lint rung skipped"
  fi
  run_step python-test "$GATE_VENV/bin/python" -m pytest
  ;;
docs)
  echo "note: documentation-only tree - no build, lint, or test ladder exists to run (explicit no-ladder pass)"
  ;;
esac

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
