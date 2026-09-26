#!/usr/bin/env bash
# fm-brief-content-lib.sh - the single owner of "does this brief/charter file
# carry real instructions" validity, checked before a worker ever reads it.
#
# Not to be confused with bin/fm-dod-lib.sh, the ship-brief per-mode
# contract-text owner shared between bin/fm-brief.sh and bin/fm-promote.sh.
# This file owns a different, narrower contract: the {TASK} placeholder.
#
# bin/fm-brief.sh scaffolds a ship/scout brief or secondmate charter with a
# literal `{TASK}` placeholder (its header comment is the placeholder's
# authoritative documentation); firstmate replaces it by hand before spawning.
# That hand-off has no automated enforcement, so a scaffold that never got
# filled in - or a brief file left byte-empty - previously reached the harness
# launch template unnoticed: every embedding launch template (bin/fm-spawn.sh's
# launch_template) reads the brief through a live
# `"$(__OPINPUT__ encode launch-brief < __BRIEF__)"` command substitution
# inside the spawned pane's own shell, and fm-operational-input.sh's encode
# path silently returns nothing on an empty body (its `[ -n "$body" ] ||
# return 2` guard) rather than failing loudly - so an unfilled brief produced a
# harness launched with a genuinely empty prompt with no error anywhere
# (data/fm-spawn-empty-prompt/report.md: an opencode batch spawn booted three
# workers this way, and a later fm-control relaunch of the same
# already-broken tasks carried the same missing instructions forward).
#
# fm-spawn.sh and fm-control.sh both call fm_brief_has_content before a brief
# can reach a launch template or a relaunched worker, so this predicate is
# the one place that "empty" or "placeholder-only" is defined.

# fm_brief_has_content: true when FILE exists, is readable, is non-blank, and
# carries no unreplaced {TASK} placeholder. False on any other case; prints
# nothing so each caller composes its own diagnostic naming its own operation.
fm_brief_has_content() {  # <file>
  local file=${1-} content
  [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 1
  content=$(cat "$file" 2>/dev/null) || return 1
  case "$content" in
    *'{TASK}'*) return 1 ;;
  esac
  [ -n "${content//[[:space:]]/}" ]
}
