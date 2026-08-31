# shellcheck shell=bash
# shellcheck disable=SC2016  # backticks inside single quotes are literal brief text
# Shared owner of the ship-brief per-mode contract text (Setup 2, Rule 1, and
# the full Definition of done), extracted verbatim from bin/fm-brief.sh's mode
# case so bin/fm-promote.sh can append the same contract to a promoted scout's
# brief without duplicating a byte of it. The caller's environment must define
# FM_ROOT (the firstmate code root named inside the direct-PR gate line) the
# same way bin/fm-brief.sh does; functions take the task id so the text can
# name the task's own branch.
#
# Command-substitution callers get the text without its trailing newline (the
# same shape fm-brief.sh's DOD=${DOD%$'\n'} discipline produces); direct
# callers get the newline, which is what a brief append wants.

fm_brief_ship_setup2() {  # <mode>
  local mode=$1
  case $mode in
    no-mistakes)
      printf '\n2. Run `no-mistakes doctor`; if it reports the repo is not initialized here, run `no-mistakes init`.\n'
      ;;
    *)  # direct-PR and local-only carry no second setup step
      ;;
  esac
}

fm_brief_ship_rule1() {  # <mode> <id>
  local mode=$1 id=$2
  case $mode in
    direct-PR)
      printf '%s\n' '1. Never push to the default branch (push only your `fm/'"$id"'` branch). Never merge a PR.'
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      ;;
    *)  # no-mistakes
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
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
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Run the local gate before pushing: \`bash $FM_ROOT/bin/fm-local-gate.sh $id .\` - a red gate blocks the push; fix and re-gate.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
The PR description is written for HUMAN reviewers, not as an agent prompt: what the change is and why, how it works, test coverage, and any limitations - never pipeline intents, instructions, or prompt-style text.
Give the PR a title that names what the change does for the project in plain words - never the task id, the branch name, or a pipeline-generated prefix.
When this task closes GitHub issues, end the PR body with one \`Closes #N\` line per issue so the merge closes them automatically.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
When the repository requires a review before merge, firstmate relays its findings to you, and addressing them is part of this task; land one round of fixes in a single push.
Once that review has approved, push nothing more: any new commit dismisses the approval and costs another full review round.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    *)  # no-mistakes
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

Before reporting, write the PR description for HUMAN reviewers - what the change is and why, how it works, test coverage, limitations - never the pipeline intent or any prompt-style text; a pipeline may pre-fill the body, so replace it.
Give the PR a title that names what the change does for the project in plain words - never the task id, the branch name, or a pipeline-generated prefix.
When this task closes GitHub issues, end the PR body with one \`Closes #N\` line per issue so the merge closes them automatically.
After /no-mistakes reports CI green (the CI-ready return point - report now so firstmate can tell the captain early, never silently monitoring the PR through to merge), append \`done: PR {url} checks green\` and stop.
When the repository requires a review before merge, that report is a milestone, not the finish: the merge bar is CI green plus the repository's required review approving, so check the PR's review state before appending the report.
If that review has already requested changes, do not append \`done:\` yet - addressing its findings is part of this task, so land that round's fixes in a single push and report at the next CI-ready return point.
If its verdict arrives only after your report, firstmate will relay it to you, and addressing it stays part of this task rather than new work.
Once that review has approved, push nothing more: any new commit dismisses the approval and costs another full review round, so never start another validation run against an approved PR.
When no review bar applies, that report finishes your part; the merge itself stays with the configured merge authority.
EOF
      ;;
  esac
}
