#!/usr/bin/env bash
# tests/fm-control-relaunch-fleet.test.sh - this fleet's own fm-control.sh
# relaunch cases: relaunching away from grok or kimi retires their global
# turn-end hooks, the shared empty-token guard and a zero-byte prior token
# never wedge a relaunch, and an empty or unfilled brief is refused before the
# agent stops. They live beside upstream's tests/fm-control-relaunch.test.sh so
# a take-in never re-resolves them inside it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch-fleet)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

# The fixture helpers below are copies of upstream's suite's, except that
# run_control and run_spawn honor FM_TEST_USER_HOME for a case whose subject
# reads HOME itself.
relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      case "$payload" in
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  # A case whose subject reads HOME itself - the kimi hook lives under
  # $HOME/.kimi-code - names the home it wants through FM_TEST_USER_HOME rather
  # than exporting HOME, which this env line would otherwise override.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="${FM_TEST_USER_HOME:-$dir/user-home}" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  # FM_TEST_USER_HOME is the opt-in for a case whose subject reads HOME itself.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="${FM_TEST_USER_HOME:-$dir/user-home}" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

# Relaunching away from grok or kimi revokes the last registry entry through
# the same retirement path teardown uses, so the global hook files do not leak
# forever in the operator's harness home (fm-orphan-global-turnend-hooks
# follow-up: the relaunch path never ran the retirement check).
test_relaunch_away_retires_the_prior_harness_global_hooks() {
  local harness dir out rc config_dir
  for harness in grok kimi; do
    dir=$(new_case "retire-$harness" "rl-retire-$harness")
    add_ship_task "$dir" "rl-retire-$harness" "$harness"
    printf 'codex' > "$dir/fake/becomes"
    if [ "$harness" = grok ]; then
      mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/grokhome/hooks/fm-turn-end.sh"
      printf '{"hooks":{"Stop":[]}}\n' > "$dir/grokhome/hooks/fm-turn-end.json"
      printf '%s\n' "$dir/home/state/rl-retire-grok.turn-ended" \
        > "$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
      printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl-retire-grok.grok-turnend-token"
      printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
    else
      config_dir="$dir/home/.kimi-code"
      mkdir -p "$config_dir"
      printf '# Kimi test config\ndefault_model = "test"\n' > "$config_dir/config.toml"
      HOME="$dir/home" "$ROOT/bin/fm-kimi-turnend-hook.sh" install \
        || fail "kimi hook install failed during setup"
      printf '%s\n' "$dir/home/state/rl-retire-kimi.turn-ended" \
        > "$config_dir/fm-turn-end.d/fm.ghijklghijkl"
      printf 'fm.ghijklghijkl\n' > "$dir/home/state/rl-retire-kimi.kimi-turnend-token"
      printf 'token=fm.ghijklghijkl\n' > "$dir/wt/.fm-kimi-turnend"
    fi

    out=$(FM_TEST_USER_HOME="$dir/home" run_control "$dir" "rl-retire-$harness" relaunch \
      --harness codex --note "switching away"); rc=$?
    expect_code 0 "$rc" "relaunch away from $harness should succeed"$'\n'"$out"

    if [ "$harness" = grok ]; then
      assert_absent "$dir/grokhome/hooks/fm-turn-end.sh" \
        "grok hook script survived a relaunch away from grok"
      assert_absent "$dir/grokhome/hooks/fm-turn-end.json" \
        "grok hook json survived a relaunch away from grok"
      assert_absent "$dir/grokhome/hooks/fm-turn-end.d" \
        "grok registry survived a relaunch away from grok"
    else
      config_dir="$dir/home/.kimi-code"
      assert_absent "$config_dir/fm-turn-end.sh" \
        "kimi hook script survived a relaunch away from kimi"
      assert_absent "$config_dir/fm-turn-end.d" \
        "kimi registry survived a relaunch away from kimi"
      ! grep -q 'BEGIN FIRSTMATE KIMI TURN-END HOOK' "$config_dir/config.toml" \
        || fail "kimi config region survived a relaunch away from kimi"
    fi
  done
  pass "fm-control relaunch: relaunching away retires the prior harness's global hooks"
}

# fm_control_harness_turnend_token_read is the one owner of the empty-token guard
# shared by teardown's grok and kimi retirement and spawn's relaunch-wiring
# cleanup. Pin its contract directly: absent token, a non-token-gated harness,
# zero-byte token (the crash-window fix), populated token, and the present but
# unreadable non-empty token that must still fail closed, plus the empty-args
# case that propagates the path lookup's nonzero so a caller's `|| return 1`
# fires identically to the former inline sites.
test_turnend_token_read_owns_the_empty_token_guard() {
  local dir state token rc harness
  dir=$(fm_test_tmproot fm-turnend-token-read)
  state="$dir/state"
  mkdir -p "$state"
  token=$(fm_control_harness_turnend_token_read grok "$state" absent) \
    || fail "absent grok token should succeed, got nonzero"
  [ -z "$token" ] || fail "absent token should read empty, got '$token'"
  token=$(fm_control_harness_turnend_token_read claude "$state" x) \
    || fail "a non-token-gated harness should succeed"
  [ -z "$token" ] || fail "a non-token-gated harness should read empty, got '$token'"

  for harness in grok kimi; do
    : > "$state/tk.$harness-turnend-token"
    token=$(fm_control_harness_turnend_token_read "$harness" "$state" tk) \
      || fail "zero-byte $harness token should succeed (the crash-window fix)"
    [ -z "$token" ] || fail "zero-byte $harness token should read empty, got '$token'"

    printf 'fm.deadbeefdead\n' > "$state/tk.$harness-turnend-token"
    token=$(fm_control_harness_turnend_token_read "$harness" "$state" tk) \
      || fail "populated $harness token should succeed"
    [ "$token" = "fm.deadbeefdead" ] \
      || fail "populated $harness token mismatch, got '$token'"

    printf 'fm.unreachable\n' > "$state/tk.$harness-turnend-token"
    chmod 000 "$state/tk.$harness-turnend-token"
    if [ -r "$state/tk.$harness-turnend-token" ]; then
      chmod 600 "$state/tk.$harness-turnend-token"
      echo "skip: file modes do not deny reads here (running privileged); cannot stage an unreadable $harness token"
      continue
    fi
    # The read runs in-process (the function is sourced), so redirect stderr to
    # keep the "Permission denied" diagnostic out of the test's own stderr.
    fm_control_harness_turnend_token_read "$harness" "$state" tk >/dev/null 2>&1
    rc=$?
    chmod 600 "$state/tk.$harness-turnend-token"
    expect_code 1 "$rc" "unreadable $harness token must fail closed, got $rc"
  done

  # An empty state or id propagates the path lookup's nonzero; capture the return
  # directly (this file runs under set -u, not set -e, so no errexit toggling).
  fm_control_harness_turnend_token_read grok "" x >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "empty state must propagate the path lookup failure"
  pass "fm-control-lib: fm_control_harness_turnend_token_read owns the empty-token guard for every call site"
}

# The empty-token guard's third call site is clear_relaunch_harness_wiring in
# bin/fm-spawn.sh (the relaunch-wiring cleanup), alongside teardown's grok and
# kimi retirement. A zero-byte token file is the crash-window case the relaunch
# cleanup must tolerate rather than wedge on, exactly as teardown does; the
# per-task wiring is still retired because that path cleanup is independent of
# the token read.
test_empty_prior_turnend_token_does_not_wedge_relaunch() {
  local harness dir id rc out
  for harness in grok kimi; do
    id="et-$harness"
    dir=$(new_case "emptytok-$harness" "$id")
    add_ship_task "$dir" "$id" "$harness"
    printf 'zsh' > "$dir/fake/command"
    : > "$dir/home/state/$id.$harness-turnend-token"
    printf 'token=fm.emptyempty\n' > "$dir/wt/.fm-$harness-turnend"
    out=$(run_spawn "$dir" "$id" --relaunch --harness claude 2>&1); rc=$?
    expect_code 0 "$rc" "relaunch with a zero-byte $harness token should succeed, not wedge"$'\n'"$out"
    [ ! -e "$dir/home/state/$id.$harness-turnend-token" ] \
      || fail "relaunch must still retire an empty $harness token's state file"
    [ ! -e "$dir/wt/.fm-$harness-turnend" ] \
      || fail "relaunch must still retire an empty $harness token's worktree pointer"
  done
  pass "fm-spawn --relaunch: a zero-byte prior turn-end token does not wedge the wiring cleanup"
}

# Checked BEFORE record_note appends the progress note (data/fm-spawn-empty-prompt/report.md
# episode 2: a relaunch of an already-broken task carried the same missing task
# text forward, because the appended note alone would have made the file look
# non-empty).
test_empty_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case emptybrief rl12)
  add_ship_task "$dir" rl12 claude
  : > "$dir/home/data/rl12/brief.md"
  out=$(run_control "$dir" rl12 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "empty instructions should refuse"
  assert_contains "$out" "no real content" "the refusal should name the empty instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: a byte-empty brief is never carried into a relaunch"
}

test_placeholder_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case placeholderbrief rl13)
  add_ship_task "$dir" rl13 claude
  printf '# brief\n\n{TASK}\n' > "$dir/home/data/rl13/brief.md"
  out=$(run_control "$dir" rl13 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an unreplaced {TASK} placeholder should refuse"
  assert_contains "$out" "no real content" "the refusal should name the placeholder instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: an unfilled {TASK} placeholder is never carried into a relaunch"
}

test_turnend_token_read_owns_the_empty_token_guard
test_empty_prior_turnend_token_does_not_wedge_relaunch
test_relaunch_away_retires_the_prior_harness_global_hooks
test_empty_instructions_refuse_before_stopping_anything
test_placeholder_instructions_refuse_before_stopping_anything
