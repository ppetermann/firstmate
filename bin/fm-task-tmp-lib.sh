# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_TASK_TMP_* are results the caller reads after sourcing.
# fm-task-tmp-lib.sh - the optional real-disk per-task temp root
# (config/worker-tmp-root).
#
# Default (no config file): bin/fm-spawn.sh gives every task /tmp/fm-<id>/ and
# exports only GOTMPDIR into it, leaving TMPDIR alone on purpose (its comment at
# the per-task temp root says why); bin/fm-teardown.sh removes that root. None
# of the functions below changes that path.
#
# Opt-in: a local, gitignored config/worker-tmp-root holding one directory
# path moves the per-task root to <base>/fm-<id>/ and makes every
# launch - ship, scout, secondmate, and relaunch - export TMPDIR, TMP, and TEMP
# as <root>/tmp. That is the knob the agents themselves follow: on Linux Claude
# Code resolves CLAUDE_CODE_TMPDIR, then TMPDIR, TMP, TEMP, and places its
# per-uid claude-<uid>/<project>/<session>/ directory (session scratchpad, task
# output) there, and opencode puts its tmp directory at $TMPDIR/opencode; every
# tool a worker runs inherits the same value. So everything a worker writes to
# temp lands under its own per-task root, and teardown removing that root
# removes all of it. data/fleet-docs/worker-tmp-root.md records the probe.
# The file is inherited into secondmate homes (bin/fm-config-inherit-lib.sh), so
# a secondmate's own workers follow it too.
#
# Ownership marker: a relocated root carries <root>/.fm-home naming the
# physical path of the firstmate home that spawned it. It makes the root
# attributable - teardown removes only a root its own home created, and the
# session-start orphan report (fm_task_tmp_orphans) reports only roots that no
# task record of the owning home still names. Teardown treats a root without
# the marker exactly as before this file existed.
#
# Functions (every one returns non-zero with FM_TASK_TMP_ERROR set on refusal):
#   fm_task_tmp_config_read <config-dir>
#       Sets FM_TASK_TMP_BASE to the configured base path, or '' when the file
#       is absent. A present file must be a readable regular file holding one
#       path without whitespace or control characters, either absolute or
#       starting with ~/ (expanded against the launching user's HOME, so the
#       one value inherited by every secondmate home, local or remote, names
#       each host's own disk).
#   fm_task_tmp_private_dir <dir>
#       Creates <dir> 0700, or accepts an existing one only when it is a real
#       directory (not a symlink) owned by this user and writable by nobody
#       else, then tightens it to 0700. The same check spawn applies to the
#       default /tmp/fm-<id> root.
#   fm_task_tmp_base_prepare <base>
#       Creates <base> (and missing parents) privately, then sets
#       FM_TASK_TMP_BASE_REAL to its physical path; refuses a base owned by someone else or writable by
#       group or others, since the per-task roots inside it must not be
#       swappable by another user.
#   fm_task_tmp_claim <root> <home>
#       Records <home>'s physical path in <root>/.fm-home; refuses a root
#       whose marker already names another home.
#   fm_task_tmp_remove <root> <id> <home>
#       Guarded removal of a marked root. Returns 2 (and does nothing) when
#       <root> carries no marker, so the caller keeps its legacy removal.
#       Otherwise removes the root only when its basename is fm-<id>, it is a
#       real directory owned by this user under a symlink-free physical path,
#       and its marker names <home>; anything else is left in place with a
#       reason. Whatever it could not remove (for example files a container
#       wrote as another user) is reported by path and size. Report lines go
#       to stdout, prefixed "warning: ".
#   fm_task_tmp_orphans <base> <home> <state-dir>
#       Prints one "TASK_TMP_ORPHAN: <root> (<size>) - <why>" line per fm-*
#       root under <base> that this home owns and no state/*.meta tasktmp=
#       names, or that no live home owns at all; read-only, never deletes.
#       At most FM_TASK_TMP_ORPHAN_LIMIT (default 20) lines, then a count line.

FM_TASK_TMP_CONFIG_FILE="worker-tmp-root"
FM_TASK_TMP_MARKER=".fm-home"
FM_TASK_TMP_BASE=
FM_TASK_TMP_BASE_REAL=
FM_TASK_TMP_ERROR=

fm_task_tmp_config_read() {  # <config-dir>
  local file="$1/$FM_TASK_TMP_CONFIG_FILE" value
  FM_TASK_TMP_BASE=
  FM_TASK_TMP_ERROR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_TASK_TMP_ERROR="config/$FM_TASK_TMP_CONFIG_FILE must be a readable regular file"
    return 1
  fi
  value=$(cat "$file") || {
    FM_TASK_TMP_ERROR="config/$FM_TASK_TMP_CONFIG_FILE could not be read"
    return 1
  }
  case "$value" in
    *[[:space:][:cntrl:]]*|'')
      FM_TASK_TMP_ERROR="config/$FM_TASK_TMP_CONFIG_FILE must hold one directory path without whitespace"
      return 1
      ;;
  esac
  # shellcheck disable=SC2088 # The literal ~/ prefix is what this case matches.
  case "$value" in
    /*) ;;
    '~/'?*)
      case "${HOME:-}" in
        /*) value="${HOME%/}/${value#'~/'}" ;;
        *)
          FM_TASK_TMP_ERROR="config/$FM_TASK_TMP_CONFIG_FILE starts with ~/ but HOME is not an absolute path"
          return 1
          ;;
      esac
      ;;
    *)
      FM_TASK_TMP_ERROR="config/$FM_TASK_TMP_CONFIG_FILE must hold an absolute path or one starting with ~/"
      return 1
      ;;
  esac
  FM_TASK_TMP_BASE=$value
}

# True when <dir> is readable as group- or other-writable.
fm_task_tmp_shared_writable() {  # <dir>
  [ -n "$(find "$1" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]
}

fm_task_tmp_private_dir() {  # <dir>
  local dir=$1
  FM_TASK_TMP_ERROR=
  if (umask 077 && mkdir "$dir") 2>/dev/null; then
    return 0
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ] ||
    fm_task_tmp_shared_writable "$dir" || ! chmod 700 "$dir"; then
    FM_TASK_TMP_ERROR="task temp root $dir already exists and is not a private directory owned by this user"
    return 1
  fi
}

fm_task_tmp_base_prepare() {  # <base>
  local base=$1 physical
  FM_TASK_TMP_BASE_REAL=
  FM_TASK_TMP_ERROR=
  if ! (umask 077 && mkdir -p "$base") 2>/dev/null || [ ! -d "$base" ]; then
    FM_TASK_TMP_ERROR="configured worker temp base $base could not be created as a directory"
    return 1
  fi
  physical=$(cd -P "$base" 2>/dev/null && pwd -P) || {
    FM_TASK_TMP_ERROR="configured worker temp base $base could not be resolved"
    return 1
  }
  if [ ! -O "$physical" ] || fm_task_tmp_shared_writable "$physical"; then
    FM_TASK_TMP_ERROR="configured worker temp base $physical must be owned by this user and not writable by group or others"
    return 1
  fi
  FM_TASK_TMP_BASE_REAL=$physical
}

# Physical path of a home directory, or the path as given when it cannot be
# resolved (a home that no longer exists).
fm_task_tmp_home_path() {  # <home>
  (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# Prints the home recorded in <root>'s marker; fails when there is no readable
# regular marker file.
fm_task_tmp_marker_home() {  # <root>
  local marker="$1/$FM_TASK_TMP_MARKER"
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || return 1
  head -n 1 "$marker"
}

fm_task_tmp_claim() {  # <root> <home>
  local root=$1 home recorded
  home=$(fm_task_tmp_home_path "$2")
  FM_TASK_TMP_ERROR=
  if [ -e "$root/$FM_TASK_TMP_MARKER" ] || [ -L "$root/$FM_TASK_TMP_MARKER" ]; then
    if ! recorded=$(fm_task_tmp_marker_home "$root"); then
      FM_TASK_TMP_ERROR="task temp root $root carries an unreadable ownership marker"
      return 1
    fi
    if [ "$recorded" != "$home" ]; then
      FM_TASK_TMP_ERROR="task temp root $root belongs to another firstmate home ($recorded)"
      return 1
    fi
    return 0
  fi
  if ! (umask 077 && printf '%s\n' "$home" >"$root/$FM_TASK_TMP_MARKER"); then
    FM_TASK_TMP_ERROR="could not record the ownership marker in task temp root $root"
    return 1
  fi
}

# Human-readable size of <path>, or "unknown size".
fm_task_tmp_size() {  # <path>
  local size
  size=$(du -sh "$1" 2>/dev/null | tail -n 1 | cut -f1)
  printf '%s\n' "${size:-unknown size}"
}

fm_task_tmp_remove() {  # <root> <id> <home>
  local root=$1 id=$2 home recorded parent reason=
  [ -n "$root" ] || return 2
  [ -e "$root/$FM_TASK_TMP_MARKER" ] || [ -L "$root/$FM_TASK_TMP_MARKER" ] || return 2
  home=$(fm_task_tmp_home_path "$3")
  parent=$(cd -P "$(dirname "$root")" 2>/dev/null && pwd -P) || parent=
  if [ "$(basename "$root")" != "fm-$id" ]; then
    reason="its name is not fm-$id"
  elif [ -z "$parent" ] || [ "$parent/fm-$id" != "$root" ]; then
    reason="its recorded path is not a symlink-free physical path"
  elif [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ]; then
    reason="it is not a real directory owned by this user"
  elif ! recorded=$(fm_task_tmp_marker_home "$root"); then
    reason="its ownership marker is unreadable"
  elif [ "$recorded" != "$home" ]; then
    reason="its ownership marker names another firstmate home ($recorded)"
  fi
  if [ -n "$reason" ]; then
    echo "warning: task temp root $root was NOT removed because $reason; it holds $(fm_task_tmp_size "$root") - inspect it and remove it by hand"
    return 1
  fi
  rm -rf "$root" 2>/dev/null
  if [ -e "$root" ] || [ -L "$root" ]; then
    echo "warning: task temp root $root could not be fully removed; $(fm_task_tmp_size "$root") is left behind, likely files owned by another user (for example written by a container) - remove it by hand, with sudo if needed"
    return 1
  fi
  return 0
}

fm_task_tmp_orphans() {  # <base> <home> <state-dir>
  local base=$1 state=$3 home physical root recorded why limit count=0 printed=0
  home=$(fm_task_tmp_home_path "$2")
  limit=${FM_TASK_TMP_ORPHAN_LIMIT:-20}
  case "$limit" in ''|*[!0-9]*) limit=20 ;; esac
  physical=$(cd -P "$base" 2>/dev/null && pwd -P) || return 0
  for root in "$physical"/fm-*; do
    [ -d "$root" ] && [ ! -L "$root" ] || continue
    why=
    if recorded=$(fm_task_tmp_marker_home "$root"); then
      if [ "$recorded" = "$home" ]; then
        if ! grep -qxF "tasktmp=$root" "$state"/*.meta 2>/dev/null; then
          why="no task record in this home names it"
        fi
      elif [ ! -d "$recorded" ]; then
        why="the firstmate home that created it ($recorded) no longer exists"
      fi
    else
      why="it carries no ownership marker"
    fi
    [ -n "$why" ] || continue
    count=$((count + 1))
    if [ "$printed" -lt "$limit" ]; then
      echo "TASK_TMP_ORPHAN: $root ($(fm_task_tmp_size "$root")) - $why; not removed automatically"
      printed=$((printed + 1))
    fi
  done
  if [ "$count" -gt "$printed" ]; then
    echo "TASK_TMP_ORPHAN: $((count - printed)) more orphaned task temp root(s) under $physical not listed"
  fi
}
