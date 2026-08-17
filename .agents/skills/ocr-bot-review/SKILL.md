---
name: ocr-bot-review
description: >-
  Agent-only playbook for the OCR review bot's automated pull-request review rounds.
  Use on any "ocr-pr <owner/repo>#<number> <head_sha>" check wake to run one reviewer round for that PR head, and on any "ocrbot-error <detail>" check wake to report the bot's configuration or credential blocker.
  Owns wake handling, the backlog and concurrency contract, the reviewer brief block with the exact GitHub write shapes, verdict mapping, thread reconciliation, and the bot's failure policy.
  References ocr-delegate-review for the review core itself.
user-invocable: false
metadata:
  internal: true
---

# ocr-bot-review

The bot gates pull requests on registered repositories through a required `ocr-review` check run created by the captain's GitHub App; the ordinary PR review is the communication and the check run is the enforcement.
`docs/configuration.md` "OCR review bot (config/ocr-bot)" owns activation, files, and cadence, and `bin/fm-ocrbot-poll.sh` owns discovery and both wake-line formats.
This skill owns everything after the wake: routing, spawning, the reviewer brief block, verdict mapping, thread reconciliation, and the bot's failure policy.
The review core - file selection via `ocr delegate preview`, rule groups via `ocr delegate rule`, per-file diff reasoning, category and severity tagging - stays owned by `ocr-delegate-review`'s worker block; this skill references it and never restates it.

## Wake handling

On an `ocr-pr <owner/repo>#<n> <head_sha>` `check:` wake, run one reviewer round.

1. Deduplicate the round before any dispatch.
   Skip the wake when the App already has a completed `ocr-review` check run on that head SHA, read with the ambient auth: `gh api "repos/<owner>/<repo>/commits/<head_sha>/check-runs?check_name=ocr-review"`.
   Skip it too when a reviewer round for the same PR and head SHA is already under way in the fleet.
2. Record one backlog work item for the round, noting the PR URL and its head SHA, so every dispatch and completion updates the backlog per AGENTS.md section 10.
3. Enforce the standing concurrency bound of 2 simultaneous reviewer scouts; further rounds wait in the backlog until a slot clears.
   Two is deliberate: Z.AI throttles hard and rounds are short, so a deeper pool adds throttle risk, not throughput.
4. Spawn the reviewer in the project's clone with explicit harness and model, because dispatch profiles exist and `fm-spawn` refuses a bare spawn: `fm-spawn.sh ocrrev-<slug> projects/<repo> --scout --harness claude --model opus`.
   The reviewer binding follows `ocr-delegate-review` (claude/opus since 2026-08-17: GLM session budget exhausted mid-fleet; revert when the Z.AI window recovers).
   If the repository has no clone under `projects/` yet, load `project-management` and clone it through the normal add intake first.
5. Scaffold with `fm-brief.sh ocrrev-<slug> <repo> --scout`, then replace `{TASK}` with the filled reviewer brief block below.

On an `ocrbot-error <detail>` `check:` wake there is no review round.
Relay the diagnostic to the captain as a bot configuration or credential blocker, translated per AGENTS.md section 9, and stop; the poll already deduplicates the error, so one wake is one report.

## Reviewer brief block

Replace `{OCR_HOME}`, `{OCR_REPO}`, `{OCR_PR}`, `{OCR_HEAD}`, and `{OCR_BASE_REF}` with the firstmate home path, the `owner/repo`, the PR number, the recorded head SHA, and the PR's base ref.
Replace `{OCR_CORE}` with steps 2-4 of the `ocr-delegate-review` worker block pasted verbatim, with its `{OCR_BASE}` resolved to `git merge-base {OCR_BASE_REF} {OCR_HEAD}`; the pasted steps keep their own numbering and the round's steps resume after them.
Then paste the whole block into the brief's `{TASK}` area.

```markdown
## OCR bot review round ({OCR_REPO}#{OCR_PR} at {OCR_HEAD})
You are the reviewer for one automated OCR bot round on this pull request.
The gate is a required check run named `ocr-review` on the head SHA, and your GitHub writes post as the captain's GitHub App.
You review and report only: never fix, never commit, never push.

1. In this worktree, fetch the PR head and check out the exact recorded SHA: `git fetch origin "pull/{OCR_PR}/head:ocr-review-head"`, then `git checkout --detach {OCR_HEAD}`.
   If the fetch shows the PR head has moved past `{OCR_HEAD}`, review the newer head instead and record the SHA you actually reviewed; every later step names whatever head you reviewed.
2. Mint the App token and start the check run with a visible reviewing status: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api --method POST "repos/{OCR_REPO}/check-runs" -f name=ocr-review -f head_sha=<head SHA> -f status=in_progress -f "output[title]=OCR review" -f "output[summary]=Reviewing this pull request..."`.
   `GH_TOKEN` takes precedence over stored gh credentials, so this and every later `GH_TOKEN=...` write posts as the App and nothing else changes.
   Record the returned check-run `id` for step 6; the PR now shows the review under way with its summary line saying so.
   Also post the round's start comment so watchers see activity immediately: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api --method POST "repos/{OCR_REPO}/issues/{OCR_PR}/comments" -f body="OCR review round started for this head."`.
   Post that comment only when the PR has no prior start comment from the bot for this head: read the existing issue comments as the App and skip when one already names this head SHA, so re-runs and retries never spam.
3. {OCR_CORE}
   Apply the reviewer shape to the pasted core: report findings with category, severity, path, and line range in the new file, and never fix or commit anything.
4. Reconcile with the bot's existing threads on the PR before posting.
   Read them as the App: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api graphql -f query='query($owner: String!, $repo: String!, $n: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $n) { reviewThreads(first: 100) { nodes { id isResolved isOutdated comments(first: 20) { nodes { path body author { login } } } } } } } }' -f owner=<owner> -f repo=<repo> -F n={OCR_PR}`.
   Resolve a prior finding whose flagged code now passes: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' -f id=<thread id>`.
   A prior finding resolved by a human is the captain's per-finding override: honor it and never re-file the same finding, same path and same substance, on unchanged code.
   A standing finding keeps its thread: do not post a duplicate comment for it.
5. Post exactly one PR review carrying every finding as an inline comment.
   Build the payload with your own file tools, never by shell-interpolating finding text: a JSON object with `commit_id`, `event`, `body`, and a `comments` array where each entry has `path`, `line`, `side: "RIGHT"`, and a `body` tagging the finding as `_category_ | _severity_ | title` plus the detail.
   Set `event` to `REQUEST_CHANGES` when any critical, high, OR MEDIUM finding stands on unchanged code, otherwise `APPROVE` with a one-line clean summary as `body`.
   Medium findings block (the captain's 2026-08-17 tightening: non-blocking findings were being silently dropped after merge); low findings post as comments and never flip the verdict.
   Each LOW finding that stands unaddressed on unchanged code at APPROVE time is ALSO filed as a GitHub issue on the repo by the reviewer (title `low: <one-line>`, body citing finding, path:line, and the PR that surfaced it), and the review body's closing line names them: `Low findings filed as issues: #<n>, #<n>`. Lows are therefore never silently dropped - they live in the tracker until closed.
   Post it: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api --method POST "repos/{OCR_REPO}/pulls/{OCR_PR}/reviews" --input <payload file>`.
6. Complete the check run from step 2: `GH_TOKEN=$({OCR_HOME}/bin/fm-ocrbot-token.sh) gh api --method PATCH "repos/{OCR_REPO}/check-runs/<check-run id>" -f status=completed -f conclusion=<success|failure> -f "output[title]=ocr review" -f "output[summary]=<one-line verdict>"`.
   The conclusion is `failure` while a critical or high finding stands, `success` when clean.
   Never conclude `neutral`, `skipped`, or `cancelled` as an outcome signal: neutral and skipped satisfy required checks, so a round that could not run must instead leave the check `in_progress` or absent, both of which block the merge.
7. Write the round's findings, verdicts, and API evidence to your report file, then append `done: reviewed {OCR_REPO}#{OCR_PR} <approved|changes-requested|failed> [<reviewed SHA if it moved>]` to the status file.

If `ocr` is missing, or after one retry its commands keep failing or printing unparseable JSON, this round must not silently skip the way a manual round would.
Complete the check run as `failure` with an infrastructure summary naming the problem, post no review, and report `done: reviewed {OCR_REPO}#{OCR_PR} failed (ocr unavailable: <first-line reason>)` so the gate holds and firstmate wakes.
A token-mint failure instead means no check run exists: append `blocked: <the helper's first stderr line>` and stop; the missing check already blocks the merge.
```

## After the round

Read the scout report, mark the backlog round complete keyed by the PR and head SHA, relay the outcome to the captain per AGENTS.md section 9, and tear the scout down per its standard contract.
The verdict vocabulary for relaying: approved means the check is green and the PR can merge; changes-requested means critical, high, or medium findings stand and the threads carry the detail; failed means an infrastructure failure held the gate and is captain-relevant.
A round is idempotent per head SHA: once a head carries the App's completed `ocr-review` check, never review it again; only a new head SHA, which is a push, schedules the next round.
The bot's own etiquette: findings live only as inline threads in the one review, the verdict summary is the review body, re-review resolves the threads the new head addresses, and a human resolution is a per-finding override.
Fleet workers keep their side exactly as today: reply in threads, batch fixes into one push per round, and verify approval through the reviews API; each push now costs one bot round.

## Failure policy

Blocking, not passing, is the degraded mode: a missing, pending, or failed check blocks the merge, so every failure below holds the gate.
The bot round does not inherit the manual round's failure-soft skip; `ocr-delegate-review` owns that policy for captain-requested rounds only.
A reviewer that dies or pauses mid-round leaves the check `in_progress` or absent on the SHA; normal stale supervision surfaces it, and a relaunch re-runs the same SHA idempotently.
A 401 mid-round means the installation token lapsed; the helper re-mints under its ten-minute floor, so retry the failed call once through the helper.
A duplicate wake or double spawn for one SHA is harmless: the spawn-time dedupe above, the completed check run, and the round's done-marker keyed by PR and head SHA converge on one verdict.
If the App is uninstalled, the key is revoked, or the installation id is wrong, token minting fails loudly; relay it as a credential blocker and leave the gate closed.
