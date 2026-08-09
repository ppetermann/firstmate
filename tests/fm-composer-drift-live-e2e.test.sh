#!/usr/bin/env bash
# tests/fm-composer-drift-live-e2e.test.sh - opt-in drift guard proving every
# INSTALLED harness still lets the composer classifier separate an EMPTY
# composer from one holding unsubmitted text (bin/fm-composer-lib.sh and
# bin/fm-tmux-lib.sh).
#
# Why this file exists: delivery confirmation is "did my text clear the
# composer?", and the composer is a rendered surface the harness vendor changes
# without notice. Claude Code began padding its bare prompt row with a no-break
# space, so an empty composer became indistinguishable from one holding text and
# fm-send reported "delivery unconfirmed" for steers that had landed; OpenCode's
# left-rail composer was never a shape the reader could parse at all. Neither
# regression is visible to a stubbed agent or to a table of shapes transcribed
# from a previous release - only a real harness drawing a real composer shows it.
#
# Each harness is launched bare, with no prompt, and driven only with
# keystrokes, so this consumes no model tokens. The launch uses whatever
# credentials the harness already has.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart in
# tests/fm-composer-pane-shapes.test.sh pins the shapes in CI. Run this guard
# after any harness upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
set -u

if [ "${FM_COMPOSER_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_DRIFT=1 to run the installed-harness composer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-composer-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-drift.XXXXXX")
SESSION=drift
PROBE=fmdrift          # typed marker; every character is removed again below
SETTLE=${FM_COMPOSER_DRIFT_SETTLE:-60}   # deciseconds to wait for each verdict

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 80 -y 24 -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

wait_for_state() {  # <target> <wanted> -> 0 when reached
  local target=$1 wanted=$2 i=0
  while [ "$i" -lt "$SETTLE" ]; do
    [ "$(fm_tmux_composer_state "$target")" = "$wanted" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# A pane that has not drawn its TUI yet is mostly blank, and a blank cursor row
# legitimately classifies as an empty composer. Waiting for a drawn screen
# BEFORE the first verdict is what stops this guard from passing vacuously
# against a harness that never finished starting.
wait_for_drawn() {  # <target>
  local target=$1 i=0 rows
  while [ "$i" -lt "$SETTLE" ]; do
    rows=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S 0 -E - 2>/dev/null \
      | grep -c '[^[:space:]]' || true)
    if [ "${rows:-0}" -ge 3 ]; then
      sleep 2   # let the first full frame settle before reading a verdict
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

composer_row() {  # <target> - the cursor row, for a failure message
  local target=$1 cy
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 0
  tmux capture-pane -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null | cat -v
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its composer shape is unverified here"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # Launched in the firstmate checkout, not a fresh temp directory: several
  # harnesses gate their first run in an unknown directory behind a trust or
  # onboarding prompt, and that prompt covers the composer this guard has to
  # read. The checkout is a directory this operator's harnesses already work in,
  # and a bare launch there sends no prompt and writes nothing.
  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$ROOT" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the composer probe"

  # 0. The TUI must actually be on screen before any verdict counts.
  wait_for_drawn "$target" || fail \
    "$harness ($version): the pane never drew a TUI, so no composer verdict here would mean anything"

  # 1. An idle harness must present an affirmatively EMPTY composer. Without
  #    this, no submit can ever be confirmed and the away-mode injector defers
  #    every escalation.
  wait_for_state "$target" empty || fail \
    "COMPOSER DRIFT: $harness $version never presented a readable EMPTY composer (last verdict '$(fm_tmux_composer_state "$target")'). Delivery can never be confirmed for this harness and away-mode escalations will defer until the max-defer alarm. Cursor row: [$(composer_row "$target")]. If this is a first-run trust or onboarding prompt, complete it once for this directory and re-run. Otherwise teach bin/fm-composer-lib.sh or bin/fm-tmux-lib.sh the composer shape this release actually draws."

  # 2. The SAME composer holding unsubmitted text must read pending. A classifier
  #    that answers `empty` here would report a swallowed Enter as delivered.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$PROBE"
  wait_for_state "$target" pending || fail \
    "COMPOSER DRIFT: $harness $version reports '$(fm_tmux_composer_state "$target")' for a composer holding the literal text '$PROBE'. A swallowed Enter would be reported as delivered and the away-mode injector would type over real input. Cursor row: [$(composer_row "$target")]."

  # 3. Removing that text must return the composer to empty, so the two verdicts
  #    are proven to track the composer's contents rather than its startup state.
  i=0
  while [ "$i" -lt ${#PROBE} ]; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" BSpace
    i=$((i + 1))
  done
  wait_for_state "$target" empty || fail \
    "COMPOSER DRIFT: $harness $version still reports '$(fm_tmux_composer_state "$target")' after its composer was emptied again, so the empty verdict does not track composer contents. Cursor row: [$(composer_row "$target")]."

  note "$harness $version: empty/pending/empty all observed"
  pass "composer drift: $harness $version separates an empty composer from unsubmitted text"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
