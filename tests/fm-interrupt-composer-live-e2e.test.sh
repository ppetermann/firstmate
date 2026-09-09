#!/usr/bin/env bash
# tests/fm-interrupt-composer-live-e2e.test.sh - the live post-interrupt
# composer guard (live-harness-optin family).
#
# bin/fm-control-lib.sh's interrupt tables are a per-harness claim about what
# the vendor's TUI does with a cancelled turn: which key cancels it, how many
# presses it takes, and - the claim this guard exists for - whether the harness
# RESTORES the cancelled prompt into its composer, which decides whether the
# interrupt must be followed by a composer clear. That claim is only readable
# from the real harness, so per .agents/skills/firstmate-coding-guidelines a
# stub cannot verify it: a fake pane can only confirm the table already written
# into the fake.
#
# What a wrong table costs is not theoretical. claude was recorded as needing
# no clear key until 2026-09-09, when a single Escape into a busy claude 2.1.266
# pane was measured restoring the cancelled prompt every time. The composer then
# held firstmate's own last submitted line, unsubmitted and invisible to every
# healthy-looking signal, so the next steer concatenated onto it and a doorbell
# rung into that pane went nowhere until a bare Enter was typed by hand.
#
# The prompt this guard cancels must WRAP the pane, and it asserts that it
# does. The first version of this guard cancelled a 123-character prompt in a
# 200-column pane - a single display row, which any kill-to-row-start key
# clears in one press - so it passed while the same interrupt kept stranding
# firstmate's own 200-plus-character doorbell in the composer. A prompt that
# does not wrap cannot exercise the shape that actually failed.
#
# For every INSTALLED verified harness this guard launches an idle pane in an
# isolated tmux server, starts a real turn, cancels it by running the REAL
# bin/fm-control.sh interrupt against it - never a copy of its key sequence -
# then requires the turn to actually stop and the composer to end proven
# `empty`. A harness whose composer still reads
# `pending` fails loudly with its name and version and needs a clear key added
# to that table.
#
# Run explicitly with FM_INTERRUPT_COMPOSER_LIVE=1. This spends a small number
# of real model tokens per installed harness (one cancelled turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_INTERRUPT_COMPOSER_LIVE_HARNESSES="claude muse ..." when needed, and tune
# the per-harness waits with FM_INTERRUPT_COMPOSER_LIVE_TIMEOUT (seconds,
# default 90). Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Post-interrupt composer").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_INTERRUPT_COMPOSER_LIVE tmux

unset NO_MISTAKES_GATE

SOCKET="fm-intcomp-live-$$"
SESSION="intcomplive"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-intcomp-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_INTERRUPT_COMPOSER_LIVE_TIMEOUT:-90}
PANE_COLS=200
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# The composer read reaches tmux through bare `tmux` calls, so a PATH shim pins
# it to the private socket.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-intcomp-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x "$PANE_COLS" -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# The same unattended-autonomy launch posture bin/fm-spawn.sh uses, so no
# interactive approval stands between the turn and its cancellation.
launch_cmd() {  # <name>
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex) printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox' ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# A prompt long enough that the turn is still running when the interrupt lands,
# answerable with no tool the harness might stop to ask about, and longer than
# the pane is wide so the restored copy occupies more than one display row.
LONG_PROMPT='Write a 4000 word essay about the history of terminal multiplexers, from teletype line disciplines through screen and tmux to the session managers in use today, directly in your reply. Use no tools, write no files, and ask nothing before you begin.'
[ "${#LONG_PROMPT}" -gt "$PANE_COLS" ] || {
  printf 'not ok - the cancelled prompt is %s characters in a %s-column pane, so it never wraps and this guard would pass without exercising a multi-row composer clear\n' \
    "${#LONG_PROMPT}" "$PANE_COLS" >&2
  exit 1
}

wait_composer_empty() {  # <window> <budget>
  local win=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_tmux_composer_state "$SESSION:$win")" = empty ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_busy() {  # <window> <budget>
  local win=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_pane_busy_state "$SESSION:$win")" = busy ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# The cancellation itself, read from the same busy signal that proved the turn
# started. Without this the guard could pass vacuously on a run where the
# interrupt key never landed: the turn simply keeps going and its composer is
# legitimately empty, which says nothing about what a cancelled turn leaves
# behind.
wait_not_busy() {  # <window> <budget>
  local win=$1 budget=$2 i=0
  while [ "$i" -lt "$budget" ]; do
    [ "$(fm_pane_busy_state "$SESSION:$win")" = busy ] || return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# The interrupt itself comes from the REAL control plane, not from a copy of
# its key sequence here: bin/fm-control.sh owns which keys go out, how many
# times, and the settle between them, and a guard that re-implemented any of
# that could only prove its own copy right.
deliver_interrupt() {  # <window> <harness>
  local win=$1 name=$2
  local home="$LAB/$name-home" task="live-$name" wt="$LAB/$name-wt"
  mkdir -p "$home/state" "$home/data/$task" "$wt"
  printf '# live interrupt guard\n' > "$home/data/$task/brief.md"
  {
    printf 'window=%s:%s\n' "$SESSION" "$win"
    printf 'endpoint_task_id=%s\n' "$task"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$ROOT"
    printf 'harness=%s\n' "$name"
    printf 'kind=ship\n'
  } > "$home/state/$task.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-control.sh" "$task" interrupt >"$LAB/$name.control.out" 2>&1
}

fail_harness() {  # <name> <version> <message>
  FAILED=1
  printf 'not ok - %s (%s): %s\n' "$1" "$2" "$3" >&2
}

check_harness_interrupt() {  # <name>
  # The window name must be the endpoint fm-control expects for this task id,
  # since the control plane refuses an endpoint it cannot bind to the task.
  local name=$1 version cmd win="fm-live-$1" state
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || { note "no launch recipe for $name"; return 0; }
  if ! tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- bash -lc "$cmd"; then
    fail_harness "$name" "$version" "could not launch in the isolated tmux server"
    return 0
  fi
  if ! wait_composer_empty "$win" 60; then
    fail_harness "$name" "$version" "never reached a proven-empty idle composer, so this check cannot start"
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" -l "$LONG_PROMPT"
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Enter
  if ! wait_busy "$win" 30; then
    fail_harness "$name" "$version" "the turn never started, so no cancellation was exercised"
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  # Let the turn get past its own first render before cancelling it.
  sleep 4
  if ! deliver_interrupt "$win" "$name"; then
    fail_harness "$name" "$version" "bin/fm-control.sh refused or failed to deliver this harness's interrupt: $(tr '\n' ' ' < "$LAB/$name.control.out")"
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  if ! wait_not_busy "$win" "$TIMEOUT"; then
    fail_harness "$name" "$version" \
      "the turn was still running ${TIMEOUT}s after its recorded interrupt sequence, so this run proves nothing about the composer a cancelled turn leaves behind"
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  if wait_composer_empty "$win" "$TIMEOUT"; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the composer is empty after its recorded interrupt sequence"
  else
    state=$(fm_tmux_composer_state "$SESSION:$win")
    fail_harness "$name" "$version" \
      "the composer reads '$state' after its recorded interrupt sequence; a restored prompt needs a clear key in fm_control_interrupt_clear_key, or the next submitted line will concatenate onto it"
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_INTERRUPT_COMPOSER_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_interrupt "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live post-interrupt composer guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live post-interrupt composer guard verified no harness; refusing to pass vacuously\n' >&2
  exit 1
fi
printf '# post-interrupt composer verified for %s harness(es)\n' "$CHECKED"
