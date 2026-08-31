#!/usr/bin/env bash
# fm-backlog-guard.sh - the one checkpoint any raw (non-tasks-axi) write to
# data/backlog.md must pass through.
#
# INCIDENT (2026-08-30): an ad-hoc script hand-edited data/backlog.md directly
# and a bad line silently dropped every Done-history entry below a marker.
# tasks-axi was the active, compatible backend at the time and already covers
# every routine mutation (add/done/prune/update/render); the edit bypassed it
# for no capability reason, and nothing backed up the prior content or checked
# the result before it became the live file. `config/backlog-backend=manual`
# (docs/configuration.md "Backlog backend") is the only sanctioned reason to
# hand-edit at all, and even then the edit must go through this script instead
# of overwriting data/backlog.md directly.
#
# Usage:
#   fm-backlog-guard.sh check <candidate-backlog> [<candidate-archive>]
#       Read-only. Validates a proposed backlog.md (and, only if the edit also
#       rewrites the archive, a proposed done-archive.md) against the live
#       files. Prints one "REFUSED: ..." line per violation to stderr; exits 0
#       only when there are none.
#   fm-backlog-guard.sh apply <candidate-backlog> [<candidate-archive>]
#       Runs check; on pass, backs up the live file(s) under
#       state/.backlog-guard-backups/ (keeping the most recent
#       FM_BACKLOG_GUARD_KEEP, default 20, per file) and atomically installs
#       the candidate(s). On failure the live file(s) are left untouched and
#       nothing is backed up.
#
# Checks performed (any failure refuses the write):
#   - the candidate backlog parses with `tasks-axi list --file` when
#     compatible tasks-axi is on PATH (skipped, not waived, when it is not -
#     the id check below still applies regardless);
#   - every "## ..." section header present in the live backlog is still
#     present in the candidate (a truncated file that still parses cleanly
#     would otherwise pass check 1);
#   - every task id present in the live backlog plus the live archive is still
#     present in the candidate backlog plus the candidate archive. An id may
#     move between the two or change its checkbox state, but it may never
#     silently vanish - this is what would have caught the 2026-08-30
#     truncation.
#
# FM_ROOT_OVERRIDE / FM_HOME select the home under test, the same convention
# as bin/fm-lease.sh. The archive path is read from the tracked .tasks.toml
# (falling back to data/done-archive.md) so this stays in sync with the
# `.tasks.toml` config that tasks-axi itself reads.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKLOG_GUARD_KEEP="${FM_BACKLOG_GUARD_KEEP:-20}"

BACKLOG="$FM_HOME/data/backlog.md"
BACKUP_DIR="$FM_HOME/state/.backlog-guard-backups"

usage() {
  echo "usage: fm-backlog-guard.sh check|apply <candidate-backlog> [<candidate-archive>]" >&2
  exit 2
}

archive_path() {
  local toml="$FM_ROOT/.tasks.toml" value
  if [ -f "$toml" ]; then
    value=$(sed -n 's/^archive[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$toml" | head -1)
  fi
  printf '%s\n' "$FM_HOME/${value:-data/done-archive.md}"
}

task_ids() { # <file>
  [ -f "$1" ] || return 0
  awk '
    /^- \[[ xX]\] / {
      rest = $0
      sub(/^- \[[ xX]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id != "") print id
    }
  ' "$1"
}

section_headers() { # <file>
  [ -f "$1" ] || return 0
  grep -E '^##[[:space:]]' "$1" | sed -E 's/[[:space:]]+$//'
}

CMD=${1:-}
CANDIDATE_BACKLOG=${2:-}
CANDIDATE_ARCHIVE=${3:-}
[ -n "$CMD" ] && [ -n "$CANDIDATE_BACKLOG" ] || usage
case "$CMD" in check | apply) ;; *) usage ;; esac
[ -f "$CANDIDATE_BACKLOG" ] || {
  echo "fm-backlog-guard: candidate backlog not found: $CANDIDATE_BACKLOG" >&2
  exit 2
}

LIVE_ARCHIVE=$(archive_path)
EFFECTIVE_CANDIDATE_ARCHIVE=${CANDIDATE_ARCHIVE:-$LIVE_ARCHIVE}

FAILURES=0
fail_check() {
  FAILURES=$((FAILURES + 1))
  echo "REFUSED: $1" >&2
}

# 1. tasks-axi parse check (best-effort - skipped, not waived, without it).
if command -v tasks-axi >/dev/null 2>&1; then
  if ! tasks-axi list --file "$CANDIDATE_BACKLOG" >/dev/null 2>&1; then
    fail_check "candidate backlog does not parse with 'tasks-axi list --file'"
  fi
fi

# 2. section headers never silently disappear.
OLD_HEADERS=$(section_headers "$BACKLOG")
NEW_HEADERS=$(section_headers "$CANDIDATE_BACKLOG")
while IFS= read -r header; do
  [ -n "$header" ] || continue
  grep -qxF "$header" <<<"$NEW_HEADERS" || fail_check "section header dropped: $header"
done <<<"$OLD_HEADERS"

# 3. every task id survives somewhere.
OLD_IDS=$(
  {
    task_ids "$BACKLOG"
    task_ids "$LIVE_ARCHIVE"
  } | sort -u
)
NEW_IDS=$(
  {
    task_ids "$CANDIDATE_BACKLOG"
    task_ids "$EFFECTIVE_CANDIDATE_ARCHIVE"
  } | sort -u
)
if [ -n "$OLD_IDS" ]; then
  MISSING=$(comm -23 <(printf '%s\n' "$OLD_IDS") <(printf '%s\n' "$NEW_IDS"))
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fail_check "task id vanished: $id"
  done <<<"$MISSING"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "fm-backlog-guard: $FAILURES check(s) failed, refusing" >&2
  exit 1
fi

[ "$CMD" = check ] && exit 0

# apply: back up the live file(s), then atomically install the candidate(s).
mkdir -p "$BACKUP_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
if [ -f "$BACKLOG" ]; then
  cp -p "$BACKLOG" "$BACKUP_DIR/backlog.md.$STAMP"
fi
if [ -n "$CANDIDATE_ARCHIVE" ] && [ -f "$LIVE_ARCHIVE" ]; then
  cp -p "$LIVE_ARCHIVE" "$BACKUP_DIR/done-archive.md.$STAMP"
fi

mkdir -p "$(dirname "$BACKLOG")"
TMP_INSTALL="$BACKLOG.guard-tmp.$$"
cp "$CANDIDATE_BACKLOG" "$TMP_INSTALL"
mv "$TMP_INSTALL" "$BACKLOG"

if [ -n "$CANDIDATE_ARCHIVE" ]; then
  mkdir -p "$(dirname "$LIVE_ARCHIVE")"
  TMP_ARCHIVE_INSTALL="$LIVE_ARCHIVE.guard-tmp.$$"
  cp "$CANDIDATE_ARCHIVE" "$TMP_ARCHIVE_INSTALL"
  mv "$TMP_ARCHIVE_INSTALL" "$LIVE_ARCHIVE"
fi

# Prune old backups, keeping the most recent FM_BACKLOG_GUARD_KEEP per file.
for prefix in backlog.md done-archive.md; do
  find "$BACKUP_DIR" -maxdepth 1 -name "$prefix.*" -printf '%T@ %p\n' 2>/dev/null |
    sort -rn |
    tail -n "+$((FM_BACKLOG_GUARD_KEEP + 1))" |
    cut -d' ' -f2- |
    while IFS= read -r old; do
      [ -n "$old" ] && rm -f "$old"
    done
done

echo "fm-backlog-guard: applied, backup at $BACKUP_DIR/backlog.md.$STAMP"
