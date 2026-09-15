#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process belong to that same session?" decision -
# by harness ancestry first, then by the stable per-session token fallback
# defined below - and of the classification that distinguishes a recoverable
# session-identity divergence from a genuinely competing live session
# (fm_session_lock_identity_state).
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake;
# bin/fm-turnend-guard.sh uses it to keep the sidecar valid for the session's
# lifetime and to name the cause when the auto-arm is structurally inert.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Claude Code's stable per-session identity, carried in every hook subprocess'
# own environment regardless of OS process ancestry. This is the only signal
# that still identifies a Claude daemon-hosted background session: unlike a
# harness-named daemon that literally OS-parents its session (already covered
# by ancestry membership below), a daemon-hosted session's hook subprocesses
# are dispatched with no OS ancestry path back to the process that wrote the
# lock at session start, so ancestry walking finds nothing to match at all.
# Sanitized and length-bounded before use, exactly like the lock-sidecar
# filename it becomes: never trust it unsanitized, and treat anything
# malformed as absent rather than as a wildcard match.
fm_claude_session_token() {
  local raw=${CLAUDE_CODE_SESSION_ID:-}
  [ -n "$raw" ] || return 1
  case "$raw" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#raw}" -le 128 ] || return 1
  printf '%s' "$raw"
}

# Write (or refresh) state dir $2's session-identity sidecar, binding pid $1
# (the pid fm-lock.sh just recorded in state/.lock) to this process' stable
# Claude session token. Best-effort and silent: this sidecar is an ADDITIONAL
# self-recognition path on top of state/.lock, never a substitute for it, so a
# write failure here must never fail lock acquisition itself. A session with
# no stable token (every non-Claude harness, and Claude outside a hook) simply
# leaves no sidecar, which fm_session_lock_owned_by_self treats as absent.
fm_session_lock_write_sidecar() {  # <pid> <state-dir>
  local pid=$1 state=$2 token tmp
  token=$(fm_claude_session_token) || return 0
  tmp=$(mktemp "$state/.lock-session-write.XXXXXX" 2>/dev/null) || return 0
  { printf '%s\n%s\n' "$pid" "$token" > "$tmp"; } 2>/dev/null \
    && mv -f "$tmp" "$state/.lock.session" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session.
# When ancestry finds no match at all - including a daemon-hosted session whose
# hook subprocesses share no OS ancestry with the process that wrote the lock -
# fall back to the stable per-session token above, bound to the exact pid it was
# recorded against so a lock a different, later session has since taken can
# never be claimed by a stale token. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry, and a missing or mismatched token all
# fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid token side_pid side_token
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || pids=''
  if [ -n "$pids" ]; then
    while IFS= read -r pid; do
      [ "$pid" = "$lock_pid" ] && return 0
    done <<EOF
$pids
EOF
  fi
  token=$(fm_claude_session_token) || return 1
  [ -f "$state/.lock.session" ] && [ ! -L "$state/.lock.session" ] || return 1
  { IFS= read -r side_pid && IFS= read -r side_token; } < "$state/.lock.session" 2>/dev/null || return 1
  [ -n "$side_pid" ] && [ -n "$side_token" ] || return 1
  [ "$side_pid" = "$lock_pid" ] && [ "$side_token" = "$token" ]
}

# How long the session-identity sidecar may go unrefreshed before a live lock
# pid whose recorded session token no longer matches any hook is treated as a
# RECOVERABLE identity divergence rather than as a competing live session.
# Generous on purpose: a live session that is actually working refreshes this
# once per turn end (fm_session_lock_sidecar_sync below), so only a recorded
# owner that has proven nothing for this long can be downgraded.
FM_SESSION_LOCK_DIVERGENCE_GRACE_DEFAULT=1800

# Seconds since $1 was last modified, or a large number when it cannot be read.
# bin/fm-wake-lib.sh owns the general fm_path_age helper, but this library
# documents itself as side-effect-free on source and fm-wake-lib.sh creates the
# state root when sourced, so the two stat forms are repeated here rather than
# pulling that side effect into every consumer of this file.
_fm_session_lock_path_age() {  # <path>
  local m
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    m=$(/usr/bin/stat -f %m "$1" 2>/dev/null)
  else
    m=$(stat -c %Y "$1" 2>/dev/null)
  fi
  case "$m" in
    ''|*[!0-9]*) printf '%s\n' 999999; return 0 ;;
  esac
  printf '%s\n' "$(( $(date +%s) - m ))"
}

# Keep the session-identity sidecar valid for the LIFETIME of the session, not
# only for the instant bin/fm-lock.sh acquired the lock.
#
# CLAUDE_CODE_SESSION_ID can change under a session that is already running -
# moving a session into a daemon-hosted background job forks it with a new id -
# and the acquisition-time sidecar then names a session that no longer presents
# that token while the recorded lock pid is still alive. Both self-recognition
# branches fail at once, so the session can neither recognize nor re-take its
# own lock, and every Stop hook declines silently and permanently (the
# 2026-09-15 nine-hour supervision outage).
#
# Refreshing on every PROVEN ownership gives two properties:
#   1. the recorded token follows the live session id, so an id change while
#      ancestry still holds never strands the home; and
#   2. the sidecar's mtime becomes a liveness beacon for the lock-owning
#      SESSION rather than merely for its pid, which is what lets
#      fm_session_lock_identity_state tell a genuinely live competing session
#      (refreshed every turn end) from a diverged one (never refreshed again).
#
# Silent and best-effort, exactly like the writer it delegates to: a refresh
# failure must never fail the caller.
fm_session_lock_sidecar_sync() {  # <state-dir>
  local state=$1 lock_pid
  # The sidecar exists only for a stable Claude session token, so answer the
  # cheap question first and never pay for an ancestry walk on every turn end of
  # every other harness.
  fm_claude_session_token >/dev/null || return 0
  fm_session_lock_owned_by_self "$state" || return 0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  fm_session_lock_write_sidecar "$lock_pid" "$state"
}

# ONE owner of "may this process act as this home's session, and if not, why
# not?". Prints exactly one word:
#
#   self         this process runs inside the lock-owning session.
#   free         no lock file, or a malformed one: nothing to reconcile.
#   stale-owner  the recorded pid is not a live harness process.
#   diverged     the recorded pid IS a live harness process, but the sidecar
#                proves the lock was taken by a Claude session that has not
#                proven ownership for the divergence grace, while THIS process
#                is a Claude session carrying a different well-formed token.
#                That is the session-id-changed-under-a-running-session shape:
#                recoverable, because a session that is still running this
#                home's hooks refreshes the sidecar at every turn end.
#   competing    any other live owner: refuse, exactly as before.
#
# Every uncertainty classifies as competing, so the protection the identity
# gate exists for can never widen by accident.
fm_session_lock_identity_state() {  # <state-dir> [divergence-grace]
  local state=$1 grace=${2:-${FM_SESSION_LOCK_DIVERGENCE_GRACE:-$FM_SESSION_LOCK_DIVERGENCE_GRACE_DEFAULT}}
  local lock_pid token side_pid side_token
  case "$grace" in
    ''|*[!0-9]*) grace=$FM_SESSION_LOCK_DIVERGENCE_GRACE_DEFAULT ;;
  esac
  if fm_session_lock_owned_by_self "$state"; then
    printf 'self\n'
    return 0
  fi
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) printf 'free\n'; return 0 ;;
  esac
  if ! fm_harness_pid_alive "$lock_pid"; then
    printf 'stale-owner\n'
    return 0
  fi
  # A live recorded owner. Only the complete divergence signature may downgrade
  # it, and every missing piece of that signature keeps the refusal.
  token=$(fm_claude_session_token) || { printf 'competing\n'; return 0; }
  { [ -f "$state/.lock.session" ] && [ ! -L "$state/.lock.session" ]; } \
    || { printf 'competing\n'; return 0; }
  { IFS= read -r side_pid && IFS= read -r side_token; } < "$state/.lock.session" 2>/dev/null \
    || { printf 'competing\n'; return 0; }
  [ -n "$side_pid" ] && [ -n "$side_token" ] || { printf 'competing\n'; return 0; }
  # The sidecar must describe the CURRENT lock holder, and must name a session
  # other than this one - otherwise there is no divergence to recover from.
  [ "$side_pid" = "$lock_pid" ] || { printf 'competing\n'; return 0; }
  [ "$side_token" != "$token" ] || { printf 'competing\n'; return 0; }
  [ "$(_fm_session_lock_path_age "$state/.lock.session")" -ge "$grace" ] \
    || { printf 'competing\n'; return 0; }
  printf 'diverged\n'
}
