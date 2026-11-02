#!/usr/bin/env bash
# tests/fm-fleet-snapshot-view-fleet.test.sh - this fleet's own fleet snapshot
# and view cases: a backlog row whose checkbox contradicts its section heading
# is surfaced rather than silently resolved. They live beside upstream's
# tests/fm-fleet-snapshot-view.test.sh so a take-in never re-resolves them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-fleet)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The same fixture helpers upstream's suite defines.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# The 2026-08-31 incident: three completed rows stayed physically filed under
# "## Queued". tasks-axi reads the `- [x]` checkbox and called them done; every
# fleet-snapshot consumer reads only the section heading and called them queued,
# so firstmate relayed finished work to the captain as ready to start. Neither
# reader is now allowed to win quietly - the contradiction itself must surface.
test_checkbox_versus_section_conflict_is_surfaced() {
  local home fakebin out view
  home=$(make_home checkbox-conflict)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [x] misfiled-done - Finished but still filed queued (repo: alpha) (kind: ship) (merged 2026-08-31)
- [ ] honest-queued - Genuinely queued (repo: alpha) (kind: ship)

## Done
- [ ] misfiled-queued - Filed done but still unchecked (repo: alpha) (kind: ship)
- [x] honest-done - Genuinely done (repo: alpha) (kind: ship) (merged 2026-09-01)
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.state_conflict == true) | .id] | sort)
      == ["misfiled-done", "misfiled-queued"]
    and ([.backlog.records[] | select(.state_conflict == false) | .id] | sort)
      == ["honest-done", "honest-queued"]
  ' >/dev/null || fail "state_conflict must flag exactly the checkbox/section contradictions: $out"
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and (.main_inventory.state_conflicts | sort) == ["misfiled-done", "misfiled-queued"]
      and (.main_inventory.reason | startswith("backlog row checkbox contradicts its section heading"))
      and (.main_inventory.reason | contains("misfiled-done"))
      and (.main_inventory.reason | contains("misfiled-queued"))
  ' >/dev/null || fail "main_inventory must invalidate on a checkbox/section contradiction: $out"

  # The contradiction reaches the human surface rather than being hidden behind
  # a heading-only Queued/Done table.
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  case "$view" in
    *"## Contradictory Backlog Rows"*) : ;;
    *) fail "fleet view did not surface the contradictory rows: $view" ;;
  esac
  case "$view" in
    *"[checkbox conflict] Finished but still filed queued"*) : ;;
    *) fail "fleet view did not mark the misfiled queued row: $view" ;;
  esac
  case "$view" in
    *"[checkbox conflict] Filed done but still unchecked"*) : ;;
    *) fail "fleet view did not mark the misfiled done row: $view" ;;
  esac

  # A home whose own backlog contradicts itself is unreadable, not partial.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity.kind == "backlog_state_conflict"
      and (.invalidity.ids | sort) == ["misfiled-done", "misfiled-queued"]
  ' >/dev/null || fail "home summary must report backlog_state_conflict: $out"

  # Counterfactual: file both rows under the heading their checkbox already
  # claims and the disagreement disappears without any other change.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] honest-queued - Genuinely queued (repo: alpha) (kind: ship)
- [ ] misfiled-queued - Filed done but still unchecked (repo: alpha) (kind: ship)

## Done
- [x] misfiled-done - Finished but still filed queued (repo: alpha) (kind: ship) (merged 2026-08-31)
- [x] honest-done - Genuinely done (repo: alpha) (kind: ship) (merged 2026-09-01)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.state_conflicts | length) == 0
      and ([.backlog.records[] | select(.state_conflict == true)] | length) == 0
  ' >/dev/null || fail "refiled rows must clear the contradiction: $out"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  case "$view" in
    *"Contradictory Backlog Rows"*|*"checkbox conflict"*)
      fail "fleet view kept a contradiction warning after the rows were refiled: $view" ;;
  esac
  pass "checkbox-versus-section contradictions are reported, not silently resolved"
}

# The legacy `- **id**` row carries no checkbox at all, so it can never
# contradict its heading and must not be flagged wherever it is filed.
test_bold_row_without_checkbox_never_conflicts() {
  local home fakebin out
  home=$(make_home bold-no-conflict)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- **bold-queued** - Bold queued row (repo: alpha) (kind: ship)

## Done
- **bold-done** - Bold done row (repo: alpha) (kind: ship) (merged 2026-09-01)
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.structured) | .state_conflict] | unique) == [false]
      and .main_inventory.valid == true
      and (.main_inventory.state_conflicts | length) == 0
  ' >/dev/null || fail "checkbox-less bold rows must never register a conflict: $out"
  pass "legacy bold rows carry no checkbox and never conflict with their section"
}

fm_test_run \
  test_checkbox_versus_section_conflict_is_surfaced \
  test_bold_row_without_checkbox_never_conflicts
