#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'done: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

# Workers naturally write the [key=<slug>] token AFTER the colon
# ("needs-decision: [key=x] ..."). fm-classify-lib.sh's _fm_decision_key accepts
# that position as a fallback so such a line still folds to key x (not "default")
# and interoperates with a matching "resolved: [key=x] ..." close. These cases
# exercise the real fold through the real drain script, like every case above.

test_after_colon_key_position_opens_a_decision() {
  local dir state out
  dir=$(make_case after-colon-open)
  state="$dir/state"
  out="$dir/drain.out"
  # The key token sits after the colon, where workers put it. It must surface
  # under its named key so fm-send --resolve-key <after-colon> can close it.
  printf 'needs-decision: [key=after-colon] pick REST or RPC\n' > "$state/task-after.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an after-colon open"

  # The drain prints the fold's key in a normalized position, before the verb
  # ("<task> [key=<key>] <verb>: <note>"), and omits it entirely for "default".
  # Asserting that rendered prefix is what distinguishes a genuine key-x fold
  # from a default fold that merely echoes the token back inside the note.
  grep -F 'task-after [key=after-colon] needs-decision:' "$out" >/dev/null \
    || fail "an after-colon [key=...] token did not surface under its named key: $(cat "$out")"
  grep -F 'pick REST or RPC' "$out" >/dev/null \
    || fail "the after-colon open lost its note: $(cat "$out")"
  pass "a [key=...] token after the colon opens a decision under that key"
}

test_after_colon_open_is_closed_only_by_its_own_key() {
  local dir state out
  dir=$(make_case after-colon-resolve)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: [key=after-colon] pick REST or RPC\n' > "$state/task-after2.status"
  # A bare unkeyed resolution opens/closes only "default", so it must NOT close
  # a decision the after-colon token named: the decision stays open.
  printf 'resolved: unrelated close\n' >> "$state/task-after2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unkeyed resolution"

  grep -F 'task-after2 [key=after-colon] needs-decision:' "$out" >/dev/null \
    || fail "a bare unkeyed resolved: cleared an after-colon keyed decision: $(cat "$out")"

  # The matching close - the "resolved [key=<key>]: ..." form bin/fm-send.sh
  # writes for --resolve-key - does close it, so the two positions interoperate.
  printf 'resolved [key=after-colon]: answered: went with REST\n' >> "$state/task-after2.status"
  printf 'done: shipped\n' >> "$state/task-after2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the matching resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the matching resolved [key=X] did not close the after-colon decision: $(cat "$out")"
  fi
  pass "an after-colon keyed decision is closed only by its own key, not by a bare resolved:"
}

test_before_colon_open_is_closed_by_after_colon_resolve() {
  local dir state out
  dir=$(make_case cross-position)
  state="$dir/state"
  out="$dir/drain.out"
  # Open with the canonical before-colon token, close with the after-colon
  # token. Both must yield the same key so the two positions interoperate
  # regardless of which side the writer used.
  printf 'needs-decision [key=cross]: pick REST or RPC\n' > "$state/task-cross.status"
  printf 'resolved: [key=cross] went with REST\n' >> "$state/task-cross.status"
  printf 'done: shipped\n' >> "$state/task-cross.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a cross-position open/close"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a before-colon open was not closed by an after-colon resolved: $(cat "$out")"
  fi
  pass "the before-colon and after-colon key positions interoperate"
}

# A malformed slug must never make the escalation disappear - a needs-decision a
# worker stopped on is the one thing this fold exists to keep visible - and must
# never land in the "default" bucket either, where it would overwrite or close
# the historical unkeyed decision. Both positions fall back to the reserved
# "invalid-key" bucket instead. The drain prefixes every non-default key, so the
# rendered "[key=invalid-key]" is what shows which bucket the line folded into.

test_invalid_slug_after_colon_surfaces_under_invalid_key() {
  local dir state out
  dir=$(make_case after-colon-invalid)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision: [key=bad slug] should not vanish\n' > "$state/task-bad.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an invalid after-colon slug"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || fail "an invalid after-colon slug made the escalation vanish: $(cat "$out")"
  grep -F 'task-bad [key=invalid-key] needs-decision:' "$out" >/dev/null \
    || fail "an invalid after-colon slug did not surface under invalid-key: $(cat "$out")"
  pass "an invalid slug after the colon surfaces under the invalid-key bucket"
}

test_invalid_slug_before_colon_surfaces_under_invalid_key() {
  local dir state out
  dir=$(make_case before-colon-invalid)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=bad slug]: should not vanish\n' > "$state/task-bad2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an invalid before-colon slug"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || fail "an invalid before-colon slug made the escalation vanish: $(cat "$out")"
  grep -F 'task-bad2 [key=invalid-key] needs-decision: should not vanish' "$out" >/dev/null \
    || fail "an invalid before-colon slug did not surface under invalid-key: $(cat "$out")"
  pass "an invalid slug before the colon surfaces under the invalid-key bucket"
}

test_invalid_slug_does_not_mask_a_real_default_decision() {
  local dir state out
  dir=$(make_case invalid-vs-default)
  state="$dir/state"
  out="$dir/drain.out"
  # A rule-5 blocker is unkeyed, so it holds the "default" record. A later
  # malformed escalation must not take that bucket over: were it to fold to
  # "default" the fold would drop the blocker's record before re-adding its own,
  # and the real blocker would silently disappear from OPEN DECISIONS.
  printf 'blocked: real blocker here\n' > "$state/task-both.status"
  printf 'needs-decision [key=bad slug]: should not vanish\n' >> "$state/task-both.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a mixed invalid/default stream"

  grep -F 'task-both blocked: real blocker here' "$out" >/dev/null \
    || fail "a malformed line masked the real unkeyed blocker: $(cat "$out")"
  grep -F 'task-both [key=invalid-key] needs-decision: should not vanish' "$out" >/dev/null \
    || fail "the malformed escalation did not surface under invalid-key: $(cat "$out")"
  pass "a malformed key never masks a real unkeyed decision"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_after_colon_key_position_opens_a_decision
test_after_colon_open_is_closed_only_by_its_own_key
test_before_colon_open_is_closed_by_after_colon_resolve
test_invalid_slug_after_colon_surfaces_under_invalid_key
test_invalid_slug_before_colon_surfaces_under_invalid_key
test_invalid_slug_does_not_mask_a_real_default_decision
