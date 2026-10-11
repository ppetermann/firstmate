#!/usr/bin/env bash
# fm-pool-disk-lib.sh - disk housekeeping for the Treehouse worker-copy pool:
# trimming a Rust copy's build output when it returns to the pool, deciding
# whether a pool copy is idle, and the free-space verdict a Rust dispatch reads.
#
# Rust copies dominate the pool's disk use. A copy keeps its ignored target/
# when it goes back to the pool, so the next task in it starts warm, but most of
# that directory is not worth keeping: the incremental caches only speed up the
# edit-recompile loop of the worker that wrote them, and the linked test and
# binary executables are relinked by the next build anyway and never deleted by
# Cargo. The compiled libraries (.rlib, .rmeta) are what keeps the next task
# warm, so they stay.
#
# This file is the single owner of:
#   - which part of a copy's target/ the pool-return trim removes
#     (fm_pool_trim_copy): every <target>/*/incremental/ directory and every
#     extensionless executable file directly in <target>/*/deps/, never an
#     .rlib, .rmeta, .d, .so, or anything outside those two places. Only the
#     copy's own top-level target/ is touched, so a nested firmware workspace's
#     target (for example pane/target) is never trimmed;
#   - what makes a directory a Rust copy whose target/ may be trimmed
#     (fm_pool_rust_target): a Cargo.toml at the copy's top, and a target/ that
#     is a real directory (not a symlink) which git reports as ignored, so only
#     regenerable build output is ever deleted;
#   - when a pool copy is idle (fm_pool_copy_idle_reason), read from Treehouse's
#     own state and Firstmate's records rather than guessed: Treehouse reports
#     the slot available with no lease, no slot-owner claim sits beside it
#     (bin/fm-wake-lib.sh owns the claim), and no task record in any local
#     Firstmate home names it as its worktree;
#   - the free-space verdict for a Rust dispatch (fm_pool_disk_free and
#     fm_pool_disk_verdict): warn below 20% free, refuse below 10% free, on the
#     filesystem holding the pool.
# bin/fm-teardown.sh owns when the trim runs, bin/fm-pool-sweep.sh owns the
# idle-copy sweep, bin/fm-spawn.sh owns where the free-space check runs, and
# docs/pool-disk.md is the operator reference.
#
# Deleting build output is best effort by design. A containerized build can
# leave root-owned files that this user cannot delete; the trim reports how many
# paths survived and the root-container command that removes them, and still
# returns success, so a cleanup step can never fail the cleanup it is part of.
#
# Requires bin/fm-wake-lib.sh (slot-owner claim, local Firstmate state
# directories) and bin/fm-secondmate-registry-lib.sh (which the local-homes walk
# reads) to be sourced first for fm_pool_copy_idle_reason; the trim and
# free-space helpers need neither. No side effects on source.

# Free-space thresholds, in whole percent of the pool filesystem's capacity.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_POOL_DISK_WARN_PCT=20
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_POOL_DISK_REFUSE_PCT=10

# The directory holding every Treehouse pool on this machine.
fm_pool_root() {
  printf '%s\n' "${FM_TREEHOUSE_POOL_ROOT:-$HOME/.treehouse}"
}

# Print <copy>/target when <copy> is a Rust copy whose target/ is regenerable
# build output; nonzero otherwise.
fm_pool_rust_target() {  # <copy>
  local copy=$1 target
  [ -f "$copy/Cargo.toml" ] || return 1
  target="$copy/target"
  [ -d "$target" ] && [ ! -L "$target" ] || return 1
  git -C "$copy" check-ignore -q target/ 2>/dev/null || return 1
  printf '%s\n' "$target"
}

# Kilobytes the given paths occupy, hard links counted once; 0 for none.
_fm_pool_du_kb() {
  local total
  [ "$#" -gt 0 ] || { printf '0\n'; return 0; }
  total=$(du -skc "$@" 2>/dev/null | tail -n 1 | awk '{print $1}')
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  printf '%s\n' "$total"
}

_fm_pool_mb() {  # <kb>
  printf '%s MB\n' "$(( ($1 + 512) / 1024 ))"
}

# Pool-return trim of one copy's target/. <mode> is apply or dry-run. Prints
# one summary line for a Rust copy (nothing for any other copy), plus a warning
# when any path survived deletion. Returns 0 for a well-formed call, including
# when nothing could be deleted, and 2 for a bad mode.
fm_pool_trim_copy() {  # <copy> <apply|dry-run>
  local copy=$1 mode=$2 target path before after failed=0 first_failed=''
  local -a cache_dirs=() files=() left=()
  case "$mode" in apply|dry-run) ;; *) return 2 ;; esac
  target=$(fm_pool_rust_target "$copy") || return 0
  while IFS= read -r path; do
    [ -n "$path" ] && cache_dirs+=("$path")
  done < <(find "$target" -mindepth 2 -maxdepth 2 -type d -name incremental 2>/dev/null)
  while IFS= read -r path; do
    [ -n "$path" ] && files+=("$path")
  done < <(find "$target" -mindepth 3 -maxdepth 3 -path "$target/*/deps/*" \
    -type f -perm -u+x ! -name '*.*' 2>/dev/null)
  before=$(_fm_pool_du_kb "${cache_dirs[@]+"${cache_dirs[@]}"}" "${files[@]+"${files[@]}"}")
  if [ "$mode" = dry-run ]; then
    printf 'trim: %s: would free %s (%s incremental cache dir(s), %s executable(s)); compiled libraries kept\n' \
      "$copy" "$(_fm_pool_mb "$before")" "${#cache_dirs[@]}" "${#files[@]}"
    return 0
  fi
  for path in "${cache_dirs[@]+"${cache_dirs[@]}"}" "${files[@]+"${files[@]}"}"; do
    rm -rf -- "$path" 2>/dev/null || true
    if [ -e "$path" ] || [ -L "$path" ]; then
      failed=$((failed + 1))
      [ -n "$first_failed" ] || first_failed=$path
      left+=("$path")
    fi
  done
  after=$(_fm_pool_du_kb "${left[@]+"${left[@]}"}")
  printf 'trim: %s: freed %s (%s incremental cache dir(s), %s executable(s)); compiled libraries kept\n' \
    "$copy" "$(_fm_pool_mb "$((before - after))")" "${#cache_dirs[@]}" "${#files[@]}"
  if [ "$failed" -gt 0 ]; then
    printf 'warning: trim: %s: %s path(s) could not be deleted (%s left), probably root-owned output of a container build; remove them with a root container, for example: sg docker -c "docker run --rm -v '"'"'%s'"'"':/w alpine rm -rf /w/%s"\n' \
      "$copy" "$failed" "$(_fm_pool_mb "$after")" "$target" "${first_failed#"$target"/}" >&2
  fi
  return 0
}

# Print why the pool copy at <copy> is NOT idle, or nothing and return 0 when it
# is. <status-json> is `treehouse status --json` for the copy's pool, read by the
# caller while it holds the project's Treehouse lock. Every check fails safe:
# anything that cannot be read is a reason, never an idle verdict.
fm_pool_copy_idle_reason() {  # <copy> <status-json>
  local copy=$1 json=$2 rows row path status='' holder='' matches=0 dir meta line
  rows=$(printf '%s' "$json" | jq -r \
    '.[] | "\(.status)\t\(.lease_holder // "")\t\(.path)"' 2>/dev/null) && [ -n "$rows" ] || {
    printf 'treehouse status is unreadable\n'
    return 1
  }
  while IFS= read -r row; do
    path=${row#*$'\t'}
    path=${path#*$'\t'}
    if [ "$path" = "$copy" ] || [ "$path" -ef "$copy" ]; then
      matches=$((matches + 1))
      status=${row%%$'\t'*}
      holder=${row#*$'\t'}
      holder=${holder%%$'\t'*}
    fi
  done <<EOF
$rows
EOF
  [ "$matches" = 1 ] || { printf 'treehouse lists it %s times\n' "$matches"; return 1; }
  [ -z "$holder" ] || { printf 'leased to %s\n' "$holder"; return 1; }
  [ "$status" = available ] || { printf 'treehouse reports it %s\n' "$status"; return 1; }
  fm_treehouse_slot_owner_state "$copy" ""
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    absent) ;;
    other) printf 'claimed by task %s\n' "$FM_TREEHOUSE_SLOT_OWNER_ID"; return 1 ;;
    *) printf 'its slot-owner claim is unreadable\n'; return 1 ;;
  esac
  fm_local_firstmate_state_dirs "$STATE" || {
    printf 'local task records cannot be read (%s)\n' "$FM_LOCAL_FIRSTMATE_ERROR"
    return 1
  }
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ -d "$dir" ] || continue
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          worktree=*|home=*)
            if [ "${line#*=}" = "$copy" ] || [ "${line#*=}" -ef "$copy" ]; then
              printf 'named by task record %s\n' "$meta"
              return 1
            fi
            ;;
        esac
      done < "$meta"
    done
  done
  return 0
}

# Free space on the filesystem holding <path>. Sets FM_POOL_DISK_FREE_KB,
# FM_POOL_DISK_SIZE_KB, FM_POOL_DISK_FREE_PCT (whole percent, rounded down), and
# FM_POOL_DISK_SUMMARY ("<free> GB free of <size> GB (<pct>%) on <mount>").
# Nonzero when df fails or prints something unparseable.
fm_pool_disk_free() {  # <path>
  local path=$1 line used avail mount
  line=$(df -P -k "$path" 2>/dev/null | tail -n 1) || return 1
  used=$(printf '%s\n' "$line" | awk '{print $3}')
  avail=$(printf '%s\n' "$line" | awk '{print $4}')
  mount=$(printf '%s\n' "$line" | awk '{print $NF}')
  case "$used$avail" in ''|*[!0-9]*) return 1 ;; esac
  [ $((used + avail)) -gt 0 ] || return 1
  FM_POOL_DISK_FREE_KB=$avail
  FM_POOL_DISK_SIZE_KB=$((used + avail))
  FM_POOL_DISK_FREE_PCT=$((avail * 100 / (used + avail)))
  # shellcheck disable=SC2034 # read by the sourcing caller.
  FM_POOL_DISK_SUMMARY="$((FM_POOL_DISK_FREE_KB / 1048576)) GB free of $((FM_POOL_DISK_SIZE_KB / 1048576)) GB ($FM_POOL_DISK_FREE_PCT%) on $mount"
}

# ok, warn, or refuse for the last fm_pool_disk_free reading.
fm_pool_disk_verdict() {
  if [ "$FM_POOL_DISK_FREE_PCT" -lt "$FM_POOL_DISK_REFUSE_PCT" ]; then
    printf 'refuse\n'
  elif [ "$FM_POOL_DISK_FREE_PCT" -lt "$FM_POOL_DISK_WARN_PCT" ]; then
    printf 'warn\n'
  else
    printf 'ok\n'
  fi
}
