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
# It also proves the other half of that contract for every adapter that
# declares a composer clear key (bin/fm-control-lib.sh): the key must actually
# be able to EMPTY a composer, including one holding a line long enough to wrap
# the pane. That is not the same question as "does the key work" - a kill key
# that clears back to the start of the current wrapped display row clears a
# short line in one press and leaves the leading rows of a long one behind, and
# firstmate's own steering doorbell always wraps because it embeds the absolute
# inbox path twice. When that went unmeasured, an interrupt reported success
# while leaving the doorbell sitting unsubmitted in the composer.
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

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_COMPOSER_DRIFT tmux

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
PANE_COLS=80           # the private session's width, below
# The exact bytes firstmate rings into every pane, built by its own owner
# (bin/fm-task-inbox-lib.sh) rather than transcribed here, so a change to the
# doorbell reaches this guard automatically.
CLEAR_PRESS_BUDGET=${FM_COMPOSER_DRIFT_CLEAR_PRESSES:-8}
SETTLE=${FM_COMPOSER_DRIFT_SETTLE:-60}   # deciseconds to wait for each verdict

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt" "$LAB/state/drift.inbox"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# The composer clear is exercised through the REAL dispatch and the REAL
# adapter table, never a copy of either: a guard that re-implemented the press
# loop could only prove its own copy right.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

printf 'schema=fm-task-inbox.v1\nat=drift\n--\nprobe\n' > "$LAB/state/drift.inbox/001.msg"
DOORBELL=$(fm_task_inbox_doorbell_line "$LAB/state/drift.inbox/001.msg") \
  || fail "could not build the real doorbell line for the composer-clear probe"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -x 80 -y 24 -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# shellcheck source=tests/harness-drift-helpers.sh
. "$ROOT/tests/harness-drift-helpers.sh"

wait_for_state() {  # <target> <wanted> -> 0 when reached
  local target=$1 wanted=$2 i=0
  while [ "$i" -lt "$SETTLE" ]; do
    [ "$(fm_tmux_composer_state "$target")" = "$wanted" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# The tmux-side screen read that the shared fm_drift_wait_for_drawn polls
# (tests/harness-drift-helpers.sh owns the drawn-screen policy itself).
fm_drift_capture() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" -S 0 -E - 2>/dev/null
}

composer_row() {  # <target> - the cursor row, for a failure message
  local target=$1 cy
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 0
  tmux capture-pane -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null | cat -v
}

CHECKED=0
SKIPPED=

# The verified adapters, owned by tests/harness-drift-helpers.sh so a newly
# verified adapter cannot be added to one live guard and left out of another.
for harness in "${FM_DRIFT_HARNESSES[@]}"; do
  if ! bin_path=$(fm_drift_resolve_harness_binary "$harness"); then
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
  fm_drift_wait_for_drawn "$target" "$SETTLE" || fail \
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

  # 4. For an adapter that declares a composer clear key, that key must be able
  #    to EMPTY the composer, including one holding a line that WRAPS. This is
  #    the shape that broke: a kill key clearing back to the start of the
  #    current wrapped display row leaves the leading rows of a long line
  #    behind, and firstmate's doorbell is always long. The clear runs through
  #    the shipped fm_backend_clear_composer, so the guard proves the code
  #    firstmate actually runs rather than a transcription of it.
  clear_key=$(fm_control_interrupt_clear_key "$harness" 2>/dev/null) || clear_key=
  if [ -n "$clear_key" ]; then
    [ "${#DOORBELL}" -gt "$PANE_COLS" ] || fail \
      "the composer-clear probe types ${#DOORBELL} characters into a ${PANE_COLS}-column pane, so it never wraps and would prove nothing; widen the probe or narrow the pane"
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$DOORBELL"
    wait_for_state "$target" pending || fail \
      "COMPOSER DRIFT: $harness $version reports '$(fm_tmux_composer_state "$target")' for a composer holding firstmate's own ${#DOORBELL}-character doorbell, so the clear probe below cannot mean anything. Cursor row: [$(composer_row "$target")]."
    presses=$(fm_backend_clear_composer tmux "$target" '' "$clear_key" 0.2 "$CLEAR_PRESS_BUDGET") \
      || fail \
      "COMPOSER CLEAR DRIFT: $harness $version still holds text after $presses x $clear_key, so an interrupt cannot leave its composer clean and the next submitted line would concatenate onto the leftovers. Cursor row: [$(composer_row "$target")]. Fix the adapter's clear key in bin/fm-control-lib.sh or raise the press budget in bin/fm-control.sh."
    wait_for_state "$target" empty || fail \
      "COMPOSER CLEAR DRIFT: $harness $version reports '$(fm_tmux_composer_state "$target")' after $presses x $clear_key emptied its composer. Cursor row: [$(composer_row "$target")]."
    note "$harness $version: a ${#DOORBELL}-character wrapped composer cleared in $presses x $clear_key"
  else
    note "$harness $version: no composer clear key is declared for this adapter, so none is exercised"
  fi

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
