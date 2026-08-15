#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and the global turn-end-hook retirement path below them. The tables stay
# side-effect-free, so they can be sourced by a test as a pure contract;
# retirement mutates the operator's harness home and requires bin/fm-wake-lib.sh's
# lock helpers to be loaded by the caller at call time:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# and an unrecognized value returns nonzero rather than being guessed into a
# family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    muse*) printf 'muse' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse is a crewmate/scout
# adapter only: it has no primary supervision protocol, and bin/fm-spawn.sh
# refuses a --secondmate launch on it. The control plane
# asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|kimi|cursor|muse) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|grok|kimi|cursor|muse) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse) printf '/exit' ;;
    codex|pi|pi-signed) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-} dir
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  dir=$(fm_control_harness_turnend_registry_dir "$harness") || return 0
  printf '%s/%s\n' "$dir" "$token"
}

# The per-harness registry directory under which each task's turn-end auth token
# lives. This is the authority the global hooks themselves read: a non-empty
# registry means at least one task still uses the harness's global hook, so the
# global hook files must stay. fm_control_harness_turnend_auth_path composes
# `<registry_dir>/<token>` for a single entry; this function returns the
# directory itself, which fm_control_harness_turnend_maybe_retire_global counts.
fm_control_harness_turnend_registry_dir() {  # <harness>
  local harness=${1-}
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d" ;;
    *) return 1 ;;
  esac
}

# The per-harness registry lock serializing every global turn-end hook state
# transition. The lock directory is a SIBLING of the registry (never inside it)
# so retirement can remove the registry without destroying the lock itself, and
# fm_lock_release removes the lock directory on release, so a fully retired
# harness leaves nothing behind in the operator's home. Holders:
# fm_control_harness_turnend_maybe_retire_global here, and fm-spawn.sh's grok
# and kimi token-mint/hook-write sections. The kimi installer script itself
# takes no lock; both of its callers hold this one across each invocation.
fm_control_harness_turnend_lock_path() {  # <harness>
  local harness=${1-} registry
  registry=$(fm_control_harness_turnend_registry_dir "$harness") || return 1
  printf '%s.lock\n' "$registry"
}

# Maybe retire a harness's global turn-end hook files when the last task using
# that harness goes away. Called from fm-teardown.sh after the task's own auth
# token is removed, and from fm-spawn.sh's clear_relaunch_harness_wiring after
# a relaunch revokes the previous incarnation's entry. Counts the registry
# entries; if zero, removes the global hook files so they do not persist as
# permanent cruft in the operator's home directory.
#
# Concurrency safety (per-harness registry lock): the count and every
# destructive step run while holding fm_control_harness_turnend_lock_path, and
# fm-spawn.sh holds the same lock across each harness's token-mint plus
# hook-write section, so a retirement can never interleave with a spawn's
# install.
# A spawn whose entry is minted before this count runs keeps its hook files,
# because the count observes its registry entry under the lock.
# A spawn that waits on the lock re-installs after the retirement completes,
# so it always launches with its own live entry plus a fresh hook.
# The lock helpers come from bin/fm-wake-lib.sh; if a caller environment lacks
# them, retirement is skipped with a warning rather than racing unprotected.
#
# grok's hook files are removed directly; kimi delegates to its installer's
# symmetric `remove` subcommand so the marker-delimited config.toml edit stays
# surgical. Returns 0 silently when the registry still holds entries, when the
# registry is missing, or when the harness has no global hook.
fm_control_harness_turnend_maybe_retire_global() {  # <harness> <script_dir>
  local harness=${1-} script_dir=${2-} registry count grok_hooks lock
  registry=$(fm_control_harness_turnend_registry_dir "$harness") 2>/dev/null || return 0
  [ -n "$registry" ] || return 0
  [ -d "$registry" ] || return 0
  lock=$(fm_control_harness_turnend_lock_path "$harness") || return 0
  if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    echo "warning: skipping global turn-end hook retirement for $harness: fm-wake-lib.sh lock helpers are not loaded" >&2
    return 0
  fi
  fm_lock_acquire_wait "$lock"
  count=$(find "$registry" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    case "$harness" in
      grok)
        grok_hooks=$(dirname "$registry")
        rm -f -- "$grok_hooks/fm-turn-end.sh" "$grok_hooks/fm-turn-end.json"
        rmdir -- "$registry" 2>/dev/null || true
        ;;
      kimi)
        "$script_dir/fm-kimi-turnend-hook.sh" remove 2>/dev/null || true
        ;;
    esac
  fi
  fm_lock_release "$lock" || true
  return 0
}

# Read a harness's per-task turn-end token safely, printing the token (or nothing)
# to stdout. This is the ONE owner of the empty-token guard that teardown's grok
# and kimi retirement (bin/fm-teardown.sh) and spawn's relaunch-wiring cleanup
# (bin/fm-spawn.sh) must apply identically.
#
# fm_control_harness_turnend_token_path names where the token lives; this reads
# it. A missing token file, an empty token_path (any harness whose turn-end hook
# is not global-and-token-gated, so token_path declines to name one), and a
# ZERO-BYTE token file are all the same nothing-to-revoke case: the token is
# written with a plain redirect, which truncates before the token lands, so a
# crash or kill in that window leaves an empty file; treating its EOF as a read
# failure would abort teardown before any state is removed and the task could
# never be torn down again. A token that is present and non-empty but unreadable
# still fails closed (returns 1), because that one really would strand a live
# global registry entry. The path lookup's own argument-validation failure
# (empty state or id) propagates as nonzero so a caller's `|| return 1` still
# fires. Prints the token (possibly empty) on success.
fm_control_harness_turnend_token_read() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-} token_path token=''
  token_path=$(fm_control_harness_turnend_token_path "$harness" "$state" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ] && [ -s "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  printf '%s' "$token"
}
