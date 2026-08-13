#!/usr/bin/env bash
# Behavior tests for the claude launch-readiness trust gate in bin/fm-spawn.sh.
# The gate stops fm-spawn from reporting success for a claude worker parked on
# its first-run trust dialog. Readiness is the PRIMARY signal: the gate's real
# question is "did the agent start processing the brief?", answered for a
# crewmate or scout by the busy-state hook firing (claude's UserPromptSubmit
# advancing the seeded record). Trust-prompt recognition is only a secondary
# aid that clears a known blocker so processing can start; if a vendor rewording
# ever matches no detection fragment, the hook never fires and the gate FAILS
# LOUDLY rather than assuming success. These tests drive the gate through a fake
# tmux that models the dialog state machine against captured screen text (the
# fragments were captured from a real Claude Code launch, 2026-08-13).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-trust-gate)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_claude_gate() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_claude_gate EXIT

# Fake tmux that models claude's launch + trust-dialog state machine. The spawn
# drives it through send-keys (exports, treehouse get, the launch literal, and
# the gate's prompt-clearing Enter); capture-pane renders the screen for the
# current state. When the agent reaches "working" the fake advances the REAL
# busy-state record through fm-busy-event.sh, simulating claude's
# UserPromptSubmit hook firing after the directory is trusted. The clear-enter
# log records every Enter received while in the trust state so the gate's
# "at most one clear" contract is testable.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_CLAUDE_STATE" 2>/dev/null || true)

advance_busy() {
  [ -n "${FM_FAKE_FM_ROOT:-}" ] || return 0
  [ -n "${FM_FAKE_STATE_DIR:-}" ] || return 0
  [ -n "${FM_FAKE_TASK_ID:-}" ] || return 0
  "$FM_FAKE_FM_ROOT/bin/fm-busy-event.sh" apply \
    "$FM_FAKE_STATE_DIR" "$FM_FAKE_TASK_ID" busy \
    --current-gen --source claude-hook --event user-prompt-submit \
    >/dev/null 2>&1 || true
}

fake_screen() {
  case "$state" in
    trust)
      case "${FM_FAKE_CLAUDE_PROMPT_VARIANT:-full}" in
        choice-only)
          cat <<'SCR'

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
SCR
          ;;
        question-only)
          cat <<'SCR'

 Accessing workspace:

 Quick safety check: Is this a project you created or one you trust?

 Enter to confirm · Esc to cancel
SCR
          ;;
        *)
          cat <<'SCR'

 Accessing workspace:

 Quick safety check: Is this a project you created or one you trust?

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
SCR
          ;;
      esac
      ;;
    working)
      cat <<'SCR'

❯ Read the brief and follow it exactly.

● Working...

❯
SCR
      ;;
    unknown)
      # Version-drift stand-in: a screen the gate's detection fragments do NOT
      # recognize (none of the trust-question strings) and where the agent is
      # parked rather than processing. Models a future vendor rewording beyond
      # all current fragments, or any other unrecognized non-processing state.
      # The fake never advances the busy-state record from this state, so a
      # correctly-version-drift-safe gate must report FAILURE, never success.
      cat <<'SCR'

 ⚠ Before we begin
 Do you want to proceed in this directory?
   > Continue
     Cancel

 Press Return to continue
SCR
      ;;
    *)
      printf '$ \n'
      ;;
  esac
}

case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *dangerously-skip-permissions*)
          printf 'launch\n' > "$FM_FAKE_CLAUDE_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launch)
            case "${FM_FAKE_CLAUDE_OUTCOME:-trust}" in
              unknown)
                printf 'unknown\n' > "$FM_FAKE_CLAUDE_STATE"
                ;;
              *)
                if [ "${FM_FAKE_CLAUDE_TRUST:-yes}" = yes ]; then
                  printf 'trust\n' > "$FM_FAKE_CLAUDE_STATE"
                else
                  printf 'working\n' > "$FM_FAKE_CLAUDE_STATE"
                  advance_busy
                fi
                ;;
            esac
            ;;
          trust)
            printf '1\n' >> "$FM_FAKE_CLEAR_ENTER_LOG"
            if [ "${FM_FAKE_CLAUDE_CLEARABLE:-yes}" = yes ]; then
              printf 'working\n' > "$FM_FAKE_CLAUDE_STATE"
              advance_busy
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    fake_screen
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" claude
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for claude trust gate\n' > "$home/data/$id/brief.md"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/claude.state"
  : > "$case_dir/clear-enter.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_CLAUDE_TRUST_GATE=1 \
    FM_FAKE_CLAUDE_STATE="$case_dir/claude.state" \
    FM_FAKE_CLAUDE_TRUST="${FM_FAKE_CLAUDE_TRUST:-yes}" \
    FM_FAKE_CLAUDE_CLEARABLE="${FM_FAKE_CLAUDE_CLEARABLE:-yes}" \
    FM_FAKE_CLAUDE_OUTCOME="${FM_FAKE_CLAUDE_OUTCOME:-trust}" \
    FM_FAKE_CLEAR_ENTER_LOG="$case_dir/clear-enter.log" \
    FM_FAKE_FM_ROOT="$ROOT" \
    FM_FAKE_STATE_DIR="$(cd "$home/state" && pwd -P)" \
    FM_FAKE_TASK_ID="$id" \
    FM_CLAUDE_READY_POLLS="${FM_CLAUDE_READY_POLLS:-2}" FM_CLAUDE_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness claude --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# Read one field from the busy-state record file directly (format:
# "v1 gen=.. seq=.. state=.. source=.. event=.. ts=..").
busy_field() {
  local state_dir=$1 id=$2 field=$3
  sed -n "s/.* ${field}=\([^ ]*\).*/\1/p" "$state_dir/$id.busy-state" 2>/dev/null || true
}

clear_enter_count() {
  local log=$1
  if [ -f "$log" ]; then wc -l < "$log" | tr -d ' '; else printf '0\n'; fi
}

test_claude_trust_prompt_cleared_succeeds() {
  local id rec out rc src evt
  id=claude-clear-z1-$$
  rec=$(make_spawn_case clear "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=yes FM_FAKE_CLAUDE_CLEARABLE=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "claude spawn with a clearable trust dialog should succeed"
  assert_contains "$out" "spawned $id harness=claude" \
    "claude spawn did not report success after clearing the trust dialog"
  src=$(busy_field "$HOME_DIR/state" "$id" source)
  [ "$src" = "claude-hook" ] \
    || fail "claude busy-state source was not advanced to claude-hook (got '$src')"
  evt=$(busy_field "$HOME_DIR/state" "$id" event)
  [ "$evt" = "user-prompt-submit" ] \
    || fail "claude busy-state event was not user-prompt-submit (got '$evt')"
  [ "$(clear_enter_count "$CASE_DIR/clear-enter.log")" = "1" ] \
    || fail "gate should send exactly one clearing Enter, got $(clear_enter_count "$CASE_DIR/clear-enter.log")"
  pass "fm-spawn: claude trust dialog is detected, cleared with one Enter, and processing confirmed"
}

test_claude_no_prompt_fast_path_succeeds() {
  local id rec out rc src
  id=claude-noprompt-z2-$$
  rec=$(make_spawn_case noprompt "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "claude spawn with no trust dialog should succeed"
  assert_contains "$out" "spawned $id harness=claude" \
    "claude fast-path spawn did not report success"
  src=$(busy_field "$HOME_DIR/state" "$id" source)
  [ "$src" = "claude-hook" ] \
    || fail "claude fast-path busy source was not advanced to claude-hook (got '$src')"
  [ "$(clear_enter_count "$CASE_DIR/clear-enter.log")" = "0" ] \
    || fail "fast path with no prompt should send zero clearing Enters"
  pass "fm-spawn: claude fast path with no trust dialog confirms processing with no clear Enter"
}

test_claude_unclearable_prompt_fails_loudly() {
  local id rec out rc
  id=claude-stuck-z3-$$
  rec=$(make_spawn_case stuck "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=yes FM_FAKE_CLAUDE_CLEARABLE=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "claude spawn with an unclearable trust dialog should fail"
  assert_contains "$out" "trust dialog is showing and could not be cleared" \
    "unclearable trust dialog failure lacked its loud diagnostic"
  assert_not_contains "$out" "spawned $id harness=claude" \
    "unclearable trust dialog spawn reported success"
  assert_grep 'failed:' "$HOME_DIR/state/$id.status" \
    "unclearable trust dialog did not leave a supervisor-visible failure"
  [ "$(clear_enter_count "$CASE_DIR/clear-enter.log")" = "1" ] \
    || fail "gate should attempt exactly one clear over a stuck dialog, got $(clear_enter_count "$CASE_DIR/clear-enter.log")"
  pass "fm-spawn: claude spawn with an unclearable trust dialog fails loudly without teardown"
}

test_claude_trust_detection_reads_multiple_independent_signals() {
  # The trust dialog is a rendered surface; the gate reads more than one
  # independent fragment so no single vendor string is load-bearing. Drive the
  # spawn with a fake that renders the CHOICE line only (no question text) and
  # then with one that renders the QUESTION only (no choice text). Both must be
  # detected and cleared.
  local id rec out rc
  id=claude-signal-folder-z4-$$
  rec=$(make_spawn_case signal-folder "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=yes FM_FAKE_CLAUDE_CLEARABLE=yes \
    FM_FAKE_CLAUDE_PROMPT_VARIANT=choice-only run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "claude gate should detect the dialog from the choice line alone"
  assert_contains "$out" "spawned $id harness=claude" \
    "claude gate failed to clear a dialog detected from the choice fragment"

  id=claude-signal-question-z5-$$
  rec=$(make_spawn_case signal-question "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=yes FM_FAKE_CLAUDE_CLEARABLE=yes \
    FM_FAKE_CLAUDE_PROMPT_VARIANT=question-only run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "claude gate should detect the dialog from the question line alone"
  assert_contains "$out" "spawned $id harness=claude" \
    "claude gate failed to clear a dialog detected from the question fragment"
  pass "fm-spawn: claude trust detection survives losing either independent rendered fragment"
}

test_claude_gate_never_hammers_a_stuck_dialog() {
  # Even with a generous poll budget, the gate sends exactly one clearing Enter
  # over a stuck trust dialog (the enter_sent latch), then keeps polling until
  # the timeout. Hammering would generate multiple clear-enter log entries.
  local id rec out rc
  id=claude-nohammer-z6-$$
  rec=$(make_spawn_case nohammer "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_TRUST=yes FM_FAKE_CLAUDE_CLEARABLE=no \
    FM_CLAUDE_READY_POLLS=6 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "unclearable dialog should still fail with more polls"
  [ "$(clear_enter_count "$CASE_DIR/clear-enter.log")" = "1" ] \
    || fail "gate hammered a stuck dialog: $(clear_enter_count "$CASE_DIR/clear-enter.log") clear Enters over 6 polls (expected 1)"
  pass "fm-spawn: claude gate sends one clearing Enter over a stuck dialog regardless of poll budget"
}

test_claude_unrecognized_nonprocessing_screen_fails() {
  # Version-drift protection (the brief's core safety property): if the pane
  # shows a screen the gate's fragments do NOT recognize as the trust dialog AND
  # the agent never starts processing (the busy-state hook never fires), the
  # spawn must FAIL rather than report success. This is exactly the case a
  # vendor rewording beyond every detection fragment must hit - readiness, not
  # prompt recognition, decides. The fake's "unknown" screen shares no fragment
  # with the detector and never advances the busy record.
  local id rec out rc
  id=claude-drift-z7-$$
  rec=$(make_spawn_case drift "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_CLAUDE_OUTCOME=unknown run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "claude spawn with an unrecognized non-processing screen should fail (version drift)"
  assert_contains "$out" "did not confirm brief processing within the readiness window" \
    "unrecognized-screen failure lacked its loud diagnostic"
  assert_not_contains "$out" "spawned $id harness=claude" \
    "unrecognized non-processing screen reported success"
  assert_grep 'failed:' "$HOME_DIR/state/$id.status" \
    "unrecognized-screen spawn did not leave a supervisor-visible failure"
  [ "$(clear_enter_count "$CASE_DIR/clear-enter.log")" = "0" ] \
    || fail "gate should send no clearing Enter for a screen it does not recognize as the trust dialog, got $(clear_enter_count "$CASE_DIR/clear-enter.log")"
  pass "fm-spawn: claude spawn with an unrecognized non-processing screen fails loudly (version-drift safe)"
}

test_claude_trust_prompt_cleared_succeeds
test_claude_no_prompt_fast_path_succeeds
test_claude_unclearable_prompt_fails_loudly
test_claude_trust_detection_reads_multiple_independent_signals
test_claude_gate_never_hammers_a_stuck_dialog
test_claude_unrecognized_nonprocessing_screen_fails
