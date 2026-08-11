#!/usr/bin/env bash
# tests/fm-herdr-composer-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness still lets the HERDR composer reader
# (fm_backend_herdr_composer_state in bin/backends/herdr.sh) separate an EMPTY
# composer from one holding unsubmitted text, and that the two structural
# signals that reader depends on are still the ones the harness actually draws.
#
# Why this file exists alongside tests/fm-composer-drift-live-e2e.test.sh: that
# guard drives the TMUX reader, and the tmux reader finds the composer from
# tmux's own cursor row. herdr's CLI exposes no cursor primitive, so its reader
# locates the composer STRUCTURALLY, and it is that structural scan - not the
# shared content classifier - that broke. claude draws a rule-delimited composer
# (rule / `❯` / rule); while both rules are plain `─` runs they form a complete
# separator pair around the composer row, but once the pane is wide enough claude
# inlines the in-progress todo into the TOP rule, leaving claude's own CLOSING
# rule unmatched below its own live composer. That retired the composer as
# `unknown`, and the away-mode injector requires an affirmative `empty`, so every
# escalation deferred to the max-defer wedge alarm (captain's pane, claude
# 2.1.226 on herdr 0.8.0, 107 columns). The tmux guard cannot see any of this.
#
# The reader now keeps that verdict when BOTH the closing rule is the composer
# row's IMMEDIATE successor AND herdr's native `agent get` names a known non-Pi
# agent. Those are the two facts this guard pins against vendor drift: a release
# that inserts a row between the composer and its closing rule, or that stops
# being detected as an agent, silently reinstates the overnight wedge. It pins
# them on exactly the condition the reader consults them on and never a broader
# one - only when the plain-separator pair is INCOMPLETE - because a guard that
# aborts claiming the wedge is back, for a pane it has already affirmed as
# `empty`, teaches the fleet to discount the next real alarm.
#
# It also pins the premise that identity half rests on: an EXITED agent must
# LOSE its native record, or a pane whose agent is gone could still keep a
# verdict. That is checked against a real harness exit for every harness whose
# quit command is measured (see harness_exit_command); a harness without one is
# skipped with a note, so an unguarded harness is stated rather than assumed.
#
# Each harness is launched bare, with no prompt, and driven only with keystrokes,
# so this consumes no model tokens. The launch uses whatever credentials the
# harness already has.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart is the
# `composer_state_claude_labelled_top_rule_*` family in
# tests/fm-backend-herdr.test.sh, which pins the same logic in CI with a real
# herdr-CLI stub and no harness. Run this guard after any harness or herdr
# upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
#
# Pane width caveat, recorded because it bounds what a pass here proves: a
# headless lab session has no attached client, so its panes are fixed at the
# default grid (54 columns, measured on herdr 0.8.0) and claude renders the
# in-progress todo as separate rows above the top rule rather than inlining it.
# This guard therefore verifies the composer verdicts and the structural
# invariants the fix rests on; it cannot itself re-draw the wide-pane label, and
# so it does NOT fail against the pre-fix reader. What fails pre-fix is the
# portable family above and Scenario E of tests/fm-afk-inject-herdr-e2e.test.sh;
# this guard's job is to catch the vendor drift that would make the fix stop
# applying, which neither of those can see.
set -u

if [ "${FM_COMPOSER_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_DRIFT=1 to run the installed-harness herdr composer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

# shellcheck source=tests/harness-drift-helpers.sh
. "$ROOT/tests/harness-drift-helpers.sh"

SESSION="fm-lab-hcomposer-$$"
CHECKED=0
SKIPPED=
GAPPED=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
}
trap cleanup_all EXIT

fm_herdr_lab_prepare "$SESSION" || fail "could not prepare an isolated Herdr lab session"
export HERDR_SESSION="$SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 | tr -d '\r' | awk '{ print $NF }')
[ -n "$HERDR_VERSION" ] || HERDR_VERSION=unknown
SETTLE=${FM_COMPOSER_DRIFT_SETTLE:-60}   # half-second polls per verdict
PROBE=fmdrift

# Harnesses whose composer the HERDR reader cannot parse at all today, so this
# guard would report a standing gap as fresh drift on every run and never go
# green. A listed harness is still launched and still read: the gap must still
# be there, and a listed harness that starts reading correctly FAILS this guard
# asking for its entry to be removed, so the list cannot quietly outlive the
# gap it documents. The list is EMPTY today - every installed harness is held to
# the full contract below - and `FM_HERDR_COMPOSER_KNOWN_GAPS` sets it (a
# space-separated harness list) when a vendor release breaks a shape and the
# reader has not caught up yet.
HERDR_COMPOSER_KNOWN_GAPS=${FM_HERDR_COMPOSER_KNOWN_GAPS:-}

is_known_gap() {  # <harness>
  case " $HERDR_COMPOSER_KNOWN_GAPS " in *" $1 "*) return 0 ;; esac
  return 1
}

wait_shell_settled() {  # <pane>
  local pane=$1 i=0 n=0
  while [ "$i" -lt 100 ]; do
    if fm_backend_herdr_cli "$SESSION" pane process-info --pane "$pane" 2>/dev/null | jq -e '
      .result.process_info as $p
      | ($p.foreground_processes | length == 1)
        and ($p.foreground_processes[0].pid == $p.shell_pid)' >/dev/null 2>&1; then
      n=$((n + 1))
      [ "$n" -ge 8 ] && return 0
    else
      n=0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The single bounded-poll idiom every live read in this guard waits through:
# <polls> attempts half a second apart of a predicate that succeeds once the
# state the caller wants has arrived. Everything herdr reports here is either
# rendered or event-driven, so one immediate read of a live value can catch a
# transient; keeping ONE waiting idiom is what stops a newly added check being
# the one that samples once and aborts a whole run on it.
wait_until() {  # <polls> <predicate> [args...]
  local polls=$1 i=0
  shift
  while [ "$i" -lt "$polls" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

composer_state_is() {  # <target> <wanted>
  [ "$(fm_backend_herdr_composer_state "$1")" = "$2" ]
}

wait_for_state() {  # <target> <wanted>
  wait_until "$SETTLE" composer_state_is "$1" "$2"
}

# The herdr-side screen read that the shared fm_drift_wait_for_drawn polls
# (tests/harness-drift-helpers.sh owns the drawn-screen policy itself).
fm_drift_capture() {  # <target>
  fm_backend_herdr_capture "$1" 40 2>/dev/null
}

# The row numbers (1-based, within the captured window) of the bottom-most agent
# prompt-glyph row and the bottom-most plain `─` rule row, plus how many plain
# rule rows that window holds, as the reader's own structural scan sees them.
# Printed as "<glyph_row> <rule_row> <rule_count>", 0 for absent.
#
# This reuses the classifier's OWN predicates (_fm_composer_pi_separator_row,
# fm_composer_normalize_trim_var, and fm_composer_leading_agent_glyph_var) over
# the reader's own capture rather than restating them: a guard with its own idea
# of what counts as a rule would take the "not rule-delimited" branch below -
# skipping both structural assertions while still reporting green - against a
# harness the reader still treats as rule-delimited. The shared normalize-trim
# absorbs the trailing carriage return herdr ends each captured row with,
# exactly as the classifier's own scan does before testing the same predicate.
#
# The glyph row deliberately tracks the BARE shape ONLY, even though the
# classifier's scan also recognizes bordered rows: the rescue this guard pins
# applies only to the bare agent-glyph row (bin/fm-composer-lib.sh gates it on
# `FM_COMPOSER_SELECTED_KIND = bare`), and asserting adjacency about a bordered
# row the classifier never routes through that branch would hold a harness to an
# invariant it does not have. The two are one decision, so a change to either
# shape gate must move both together.
composer_frame_rows() {  # <target>
  # shellcheck disable=SC2034 # `lead` is an out-varname set by name inside
  # fm_composer_leading_agent_glyph_var; only its return status is read here.
  local target=$1 cap line plain row=0 glyph=0 rule=0 rules=0 lead
  cap=$(fm_backend_herdr_capture_ansi "$target" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null) || cap=
  while IFS= read -r line; do
    row=$((row + 1))
    plain=$(printf '%s\n' "$line" | fm_composer_strip_ansi)
    fm_composer_normalize_trim_var plain
    if _fm_composer_pi_separator_row "$plain"; then
      rule=$row
      rules=$((rules + 1))
      continue
    fi
    [ -n "$plain" ] || continue
    if fm_composer_leading_agent_glyph_var lead "$plain"; then
      glyph=$row
    fi
  done < <(printf '%s\n' "$cap")
  printf '%d %d %d\n' "$glyph" "$rule" "$rules"
}

native_agent() {  # <pane>
  fm_backend_herdr_cli "$SESSION" agent get "$1" 2>/dev/null \
    | jq -r '.result.agent.agent // ""' 2>/dev/null
}

native_agent_absent() {  # <pane>
  [ -z "$(native_agent "$1")" ]
}

native_agent_present() {  # <pane>
  [ -n "$(native_agent "$1")" ]
}

composer_view() {  # <target> - a few rows of context for a failure message
  fm_backend_herdr_capture "$target" 6 2>/dev/null | cat -v | tr '\n' '|'
}

# The text that makes a harness quit from an idle composer, for the harnesses
# whose non-interactive exit has been MEASURED. The rescue's whole safety
# argument is that an exited agent loses its native record, so that premise is
# worth exercising against a real exit rather than against a pane that never
# hosted an agent - but only where the exit is known, because an unrecognized
# command typed into a live composer would be submitted as a PROMPT, and this
# guard promises to consume no model tokens. A harness absent from this table
# is skipped with a note rather than silently.
#   claude - `/exit` quits from an idle composer (measured, claude 2.1.226 on
#     herdr 0.8.0: the pane returned to its shell, `agent get` reported no agent
#     within 0.05s of that, and the composer read `unknown`).
harness_exit_command() {  # <harness>
  case "$1" in
    claude) printf '%s\n' /exit ;;
    *) return 1 ;;
  esac
}

# Every quit command above is slash-prefixed, and a `/`- or `$`-prefixed send
# opens a completion popup within ~0.1s that can consume the first Enter
# (bin/backends/herdr.sh fm_backend_herdr_send_text_submit, docs/herdr-backend.md
# "Composer and injection safety"). This is NOT repairing an observed failure:
# measured against claude 2.1.226 on herdr 0.8.0 in an isolated lab, BOTH the
# atomic `pane run` path and this sequence quit claude cleanly, each settling
# the pane back to its shell, dropping the native agent record and leaving the
# composer reading `unknown`. It follows the adapter's own popup-safe order
# anyway - type once with send_literal, hold the shared 1.2s slash settle
# bin/fm-send.sh uses, then retry ENTER ALONE, never retyping - because the
# popup hazard is a real class risk this repo already owns everywhere else, one
# settle is cheap, and a swallowed Enter here would abort the whole guard with a
# drift alarm against a harness release that is fine.
FM_HERDR_EXIT_SLASH_SETTLE=${FM_HERDR_EXIT_SLASH_SETTLE:-1.2}
FM_HERDR_EXIT_ENTER_RETRIES=${FM_HERDR_EXIT_ENTER_RETRIES:-3}
# How long every read of the native agent record below waits for the value it
# expects, whether that is the record APPEARING for a running harness or being
# DROPPED after one exits. Also NOT repairing an observed failure: measured
# against claude 2.1.226 on herdr 0.8.0 in an isolated lab across THREE
# consecutive runs, the record was already absent at the FIRST sample, taken
# 0.05s after the pane's shell settled back to the foreground, so no clearing
# lag was observed at all. herdr's agent state is event-driven
# (`pane.agent_status_changed`) rather than derived on demand, so a bounded poll
# is what keeps a slower or loaded machine from reading one transient and
# aborting the run with a drift or safety-premise alarm against a harness
# release that is fine. It costs nothing when the record already reads the way
# the caller expects, which is what was measured.
FM_HERDR_AGENT_RECORD_POLLS=${FM_HERDR_AGENT_RECORD_POLLS:-20}

send_exit_command() {  # <target> <pane> <text> -> 0 once the pane is back at its shell
  local target=$1 pane=$2 text=$3 i=0
  fm_backend_herdr_send_literal "$target" "$text" || return 1
  sleep "$FM_HERDR_EXIT_SLASH_SETTLE"
  while [ "$i" -lt "$FM_HERDR_EXIT_ENTER_RETRIES" ]; do
    fm_backend_herdr_send_key "$target" Enter || return 1
    wait_shell_settled "$pane" && return 0
    i=$((i + 1))
  done
  return 1
}

# --- dead-shell control ------------------------------------------------------
# The counterweight to every `empty` below: a pane running nothing but a login
# shell must stay `unknown`, or the reader has bought its emptiness by weakening
# the rule that stops an escalation being typed into (and executed by) a shell
# whose agent has exited. Asserted live, in the same session, before any harness
# is launched.
SHELL_IDS=$(fm_backend_herdr_container_ensure "$ROOT") \
  || fail "dead-shell control: container_ensure failed"
SHELL_TASK=$(fm_backend_herdr_create_task "${SHELL_IDS%%$'\t'*}" fm-drift-shell "$ROOT" "${SHELL_IDS#*$'\t'}") \
  || fail "dead-shell control: could not create a plain shell pane"
read -r _SHELL_TAB SHELL_PANE <<EOF
$SHELL_TASK
EOF
wait_shell_settled "$SHELL_PANE" || fail "dead-shell control: the plain shell pane never settled"
SHELL_VERDICT=$(fm_backend_herdr_composer_state "$SESSION:$SHELL_PANE")
[ "$SHELL_VERDICT" = unknown ] || fail \
  "DEAD-SHELL REFUSAL LOST: a herdr pane running only a login shell reads '$SHELL_VERDICT', not unknown. Away-mode injection proceeds on an affirmative empty, so this would type an escalation into a shell. Screen tail: [$(composer_view "$SESSION:$SHELL_PANE")]."
SHELL_AGENT=$(native_agent "$SHELL_PANE")
[ -z "$SHELL_AGENT" ] || fail \
  "dead-shell control: herdr reports native agent '$SHELL_AGENT' for a plain shell pane, so native identity no longer separates a live agent from a dead one"
note "dead-shell control: a plain shell pane reads 'unknown' with no native agent record"
pass "herdr composer drift: a plain shell pane in a herdr session is refused as a composer"
fm_backend_herdr_kill "$SESSION:$SHELL_PANE" >/dev/null 2>&1 || true

# The verified adapters, owned by tests/harness-drift-helpers.sh so a newly
# verified adapter cannot be added to one live guard and left out of another.
for harness in "${FM_DRIFT_HARNESSES[@]}"; do
  if ! bin_path=$(fm_drift_resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its herdr composer shape is unverified here"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # Re-resolved per harness: each probe pane is closed when its harness is done,
  # which can retire the container it lived in, and a stale container id would
  # fail the NEXT harness for a reason that has nothing to do with its composer.
  CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$ROOT") \
    || fail "$harness ($version): container_ensure failed"
  CONTAINER=${CONTAINER_RAW%%$'\t'*}
  SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
  TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-drift-$harness" "$ROOT" "$SEEDED_TAB_ID") \
    || fail "$harness ($version): could not create an isolated lab pane"
  read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
  [ -n "$PANE_ID" ] || fail "$harness ($version): create_task returned no pane id"
  target="$SESSION:$PANE_ID"

  wait_shell_settled "$PANE_ID" \
    || fail "$harness ($version): the lab pane's shell never settled, so nothing launched here would mean anything"
  fm_backend_herdr_send_text_line "$target" "$bin_path" \
    || fail "$harness ($version): could not launch the harness in the lab pane"

  # 0. The TUI must actually be on screen before any verdict counts.
  fm_drift_wait_for_drawn "$target" "$SETTLE" || fail \
    "$harness ($version) on herdr $HERDR_VERSION: the pane never drew a TUI, so no composer verdict here would mean anything"

  if is_known_gap "$harness"; then
    if wait_for_state "$target" empty; then
      fail "$harness $version on herdr $HERDR_VERSION now presents a readable EMPTY composer, so its entry in HERDR_COMPOSER_KNOWN_GAPS is stale. Remove it from that list and let this guard hold the harness to the full contract."
    fi
    note "known gap: $harness $version on herdr $HERDR_VERSION still reads '$(fm_backend_herdr_composer_state "$target")' (see HERDR_COMPOSER_KNOWN_GAPS above); away-mode delivery to this harness on herdr is unverified"
    GAPPED="$GAPPED $harness"
    fm_backend_herdr_kill "$target" >/dev/null 2>&1 || true
    continue
  fi

  # 1. An idle harness must present an affirmatively EMPTY composer. Without it
  #    no submit can be confirmed and the away-mode injector defers every
  #    escalation until the max-defer alarm.
  wait_for_state "$target" empty || fail \
    "HERDR COMPOSER DRIFT: $harness $version on herdr $HERDR_VERSION never presented a readable EMPTY composer (last verdict '$(fm_backend_herdr_composer_state "$target")'). Away-mode escalations will defer until the max-defer alarm. Screen tail: [$(composer_view "$target")]. If this is a first-run trust or onboarding prompt, complete it once for this directory and re-run. Otherwise teach fm_backend_herdr_composer_state the shape this release actually draws."

  # 2. The structural invariants the rule-delimited rescue rests on, asserted on
  #    exactly the condition the reader consults them on and never a broader
  #    one. fm_backend_herdr_composer_state reaches for adjacency and native
  #    identity only when the plain-separator pair is INCOMPLETE (its elif is
  #    gated on FM_BACKEND_HERDR_PI_PAIR_FOUND -eq 0, which is 0 exactly when
  #    fewer than two plain rule rows are on screen). A COMPLETE pair keeps the
  #    verdict with no rescue at all, so a harness drawing one must not be held
  #    to the adjacency rule: step 1 above has already affirmed this very pane
  #    as `empty`, and aborting here would claim the away-mode wedge is back for
  #    a release just proven free of it. The skip is reported rather than
  #    silent, so a green run still states what it did and did not verify.
  read -r glyph_row rule_row rule_count <<EOF
$(composer_frame_rows "$target")
EOF
  wait_until "$FM_HERDR_AGENT_RECORD_POLLS" native_agent_present "$PANE_ID" || true
  agent_name=$(native_agent "$PANE_ID")
  if [ "${glyph_row:-0}" -gt 0 ] && [ "${rule_row:-0}" -gt "${glyph_row:-0}" ]; then
    if [ "${rule_count:-0}" -ge 2 ]; then
      note "$harness $version: rule-delimited composer, but the ${rule_count} plain rule rows on screen form a COMPLETE separator pair, so the reader keeps this verdict without the adjacency/native-identity rescue; those two invariants are NOT asserted for this harness in this pane (glyph row $glyph_row, bottom rule row $rule_row, native identity '${agent_name:-<none>}')"
    else
      [ "$rule_row" -eq "$((glyph_row + 1))" ] || fail \
        "HERDR COMPOSER DRIFT: $harness $version on herdr $HERDR_VERSION now draws $((rule_row - glyph_row - 1)) row(s) between its composer row and its unmatched closing rule. The reader only keeps a composer whose unmatched closing rule is that row's IMMEDIATE successor, so this release reinstates the away-mode wedge (every escalation reads 'unknown' and defers). Screen tail: [$(composer_view "$target")]."
      [ -n "$agent_name" ] && [ "$agent_name" != pi ] || fail \
        "HERDR COMPOSER DRIFT: $harness $version on herdr $HERDR_VERSION draws a composer closed by an UNMATCHED rule but herdr's native agent record reports '${agent_name:-<none>}'. The reader needs a known non-Pi native identity to keep that composer's verdict once the top rule stops being a plain rule, so this release reinstates the away-mode wedge."
      note "$harness $version: rule-delimited composer with an unmatched closing rule, closing rule adjacent, native identity '$agent_name'"
    fi
  else
    note "$harness $version: composer is not rule-delimited in this pane (glyph row ${glyph_row:-0}, bottom rule row ${rule_row:-0}, plain rule rows ${rule_count:-0}); native identity '${agent_name:-<none>}'"
  fi

  # 3. The SAME composer holding unsubmitted text must read pending. A classifier
  #    answering `empty` here would report a swallowed Enter as delivered and let
  #    the injector type over real input.
  fm_backend_herdr_send_literal "$target" "$PROBE" \
    || fail "$harness ($version): could not type the probe text into the composer"
  wait_for_state "$target" pending || fail \
    "HERDR COMPOSER DRIFT: $harness $version on herdr $HERDR_VERSION reports '$(fm_backend_herdr_composer_state "$target")' for a composer holding the literal text '$PROBE'. A swallowed Enter would be reported as delivered. Screen tail: [$(composer_view "$target")]."

  # 4. Removing that text must return the composer to empty, so both verdicts are
  #    proven to track the composer's CONTENTS rather than its startup state.
  # herdr names this key `backspace` and REFUSES tmux's `BSpace` with
  # invalid_key (verified against herdr 0.8.0), so a silently ignored keystroke
  # would leave the probe text in place and read as drift that is not there.
  i=0
  while [ "$i" -lt ${#PROBE} ]; do
    fm_backend_herdr_send_key "$target" backspace \
      || fail "$harness ($version) on herdr $HERDR_VERSION: herdr refused the 'backspace' key, so this guard cannot empty the composer it just filled"
    i=$((i + 1))
  done
  wait_for_state "$target" empty || fail \
    "HERDR COMPOSER DRIFT: $harness $version on herdr $HERDR_VERSION still reports '$(fm_backend_herdr_composer_state "$target")' after its composer was emptied again, so the empty verdict does not track composer contents. Screen tail: [$(composer_view "$target")]."

  # 5. The exited-agent control: the premise the identity half of the rescue
  #    rests on. A harness that has EXITED must lose its native record, or a
  #    pane whose agent is gone could still present a rule-delimited frame the
  #    reader would keep - which is the one way this rescue could type an
  #    escalation into whatever now owns the pane. The dead-shell control above
  #    proves a pane that NEVER hosted an agent has no record; only a real exit
  #    proves herdr drops the record it once had.
  if exit_cmd=$(harness_exit_command "$harness"); then
    wait_until "$FM_HERDR_AGENT_RECORD_POLLS" native_agent_present "$PANE_ID" || fail \
      "$harness ($version) on herdr $HERDR_VERSION: herdr reports no native agent for a RUNNING harness pane, so the exited-agent control below would prove nothing and the identity half of the rescue has no signal to lose"
    agent_live=$(native_agent "$PANE_ID")
    send_exit_command "$target" "$PANE_ID" "$exit_cmd" || fail \
      "$harness ($version) on herdr $HERDR_VERSION: the pane never returned to its shell after '$exit_cmd' was typed and Enter was retried $FM_HERDR_EXIT_ENTER_RETRIES times, so this release's exit path no longer matches the one harness_exit_command records; teach it the command this release actually quits on. Screen tail: [$(composer_view "$target")]."
    wait_until "$FM_HERDR_AGENT_RECORD_POLLS" native_agent_absent "$PANE_ID" || fail \
      "EXITED-AGENT PREMISE BROKEN: $harness $version on herdr $HERDR_VERSION still reports native agent '$(native_agent "$PANE_ID")' for a pane whose harness has EXITED. The rule-delimited rescue keeps a composer's verdict on that record, so a retained record lets an escalation be typed into whatever now owns the pane. Screen tail: [$(composer_view "$target")]."
    wait_for_state "$target" unknown || fail \
      "EXITED-AGENT PREMISE BROKEN: $harness $version on herdr $HERDR_VERSION reads '$(fm_backend_herdr_composer_state "$target")' for a pane whose harness has EXITED, not unknown. Away-mode injection proceeds on an affirmative empty, so this would type an escalation into whatever now owns the pane. Screen tail: [$(composer_view "$target")]."
    note "exited-agent control: $harness $version lost its native agent record on exit (was '$agent_live') and its pane reads 'unknown'"
  else
    note "skip: no measured non-interactive exit for $harness $version, so the exited-agent premise is unguarded for this harness here (add it to harness_exit_command once its quit command is measured)"
  fi

  pass "herdr composer drift: $harness $version on herdr $HERDR_VERSION separates an empty composer from unsubmitted text and keeps its structural frame"
  CHECKED=$((CHECKED + 1))
  fm_backend_herdr_kill "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
if [ -n "$GAPPED" ]; then
  note "standing herdr composer gaps, launched and confirmed still broken:$GAPPED"
fi
note "checked $CHECKED installed harness(es) against herdr $HERDR_VERSION"

cleanup_all
trap - EXIT
