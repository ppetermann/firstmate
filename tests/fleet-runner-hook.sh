#!/usr/bin/env bash
# tests/fleet-runner-hook.sh - this fleet's additions to bin/fm-test-run.sh,
# sourced once by the runner after its own functions are defined, so the
# runner itself stays upstream's file. Each addition is layered over upstream's
# function of the same purpose rather than editing it:
#   - family_for_basename: fleet-only suites get their family first; every
#     other suite falls through to upstream's table.
#   - portable_serial_weight_hints: fleet hint rows are appended only for paths
#     upstream's table does not list, so upstream wins any path it measures.
#   - families_for_changed_path: fleet-only source paths get their families,
#     and a few shared paths gain a fleet family on top of upstream's.
# Keep this file fleet-owned; never copy an upstream row here.

eval "fm_upstream_$(declare -f family_for_basename)"
family_for_basename() {
  case "$1" in
    fm-afk-shutdown-e2e.test.sh) printf '%s\n' afk ;;
    fm-brief-fleet.test.sh) printf '%s\n' pure-contract-unit ;;
    fm-claude-trust-gate.test.sh) printf '%s\n' pure-contract-unit ;;
    fm-composer-drift-live-e2e.test.sh) printf '%s\n' live-harness-optin ;;
    fm-composer-pane-shapes.test.sh) printf '%s\n' pure-contract-unit ;;
    fm-effort-ledger.test.sh) printf '%s\n' pr-forge ;;
    fm-fleet-snapshot-view-fleet.test.sh) printf '%s\n' snapshot-bearings ;;
    fm-herdr-composer-drift-live-e2e.test.sh) printf '%s\n' live-harness-optin ;;
    fm-interrupt-composer-live-e2e.test.sh) printf '%s\n' live-harness-optin ;;
    fm-local-gate.test.sh) printf '%s\n' pure-contract-unit ;;
    fm-ocrbot-poll.test.sh) printf '%s\n' pr-forge ;;
    fm-ocrbot-token.test.sh) printf '%s\n' pr-forge ;;
    fm-pr-verdict.test.sh) printf '%s\n' pr-forge ;;
    fm-signal-wait-lib.test.sh) printf '%s\n' watcher-wake-lock ;;
    fm-watch-checkpoint-fleet.test.sh) printf '%s\n' watcher-wake-lock ;;
    fm-worker-tmp-root.test.sh) printf '%s\n' backend-dispatch ;;
    fm-watch-triage-fleet.test.sh) printf '%s\n' watcher-wake-lock ;;
    *) fm_upstream_family_for_basename "$1" ;;
  esac
}

eval "fm_upstream_$(declare -f portable_serial_weight_hints)"
fm_fleet_serial_weight_hints() {
  cat <<'HINTS'
tests/fm-afk-shutdown-e2e.test.sh 23952
tests/fm-backend-rex-composer-live-e2e.test.sh 131
tests/fm-backend-rex-eventwait-smoke.test.sh 131
tests/fm-backend-rex-smoke.test.sh 134
tests/fm-backend-rex.test.sh 20242
tests/fm-backlog-guard.test.sh 1434
tests/fm-brief-content-lib.test.sh 135
tests/fm-capacity.test.sh 11044
tests/fm-chrome-devtools-session.test.sh 430
tests/fm-claude-trust-gate.test.sh 28048
tests/fm-composer-drift-live-e2e.test.sh 135
tests/fm-composer-pane-shapes.test.sh 3941
tests/fm-dispatch-facts.test.sh 1833
tests/fm-effort-ledger.test.sh 2904
tests/fm-fleet-snapshot-contribution-input.test.sh 340
tests/fm-git-push-guard.test.sh 1723
tests/fm-herdr-composer-drift-live-e2e.test.sh 136
tests/fm-interrupt-composer-live-e2e.test.sh 22
tests/fm-local-gate.test.sh 2524
tests/fm-maia-notify.test.sh 13852
tests/fm-missed-done-wake-regression.test.sh 6740
tests/fm-ocrbot-poll.test.sh 20644
tests/fm-ocrbot-token.test.sh 2437
tests/fm-opencode-abs-cwd-rail-live-e2e.test.sh 130
tests/fm-parent-channel-scan-exclusion.test.sh 5132
tests/fm-pipeline-spend.test.sh 11735
tests/fm-pool-disk.test.sh 35059
tests/fm-pr-check-lint.test.sh 436
tests/fm-pr-health.test.sh 59277
tests/fm-pr-verdict.test.sh 525
tests/fm-project-capacity.test.sh 75779
tests/fm-project-mode.test.sh 549
tests/fm-promote.test.sh 5036
tests/fm-remote-delta-read.test.sh 6732
tests/fm-remote-job-claim-reap.test.sh 3128
tests/fm-remote-job-claim-retention.test.sh 329
tests/fm-remote-job-launchagent.test.sh 64674
tests/fm-review-check.test.sh 2740
tests/fm-review-tally.test.sh 4332
tests/fm-self-repo-role.test.sh 9255
tests/fm-signal-wait-lib.test.sh 62670
tests/fm-spawn-brief-content.test.sh 825
tests/fm-spawn-empty-project.test.sh 2632
tests/fm-spawn-external-review.test.sh 6931
tests/fm-spawn-low-disk.test.sh 20029
tests/fm-startup-growth-check.test.sh 8942
tests/fm-stow-plan.test.sh 1334
tests/fm-worker-tmp-root.test.sh 29151
tests/ocr-review-rule-live.test.sh 925
HINTS
}
portable_serial_weight_hints() {
  fm_upstream_portable_serial_weight_hints
  awk 'NR == FNR { if (NF) seen[$1] = 1; next } NF && !($1 in seen)' \
    <(fm_upstream_portable_serial_weight_hints) <(fm_fleet_serial_weight_hints)
}

eval "fm_upstream_$(declare -f families_for_changed_path)"
families_for_changed_path() {
  local path=$1
  case "$path" in
    tests/fleet-runner-hook.sh)
      # This file is part of the runner, so it selects what the runner does.
      fm_upstream_families_for_changed_path bin/fm-test-run.sh
      return 0
      ;;
    bin/fm-task-tmp-lib.sh)
      # The per-task temp root owner: spawn, teardown, brief, and bootstrap.
      printf '%s\n' backend-dispatch session-bootstrap
      return 0
      ;;
    bin/fm-effort-ledger.sh)
      printf '%s\n' pr-forge
      return 0
      ;;
    bin/fm-tmux-lib.sh)
      printf '%s\n' backend-dispatch pure-contract-unit live-harness-optin
      return 0
      ;;
    .agents/skills/*/references/*.md|GROK_BOT.md|VISION.md)
      printf '%s\n' pure-contract-unit
      return 0
      ;;
    tests/fakebin-write.sh)
      # Suites that cannot take tests/lib.sh source this carrier by name; every
      # other suite inherits it through that library.
      families_for_test_reference fakebin-write.sh lib.sh \
        || printf '%s\n' "__unmapped__:$path"
      return 0
      ;;
    tests/fm-composer-classify-probe.sh|tests/*.py|tests/assets/*)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      return 0
      ;;
  esac
  fm_upstream_families_for_changed_path "$path"
  case "$path" in
    # These read a surface each harness VENDOR draws, so a change here also
    # selects the opt-in installed-harness drift guard.
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh|tests/herdr-client-pair-fixture.sh|\
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' live-harness-optin
      ;;
  esac
}
