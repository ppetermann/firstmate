#!/usr/bin/env bash
# Behavior tests for bin/fm-brief-content-lib.sh's fm_brief_has_content
# predicate: the single owner of "does this brief/charter file carry real
# instructions", checked by both fm-spawn.sh (before any harness launch
# template embeds the brief) and fm-control.sh (before a relaunch appends its
# progress note).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-brief-content-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-content-lib)

test_missing_file_has_no_content() {
  fm_brief_has_content "$TMP_ROOT/does-not-exist.md" \
    && fail "a missing file must not report content"
  pass "fm_brief_has_content: a missing file is refused"
}

test_byte_empty_file_has_no_content() {
  local f="$TMP_ROOT/empty.md"
  : > "$f"
  fm_brief_has_content "$f" && fail "a byte-empty file must not report content"
  pass "fm_brief_has_content: a byte-empty file is refused"
}

test_whitespace_only_file_has_no_content() {
  local f="$TMP_ROOT/whitespace.md"
  printf '  \n\t\n  \n' > "$f"
  fm_brief_has_content "$f" && fail "a whitespace-only file must not report content"
  pass "fm_brief_has_content: a whitespace-only file is refused"
}

test_unreplaced_placeholder_has_no_content() {
  local f="$TMP_ROOT/placeholder.md"
  printf '# brief\n\n{TASK}\n\n## Rules\n' > "$f"
  fm_brief_has_content "$f" && fail "an unreplaced {TASK} placeholder must not report content"
  pass "fm_brief_has_content: an unreplaced {TASK} placeholder is refused"
}

test_placeholder_mixed_with_real_text_has_no_content() {
  local f="$TMP_ROOT/mixed.md"
  printf 'Fix the thing. {TASK} Also do more.\n' > "$f"
  fm_brief_has_content "$f" \
    && fail "any surviving {TASK} placeholder must refuse, even alongside real prose"
  pass "fm_brief_has_content: a surviving {TASK} placeholder refuses even mixed with real text"
}

test_real_content_has_content() {
  local f="$TMP_ROOT/real.md"
  printf '# brief for eve-evemail-s06\n\nDo the actual task.\n' > "$f"
  fm_brief_has_content "$f" || fail "a filled-in brief must report content"
  pass "fm_brief_has_content: a filled-in brief is accepted"
}

test_content_word_task_without_braces_is_fine() {
  local f="$TMP_ROOT/word-task.md"
  printf 'This task is about fixing the spawn prompt bug.\n' > "$f"
  fm_brief_has_content "$f" \
    || fail "the plain word 'task' (no braces, no placeholder) must not be treated as the placeholder"
  pass "fm_brief_has_content: the word 'task' without braces is not mistaken for the placeholder"
}

test_missing_file_has_no_content
test_byte_empty_file_has_no_content
test_whitespace_only_file_has_no_content
test_unreplaced_placeholder_has_no_content
test_placeholder_mixed_with_real_text_has_no_content
test_real_content_has_content
test_content_word_task_without_braces_is_fine
