#!/usr/bin/env bash
# tests/harness-drift-helpers.sh - the single owner of the verified-adapter
# harness list and the launch-path resolver every opt-in live drift guard
# shares.
#
# Sourced by tests/fm-composer-drift-live-e2e.test.sh (the tmux composer
# reader), tests/fm-herdr-composer-drift-live-e2e.test.sh (the herdr composer
# reader), and tests/fm-harness-liveness-drift-live-e2e.test.sh (the tmux
# liveness classifier). Each guard keeps its own backend-specific probe body;
# only the facts that must be identical across all of them live here. A list
# copied per guard leaves a newly verified adapter unchecked in whichever copy
# was not updated, while every guard still reports a green pass and a
# "checked N installed harness(es)" line that reads as full coverage.
set -u

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too -
# this list is the only place to add it.
# shellcheck disable=SC2034 # Read by the guards that source this file.
FM_DRIFT_HARNESSES=(claude codex opencode pi pi-signed grok kimi muse)

# Mirror bin/fm-spawn.sh's own resolution order so these guards cover the same
# binary firstmate would actually launch. Kimi is not required to be on PATH.
fm_drift_resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# A pane that has not drawn its TUI yet is mostly blank, and a blank row
# legitimately classifies as an empty composer. Requiring a drawn screen BEFORE
# the first verdict is what stops a guard passing vacuously against a harness
# that never finished starting. The calling guard supplies `fm_drift_capture
# <target>`, which must print that pane's current screen over its own backend.
fm_drift_wait_for_drawn() {  # <target> <polls>
  local target=$1 polls=$2 i=0 rows
  while [ "$i" -lt "$polls" ]; do
    rows=$(fm_drift_capture "$target" 2>/dev/null | grep -c '[^[:space:]]' || true)
    if [ "${rows:-0}" -ge 3 ]; then
      sleep 2   # let the first full frame settle before reading a verdict
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
