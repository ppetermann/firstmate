# shellcheck shell=bash
# shellcheck disable=SC2016  # backticks inside single quotes are literal brief text
# Shared owner of the ship-brief per-mode contract text (Rule 1 and the full
# Definition of done), extracted verbatim from bin/fm-brief.sh's mode case so
# bin/fm-promote.sh can append the same contract to a promoted scout's brief
# without duplicating a byte of it. The two delivery modes are direct-PR and
# local-only; any other value is a caller error and each function refuses it.
# The caller's environment must define FM_ROOT (the firstmate code root named
# inside the direct-PR gate line) the same way bin/fm-brief.sh does; functions
# take the task id so the text can name the task's own branch.
#
# Command-substitution callers get the text without its trailing newline (the
# same shape fm-brief.sh's DOD=${DOD%$'\n'} discipline produces); direct
# callers get the newline, which is what a brief append wants.

fm_brief_ship_rule1() {  # <mode> <id>
  local mode=$1 id=$2
  case $mode in
    direct-PR)
      printf '%s\n' '1. Never push to the default branch (push only your `fm/'"$id"'` branch). Never merge a PR.'
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      ;;
    *)
      printf 'fm-brief-lib: unknown delivery mode: %s\n' "$mode" >&2
      return 1
      ;;
  esac
}

fm_brief_ship_dod() {  # <mode> <id>
  local mode=$1 id=$2
  case $mode in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself.
The task is complete only when committed on your branch.
Run the local gate before pushing: \`bash $FM_ROOT/bin/fm-local-gate.sh $id .\` - a red gate blocks the push; fix and re-gate.
When it is implemented and committed, push your branch ONCE and open the PR as a DRAFT - \`gh pr create --draft\` - then append \`done: PR {url}\` to the status file and stop.
Draft is not optional and has no exceptions: a draft runs no CI and draws no review round, which is the whole point. Never mark it ready yourself. Firstmate owns that flip and does it at this PR's landing turn, and the flip is what fires the one CI run and the one review round.
The PR description is written for HUMAN reviewers, not as an agent prompt: what the change is and why, how it works, test coverage, and any limitations - never task intents, instructions, or prompt-style text.
Give the PR a title that names what the change does for the project in plain words - never the task id, the branch name, or a tool-generated prefix.
When this task closes GitHub issues, end the PR body with one \`Closes #N\` line per issue so the merge closes them automatically.
The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
When the repository requires a review before merge, firstmate relays its findings to you, and addressing them is part of this task; land one round of fixes in a single push.
Once that review has approved, push nothing more: any new commit dismisses the approval and costs another full review round.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote and no PR.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    *)
      printf 'fm-brief-lib: unknown delivery mode: %s\n' "$mode" >&2
      return 1
      ;;
  esac
}
