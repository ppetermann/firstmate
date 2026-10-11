#!/usr/bin/env bash
# Trim the Rust build output of idle Treehouse pool copies.
#
# Usage: fm-pool-sweep.sh [--dry-run] [--max-size <size>] [--age-days <days>]
#        fm-pool-sweep.sh trim [--dry-run] <copy>
#
# The default form walks every pool under the Treehouse pool root
# ($FM_TREEHOUSE_POOL_ROOT, default ~/.treehouse) and, for each copy that is
# idle and holds a Rust target/, runs `cargo-sweep sweep --maxsize <size>` and
# then `cargo-sweep sweep --time <days>` against that copy, so an idle copy is
# capped in size (oldest artifacts go first) and loses whatever no build
# touched for <days> days. --max-size takes cargo-sweep's size syntax (a number
# of MB, or a number with a KB, MB, GB, or TB suffix) and defaults to 15GB;
# --age-days defaults to 2. Only the copy's own top-level target/ is swept,
# never a nested workspace's target such as a firmware build.
#
# The trim form applies the pool-return trim bin/fm-teardown.sh runs (every
# incremental cache and every linked test or binary executable, keeping the
# compiled libraries) to one idle copy, for example to measure its effect on a
# copy returned before that trim existed.
#
# --dry-run reports what would be removed and removes nothing.
#
# A copy is swept only when bin/fm-pool-disk-lib.sh's fm_pool_copy_idle_reason
# finds it idle: Treehouse reports it available with no lease, no slot-owner
# claim sits beside it, and no task record in any local Firstmate home names it.
# cargo-sweep does not take Cargo's build lock, so sweeping a copy a worker is
# building in could delete files its compiler is about to read; the idle check
# is what prevents that. Each copy is checked again and swept while this script
# holds the project's shared Treehouse lock (bin/fm-wake-lib.sh's
# fm_treehouse_project_lock_path), the lock a Firstmate spawn holds from slot
# allocation through its slot-owner claim, so a spawn cannot take the copy
# between the check and the sweep. A lock another spawn or cleanup holds skips
# that copy for this run instead of waiting, and a spawn that meets the lock
# while a copy is being swept refuses rather than racing it, so the sweep is
# meant for a quiet hour. A pool whose project clone or Treehouse status cannot
# be read is skipped whole.
#
# Removal is best effort: a path cargo-sweep cannot delete (for example
# root-owned output of a container build) is reported and the walk continues.
# Exits 0 after a completed walk, 1 when cargo-sweep (default form) or the copy
# (trim form) is unusable, and 2 on a usage error.
# docs/pool-disk.md holds the systemd user unit and timer that run this nightly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pool-disk-lib.sh
. "$SCRIPT_DIR/fm-pool-disk-lib.sh"

MODE=sweep
DRY_RUN=0
MAX_SIZE=15GB
AGE_DAYS=2
COPY=
want=
if [ "${1:-}" = trim ]; then
  MODE=trim
  shift
fi
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      max-size) MAX_SIZE=$a ;;
      age-days) AGE_DAYS=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --max-size|--age-days)
      [ "$MODE" = sweep ] || { echo "error: $a applies only to the sweep form" >&2; exit 2; }
      want=${a#--}
      ;;
    -*) echo "error: unknown option $a" >&2; exit 2 ;;
    *)
      [ "$MODE" = trim ] && [ -z "$COPY" ] || { echo "error: unexpected argument $a" >&2; exit 2; }
      COPY=$a
      ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 2; }
case "$MAX_SIZE" in
  ''|*[!0-9KMGTBkmgtib]*|[!0-9]*) echo "error: --max-size must be a size such as 15GB or 500" >&2; exit 2 ;;
esac
case "$AGE_DAYS" in
  ''|*[!0-9]*|0) echo "error: --age-days must be a positive whole number of days" >&2; exit 2 ;;
esac

# The project clone a pool copy belongs to: the work tree that owns the copy's
# shared git directory.
copy_project() {  # <copy>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$(basename "$common")" = .git ] || return 1
  common=$(dirname "$common")
  [ -d "$common" ] || return 1
  printf '%s\n' "$common"
}

pool_status_json() {  # <project>
  (cd "$1" && treehouse status --json) 2>/dev/null
}

LOCK_HELD=
release_lock() {
  [ -n "$LOCK_HELD" ] || return 0
  fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=
}
trap release_lock EXIT

# Re-check <copy> under its project's lock and run <action> on it when it is
# still idle. Prints one skip line otherwise.
with_idle_copy() {  # <copy> <action...>
  local copy=$1 project lock json reason
  shift
  project=$(copy_project "$copy") || { echo "skip: $copy: its project clone cannot be resolved"; return 0; }
  fm_treehouse_pool_slot "$project" "$copy" || { echo "skip: $copy: not a Treehouse pool copy of $project"; return 0; }
  lock=$(fm_treehouse_project_lock_path "$project") || { echo "skip: $copy: the project lock cannot be resolved"; return 0; }
  fm_lock_try_acquire "$lock" || { echo "skip: $copy: a spawn or cleanup holds the project lock"; return 0; }
  LOCK_HELD=$lock
  json=$(pool_status_json "$project") || json=
  if reason=$(fm_pool_copy_idle_reason "$copy" "$json"); then
    "$@" "$copy"
  else
    echo "skip: $copy: $reason"
  fi
  release_lock
}

cargo_sweep_copy() {  # <copy>
  local copy=$1 flag=()
  [ "$DRY_RUN" = 0 ] || flag=(--dry-run)
  echo "sweep: $copy: size cap $MAX_SIZE, then artifacts unused for $AGE_DAYS day(s)"
  (cd "$copy" && cargo-sweep sweep "${flag[@]+"${flag[@]}"}" --maxsize "$MAX_SIZE" "$copy") 2>&1 ||
    echo "warning: sweep: $copy: cargo-sweep --maxsize did not finish cleanly" >&2
  (cd "$copy" && cargo-sweep sweep "${flag[@]+"${flag[@]}"}" --time "$AGE_DAYS" "$copy") 2>&1 ||
    echo "warning: sweep: $copy: cargo-sweep --time did not finish cleanly" >&2
}

trim_copy() {  # <copy>
  if [ "$DRY_RUN" = 1 ]; then
    fm_pool_trim_copy "$1" dry-run
  else
    fm_pool_trim_copy "$1" apply
  fi
}

if [ "$MODE" = trim ]; then
  [ -n "$COPY" ] || { echo "error: trim needs the copy to trim" >&2; exit 2; }
  COPY=$(CDPATH='' cd -- "$COPY" 2>/dev/null && pwd -P) || { echo "error: no such copy: $COPY" >&2; exit 1; }
  fm_pool_rust_target "$COPY" >/dev/null || { echo "error: $COPY is not a Rust copy with an ignored target/" >&2; exit 1; }
  with_idle_copy "$COPY" trim_copy
  exit 0
fi

command -v cargo-sweep >/dev/null 2>&1 || { echo "error: cargo-sweep is not installed (cargo install cargo-sweep)" >&2; exit 1; }
POOL_ROOT=$(fm_pool_root)
[ -d "$POOL_ROOT" ] || { echo "sweep: no Treehouse pool root at $POOL_ROOT; nothing to do"; exit 0; }
swept=0
for state_file in "$POOL_ROOT"/*/treehouse-state.json; do
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || continue
  pool=$(dirname "$state_file")
  for copy in "$pool"/*/*; do
    [ -d "$copy" ] && [ ! -L "$copy" ] || continue
    copy=$(CDPATH='' cd -- "$copy" 2>/dev/null && pwd -P) || continue
    fm_pool_rust_target "$copy" >/dev/null || continue
    with_idle_copy "$copy" cargo_sweep_copy
    swept=$((swept + 1))
  done
done
echo "sweep: checked $swept Rust cop$([ "$swept" = 1 ] && echo y || echo ies) under $POOL_ROOT$([ "$DRY_RUN" = 1 ] && echo ' (dry run, nothing removed)' || true)"
