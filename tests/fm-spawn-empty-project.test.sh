#!/usr/bin/env bash
# Regression tests for fm-spawn's no-commits refusal: a project whose HEAD is
# unborn can yield no task worktree, so the spawn must say that instead of
# waiting on a worktree that can never appear.
#
# Firstmate's create path makes a local project with `git init`. Until that
# repository holds a commit its HEAD is unborn, so `git worktree add` has nothing to check out and no
# isolation backend can cut a task worktree from it. `treehouse get` is sent to
# the pane as text and its failure is printed there, where fm-spawn never looks,
# so before this precondition existed the pane simply stayed in the project, the
# settle poll ran its full 60-second window, and the refusal named the worktree
# symptom ("it is the spawning project itself") and nothing about the cause.
#
# These tests drive the real spawn path with a fake terminal and assert the
# refusal is immediate, names the actual cause, and never reaches the isolation
# tool - while a project that merely has no remote still launches normally,
# because "no origin" is a legitimate local-only posture and not this defect.
# A project that is no git working tree at all is refused further up, where the
# shared Treehouse project lock cannot be resolved for it, so it is not a case
# here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-empty-project)

# make_logging_fakebin <dir> builds the spawn fakebin with a treehouse that
# records every invocation instead of silently exiting 0. Reaching treehouse at
# all proves the spawn got as far as driving the pane, which is exactly what a
# project that can never yield a worktree must not cost.
make_logging_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  fm_fakebin_write "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home and a fakebin; the caller then creates
# whatever project shape it is testing at PROJ_DIR.
HOME_DIR=; PROJ_DIR=; FAKEBIN_DIR=; TREEHOUSE_LOG=
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  TREEHOUSE_LOG="$case_dir/treehouse-calls"
  FAKEBIN_DIR=$(make_logging_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise the empty-project precondition for $id."
}

run_spawn() {  # <id> <pane-path>
  local id=$1 pane=$2
  FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --mode direct-PR --yolo off
}

# The reported defect: a freshly created local project with no commits at all.
test_project_with_no_commits_is_refused_by_cause() {
  local id out status
  id=empty-no-commits-z1
  make_case empty-no-commits "$id"
  mkdir -p "$PROJ_DIR"
  git -C "$PROJ_DIR" init -q

  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker into a project with no commits"$'\n'"$out"
  assert_contains "$out" "has no commits" \
    "the refusal did not name the unborn HEAD as the cause"
  assert_contains "$out" "$PROJ_DIR" "the refusal did not name the project"
  assert_contains "$out" "empty root commit" \
    "the refusal did not say what would make the project usable"
  assert_not_contains "$out" "did not enter an isolated worktree" \
    "the spawn still reported the worktree symptom instead of the cause"
  [ ! -s "$TREEHOUSE_LOG" ] || fail "spawn drove the isolation tool for a project that can yield no worktree"$'\n'"$(cat "$TREEHOUSE_LOG")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a project with no commits is refused immediately, naming the unborn HEAD"
}

# The control, and the state the create path must leave behind: one root commit
# and no remote whatsoever. A local-only project is allowed to have no origin,
# so this must launch - the precondition screens for an unusable repository, not
# for a missing remote.
test_project_with_a_root_commit_and_no_remote_launches() {
  local id out status wt
  id=empty-root-commit-z3
  make_case empty-root-commit "$id"
  wt="$TMP_ROOT/empty-root-commit/slot"
  mkdir -p "$PROJ_DIR"
  git -C "$PROJ_DIR" init -q
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'Initialize repository'
  git -C "$PROJ_DIR" worktree add --quiet --detach "$wt"

  out=$(run_spawn "$id" "$wt")
  status=$?
  expect_code 0 "$status" "spawn should launch from a local-only project with a root commit and no remote"$'\n'"$out"
  assert_grep "worktree=$wt" "$HOME_DIR/state/$id.meta" \
    "meta did not record the isolated worktree"
  pass "an empty root commit and no remote is enough to launch the first worker"
}

test_project_with_no_commits_is_refused_by_cause
test_project_with_a_root_commit_and_no_remote_launches

echo "# all fm-spawn-empty-project tests passed"
