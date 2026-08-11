#!/usr/bin/env bash
# tests/fm-composer-pane-shapes.test.sh - portable regression for the composer
# classifier (bin/fm-composer-lib.sh + bin/fm-tmux-lib.sh) over the composer
# SHAPES real harnesses draw.
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`), each
# painting one exact composer shape with real escape sequences and parking the
# cursor with a real CUP sequence, so the classifier reads a real terminal
# screen. It needs no harness and no credentials, so it runs everywhere CI runs
# tmux. The live per-harness counterpart is
# tests/fm-composer-drift-live-e2e.test.sh.
#
# The defect it exists for: delivery verification asks the composer "did my text
# clear?", and two shapes made that question unanswerable while looking answered.
#   1. A bare prompt glyph padded with U+00A0 (claude 2.1.226). No shell trim and
#      no [[:space:]] class treats a no-break space as whitespace, so an EMPTY
#      composer classified `pending` exactly like one holding text. fm-send
#      reported "delivery unconfirmed" for messages that had landed, and the
#      away-mode injector's confirmed-empty guard deferred every escalation.
#   2. A LEFT-RAIL composer with no right border and no corner rows (opencode
#      1.18.4 and 1.18.15). No complete box exists to find and the cursor row
#      carries a composer edge, so every read returned `unknown` - which proves
#      neither delivery nor a swallow.
# Both shapes are asserted in BOTH directions: an empty composer must be `empty`
# and the same shape holding text must be `pending`, and the cases assert that
# divergence directly so they cannot go quietly vacuous if one signal is lost.
# The dead-shell cases are the counterweight: the fix must not buy emptiness by
# weakening the rule that a bare shell prompt is never a safe injection target.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-composer-shapes-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-shapes.XXXXXX")
SESSION=shapes

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so bin/fm-tmux-lib.sh's bare `tmux` calls reach the
# private socket and never touch the host's real sessions.
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

# paint: run a REAL process in a REAL pane that writes <body> (printf escapes),
# parks the cursor on <cursor-row> (1-based, matching the CUP sequence), and
# blocks. The pane is never killed between reads, so every classification below
# reads a live terminal screen rather than a captured fixture. Each shape needs
# its own <name>: tmux refuses an ambiguous window name, and this runs inside a
# command substitution, so a shared counter would not survive the subshell.
paint() {  # <name> <body-printf> <cursor-row> -> window target
  local name=$1 body=$2 cursor_row=$3 script screen
  script="$LAB/$name.sh"
  screen="$LAB/$name.screen"
  # shellcheck disable=SC2059 # the shape IS the format string, by construction
  printf "$body" > "$screen"
  cat > "$script" <<SH
#!/usr/bin/env bash
printf '\033[2J\033[H'
cat "$screen"
printf '\033[$cursor_row;3H'
exec sleep 900
SH
  chmod +x "$script"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$name" -c "$LAB/wt" -- "$script" \
    || fail "could not paint shape $name"
  # Wait for the paint AND the cursor park to reach the screen before
  # classifying it. The body and the CUP sequence are separate writes, so waiting
  # on ink alone can capture a fully drawn screen whose cursor still sits on the
  # row below the shape - the verdict would then be taken against the wrong row.
  local i=0
  while [ "$i" -lt 100 ]; do
    if [ -n "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$name" -S 0 -E - | tr -d '[:space:]')" ] \
       && [ "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:$name" '#{cursor_y}')" = "$((cursor_row - 1))" ]; then
      break
    fi
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s' "$SESSION:$name"
}

# The exact bytes each shape is built from, so the intent stays readable.
NBSP='\302\240'                 # U+00A0, claude's composer padding
RULE='\342\224\200'             # U+2500, claude's full-width composer rules
RAIL='\342\224\203'             # U+2503, opencode's heavy left rail
GLYPH='\342\235\257'            # U+276F, the claude agent prompt glyph
# The rounded corners and light side an older bordered composer draws.
BOX_TL='\342\225\255'           # U+256D
BOX_TR='\342\225\256'           # U+256E
BOX_BL='\342\225\260'           # U+2570
BOX_BR='\342\225\257'           # U+256F
BOX_V='\342\224\202'            # U+2502
BOX_H=$RULE
rule_row() { local i=0 out=''; while [ "$i" -lt 40 ]; do out="$out$RULE"; i=$((i + 1)); done; printf '%s' "$out"; }
RULES=$(rule_row)

# --- 1. claude's bare NBSP-padded prompt row ---------------------------------

test_nbsp_padded_prompt_row() {
  local empty_target text_target empty_state text_state
  empty_target=$(paint nbsp-empty "$RULES\\n$GLYPH$NBSP\\n$RULES\\n" 2)
  text_target=$(paint nbsp-text "$RULES\\n$GLYPH${NBSP}half typed steer\\n$RULES\\n" 2)
  empty_state=$(fm_tmux_composer_state "$empty_target")
  text_state=$(fm_tmux_composer_state "$text_target")
  [ "$empty_state" = empty ] \
    || fail "a prompt glyph padded with U+00A0 is an EMPTY composer, got '$empty_state'"
  [ "$text_state" = pending ] \
    || fail "the same padded row holding text is unsubmitted input, got '$text_state'"
  [ "$empty_state" != "$text_state" ] \
    || fail "empty and text-holding NBSP composers collapsed to one verdict '$empty_state'"
  pass "composer shape: an NBSP-padded prompt row separates empty from pending"
}

# The padding must not be able to hide real input either: a composer whose only
# content is a no-break space is empty, but one holding a real glyph is not,
# however the harness spaces it.
test_nbsp_only_content_is_blank_not_text() {
  local blank_target glyphy_target blank_state glyphy_state
  blank_target=$(paint nbsp-blank "$RULES\\n$GLYPH$NBSP$NBSP$NBSP\\n$RULES\\n" 2)
  glyphy_target=$(paint nbsp-glyph "$RULES\\n$GLYPH$NBSP.$NBSP\\n$RULES\\n" 2)
  blank_state=$(fm_tmux_composer_state "$blank_target")
  glyphy_state=$(fm_tmux_composer_state "$glyphy_target")
  [ "$blank_state" = empty ] || fail "a run of no-break spaces is padding, got '$blank_state'"
  [ "$glyphy_state" = pending ] \
    || fail "a visible character between no-break spaces is real input, got '$glyphy_state'"
  pass "composer shape: no-break padding is blank while a visible glyph stays input"
}

# --- 2. opencode's left-rail composer ----------------------------------------

# The rail's last row is the harness's own model/mode status line, which is why
# the reader stops at the cursor row instead of scanning the whole rail.
test_left_rail_composer() {
  local empty_target text_target empty_state text_state
  empty_target=$(paint rail-empty "  $RAIL\\n  $RAIL\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  text_target=$(paint rail-text "  $RAIL\\n  $RAIL  half typed steer\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  empty_state=$(fm_tmux_composer_state "$empty_target")
  text_state=$(fm_tmux_composer_state "$text_target")
  [ "$empty_state" = empty ] \
    || fail "an empty left-rail composer is empty, got '$empty_state'"
  [ "$text_state" = pending ] \
    || fail "a left-rail composer holding text is unsubmitted input, got '$text_state'"
  [ "$empty_state" != "$text_state" ] \
    || fail "empty and text-holding rail composers collapsed to one verdict '$empty_state'"
  pass "composer shape: a left-rail composer separates empty from pending"
}

# The rail bar is a three-byte glyph, so the row reader must strip it as a
# CHARACTER and not as one byte. Under LC_CTYPE=C/POSIX - what an unset LANG
# gives under systemd, cron, ssh and minimal containers - a one-byte strip leaves
# the bar's tail bytes behind as content, and an EMPTY rail composer reads
# `pending` exactly like one holding a steer. That is the same false negative
# this file exists for, so the divergence is asserted away from the ambient
# UTF-8 locale too. The classification runs in a fresh shell with the locale
# exported, reading the same live panes through the same public entry point.
CLASSIFY="$LAB/classify.sh"
cat > "$CLASSIFY" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-tmux-lib.sh"
fm_tmux_composer_state "\$1"
SH
chmod +x "$CLASSIFY"

classify_in_locale() {  # <locale> <target> -> state
  LC_ALL=$1 LANG=$1 LC_CTYPE=$1 "$CLASSIFY" "$2"
}

test_left_rail_composer_in_non_utf8_locale() {
  local empty_target text_target loc empty_state text_state
  empty_target=$(paint rail-empty-c "  $RAIL\\n  $RAIL\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  text_target=$(paint rail-text-c "  $RAIL\\n  $RAIL  half typed steer\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  for loc in C POSIX; do
    empty_state=$(classify_in_locale "$loc" "$empty_target")
    text_state=$(classify_in_locale "$loc" "$text_target")
    [ "$empty_state" = empty ] \
      || fail "under LC_ALL=$loc an empty left-rail composer is still empty, got '$empty_state'"
    [ "$text_state" = pending ] \
      || fail "under LC_ALL=$loc a left-rail composer holding text is still unsubmitted input, got '$text_state'"
    [ "$empty_state" != "$text_state" ] \
      || fail "under LC_ALL=$loc empty and text-holding rail composers collapsed to one verdict '$empty_state'"
  done
  pass "composer shape: a left-rail composer separates empty from pending in a non-UTF-8 locale"
}

# Text on an earlier rail row still counts, because the reader covers every row
# from the rail top through the cursor.
test_left_rail_reads_rows_above_the_cursor() {
  local target state
  target=$(paint rail-above "  $RAIL  first line still typed\\n  $RAIL\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 3)
  state=$(fm_tmux_composer_state "$target")
  [ "$state" = pending ] \
    || fail "unsubmitted text above the cursor in a rail composer must be pending, got '$state'"
  pass "composer shape: a left rail is read from its top through the cursor row"
}

# --- 3. the safety counterweights --------------------------------------------

# A dead shell is the failure the shared classifier exists to prevent: its
# prompt must never read as an injectable empty agent composer.
test_dead_shell_prompt_stays_unknown() {
  local dollar_target gt_target dollar_state gt_state
  dollar_target=$(paint shell-dollar 'user@host:~$ ' 1)
  gt_target=$(paint shell-gt '> ' 1)
  dollar_state=$(fm_tmux_composer_state "$dollar_target")
  gt_state=$(fm_tmux_composer_state "$gt_target")
  [ "$dollar_state" != empty ] \
    || fail "a bare shell prompt must never classify as an empty agent composer"
  [ "$gt_state" != empty ] \
    || fail "a bare '>' prompt must never classify as an empty agent composer"
  pass "composer shape: dead-shell prompts stay unsafe for injection"
}

# A bordered box the scan cannot bound fails CLOSED as `unknown`, and the rail
# reader must not reopen it: `empty` is the single verdict that both confirms
# delivery to fm-send and authorizes the away-mode daemon to type into a pane.
# Box structure adjacent to a run of aligned bars - a corner row above or below,
# or a paired side row - is positive evidence of a clipped BOX, and opencode's
# genuine rail draws none of the three, so those bars must not become a rail.
# Every shape below reads `unknown` on the pre-rail libs; each is a verdict
# inversion if the guard misses its direction. The boundary is checked against
# the RUN, not against the cursor row, so extra unpaired side rows between the
# cursor and the box structure cannot walk a shape out of the guard.
test_unbounded_box_stays_unknown() {
  local top bottom wide_top wide_bottom state depth body
  top="$BOX_TL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_TR"
  bottom="$BOX_BL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_BR"
  wide_top="$BOX_TL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_TR"
  wide_bottom="$BOX_BL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_BR"
  # (c) side rows capped ABOVE by a top corner.
  state=$(fm_tmux_composer_state "$(paint clipped-box "$top\\n$BOX_V\\n$BOX_V\\n" 3)")
  [ "$state" = unknown ] \
    || fail "a top-corner-capped box with unpaired side rows must fail closed as unknown, got '$state'"
  # (a) side rows bounded BELOW by a matching bottom corner, at increasing depth
  # between the cursor row and that corner.
  body="$BOX_V\\n$BOX_V\\n"
  for depth in 2 3 4; do
    state=$(fm_tmux_composer_state "$(paint "clipped-box-below-$depth" "$body$bottom\\n" 2)")
    [ "$state" = unknown ] \
      || fail "$depth side rows above a bottom corner must fail closed as unknown, got '$state'"
    body="$body$BOX_V\\n"
  done
  # (b) unpaired side rows INSIDE a complete box, above a paired content row.
  state=$(fm_tmux_composer_state "$(paint clipped-box-paired-below \
    "$BOX_V\\n$BOX_V\\n$BOX_V > hi   $BOX_V\\n$wide_bottom\\n" 1)")
  [ "$state" = unknown ] \
    || fail "side rows above a paired content row must fail closed as unknown, got '$state'"
  # (b') the same, with the paired content row ABOVE the unpaired run.
  state=$(fm_tmux_composer_state "$(paint clipped-box-inner \
    "$wide_top\\n$BOX_V > hi   $BOX_V\\n$BOX_V\\n$BOX_V\\n$wide_bottom\\n" 4)")
  [ "$state" = unknown ] \
    || fail "unpaired side rows inside a complete box must fail closed as unknown, got '$state'"
  pass "composer shape: a bordered box the scan cannot bound fails closed as unknown, whatever the run's depth"
}

# OpenCode draws its idle composer placeholder in truecolor 38;2;128;128;128 -
# luminance EXACTLY 128, the documented ghost bound - against 38;2;238;238;238
# for real typed input. The bound is inclusive for precisely this reason: at an
# exclusive `<` the placeholder survives ghost-stripping and an idle composer
# reads `pending`, which is the "delivery unconfirmed" false negative this file
# exists for. The pair is asserted in both directions so it cannot go vacuous.
test_rail_placeholder_at_the_luminance_bound() {
  local ghost_target real_target ghost_state real_state
  ghost_target=$(paint rail-ghost \
    "  $RAIL\\n  $RAIL  \\033[38;2;128;128;128mAsk anything...\\033[0m\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  real_target=$(paint rail-real \
    "  $RAIL\\n  $RAIL  \\033[38;2;238;238;238mreal typed steer\\033[0m\\n  $RAIL\\n  $RAIL  Build \302\267 model-name\\n" 2)
  ghost_state=$(fm_tmux_composer_state "$ghost_target")
  real_state=$(fm_tmux_composer_state "$real_target")
  [ "$ghost_state" = empty ] \
    || fail "a placeholder at luminance exactly 128 is ghost text, so the composer is empty, got '$ghost_state'"
  [ "$real_state" = pending ] \
    || fail "real input at luminance 238 is unsubmitted text, got '$real_state'"
  [ "$ghost_state" != "$real_state" ] \
    || fail "the idle placeholder and real input collapsed to one verdict '$ghost_state'"
  pass "composer shape: a rail placeholder at the inclusive luminance bound stays apart from real input"
}

# A single bar-led row is ordinary output (a pipe, a table), not a rail. Only an
# aligned repeat of the same BOX-DRAWING bar proves a drawn container. Both
# shapes are painted BLANK on purpose: a bar row carrying text reads non-empty
# for the trivial reason that it holds text, so it would keep passing with the
# rule it pins deleted. Each shape is asserted at the verdict its own rule
# produces, because the two rules fail differently when removed: dropping the
# minimum-two-rows rule turns the lone bar into a one-row rail and it reads
# `empty`, while admitting ASCII `|` makes these rows a rail whose bar is not a
# strippable edge, so the row reads `pending`. Asserting only `!= empty` would
# let the ASCII half pass with its rule gone.
test_single_bar_row_is_not_a_rail() {
  local target state ascii_target ascii_state
  target=$(paint lone-bar "some output\\n  $RAIL\\nmore output\\n" 2)
  state=$(fm_tmux_composer_state "$target")
  [ "$state" != empty ] \
    || fail "a lone bar-led row must not classify as an empty composer"
  ascii_target=$(paint ascii-pipe "|\\n|\\n|\\n" 2)
  ascii_state=$(fm_tmux_composer_state "$ascii_target")
  [ "$ascii_state" = unknown ] \
    || fail "ASCII bar rows are not a composer rail, so they stay unreadable, got '$ascii_state'"
  pass "composer shape: an unaligned or ASCII bar row is not a composer rail"
}

# The complete-box reader must keep working, including when the box is padded
# with the same no-break spaces.
test_complete_box_still_classifies() {
  local empty_target text_target nbsp_target empty_state text_state nbsp_state top bottom
  top="$BOX_TL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_TR"
  bottom="$BOX_BL$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_H$BOX_BR"
  empty_target=$(paint box-empty "$top\\n$BOX_V >      $BOX_V\\n$bottom\\n" 2)
  text_target=$(paint box-text "$top\\n$BOX_V > fix  $BOX_V\\n$bottom\\n" 2)
  nbsp_target=$(paint box-nbsp "$top\\n$BOX_V >$NBSP$NBSP$NBSP$NBSP$NBSP $BOX_V\\n$bottom\\n" 2)
  empty_state=$(fm_tmux_composer_state "$empty_target")
  text_state=$(fm_tmux_composer_state "$text_target")
  nbsp_state=$(fm_tmux_composer_state "$nbsp_target")
  [ "$empty_state" = empty ] || fail "an empty bordered composer is empty, got '$empty_state'"
  [ "$text_state" = pending ] || fail "a bordered composer holding text is pending, got '$text_state'"
  [ "$nbsp_state" = empty ] \
    || fail "no-break padding inside a bordered composer must not make its geometry unreadable, got '$nbsp_state'"
  pass "composer shape: complete boxes still classify, including no-break padding"
}

test_nbsp_padded_prompt_row
test_nbsp_only_content_is_blank_not_text
test_left_rail_composer
test_left_rail_composer_in_non_utf8_locale
test_left_rail_reads_rows_above_the_cursor
test_dead_shell_prompt_stays_unknown
test_unbounded_box_stays_unknown
test_rail_placeholder_at_the_luminance_bound
test_single_bar_row_is_not_a_rail
test_complete_box_still_classifies

cleanup_all
trap - EXIT
