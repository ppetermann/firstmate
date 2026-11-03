---
name: fleet-delivery-flow
description: >-
  Fleet-wide delivery flow contract: the six phases, the always-draft landing queue,
  the flip-once CI rule, the six-leg merge-ready contract, per-project tails, and the
  monthly Actions-cost read. Load at every ship-task intake, before every PR
  delivery/flip/landing decision, and at every release tail.
user-invocable: false
metadata:
  internal: true
---

# Fleet delivery flow

The bar rule: the project's committed CI is the single definition of green; the local
ladder is that CI run early. gate == CI. A gate failure outside the diff never widens
the PR — it becomes a chore task. Worker-facing commands live in each project's
AGENTS.md `## Delivery` section; `data/projects.md` stays the posture registry.
A project whose AGENTS.md has no
such section is NOT on this flow yet - resolve it at registration
(`project-management`) before dispatching ship work there.

## Phases
0. Intake: mode+yolo from registry; one task = one PR; trigger audit when workflows in
   scope (pull_request types incl. ready_for_review; every job guarded
   `!github.event.pull_request.draft`; concurrency group per ref with
   cancel-in-progress only for pull_request; publish lanes main+tags; paths-ignore
   never on a lane whose jobs are required contexts).
1. Local ladder green on the exact push head (fm-local-gate).
   Then, on an OCR bot repo, the local OCR review round by a SEPARATE reviewer worker
   (`ocr-delegate-review` standing pre-push round; never the implementer's self-review) on the committed branch, findings fixed and the
   ladder re-run, BEFORE the first push: push only a head expected to pass the flip's CI
   and bot round first time (captain, 2026-10-30; post-flip fix pushes rerun full CI).
2. Push once; PR opens DRAFT, always. Drafts run no CI and get no review rounds.
3. Landing queue: one ready PR per repo. On merge: refresh clone -> next draft rebases
   onto new main -> ladder on rebased head -> `bin/fm-pr-flip.sh <task-id|PR url>`, which
   flips and, on an OCR bot repo, queues the bot round in the same turn. The flip is the
   sole CI + review trigger. Shared-file overlap governs simultaneous readiness only.
4. Gauntlet: one CI run + one review round on the flip head. Post-flip verify within
   ~2 min: `gh-axi pr checks <n>` must list the CI context(s) and ocr-review. If
   ocr-review is missing (the flip went around fm-pr-flip.sh, or it exited 3):
   `sed -i '/^<n> /d' $FM_HOME/state/ocrbot/seen/ppetermann__<repo>` AND
   `rm -f $FM_HOME/state/ocrbot/etag/ppetermann__<repo>`, then it re-detects next
   poll (retires with ocr-review-service). The etag half is load-bearing: the poll
   short-circuits on an unchanged PR listing and never re-reads the seen file, so
   clearing seen alone is inert until something else changes that repo's listing
   (measured 2026-09-04 on maia-eve-secretary#44 - seen cleared at 18:32, the repo
   was still not polled at 18:40 while two sibling repos polled twice). fm-ocrbot-poll.sh
   now skips its cached ETag whenever the seen-state still has a tracked PR recorded
   draft, so an ordinary flip no longer needs this manual recovery; the sed+rm remains
   the fallback for any other reason ocr-review is missing. Flip-CI failure: fix via
   ladder + one push; longer work: `gh-axi pr ready <n> --undo`, iterate, re-flip
   through fm-pr-flip.sh.
   Converging cascade = stop and merge. Every thread resolved or rejected in-thread.
   REVIEWER ORDER, where two bind (maia, eve-members) - captain, 2026-09-06: the bot's
   rounds run FIRST and iterate; CodeRabbit is asked ONCE, only after the bot has cleared
   the PR. Never `@coderabbitai review` on a head the bot has not approved. Asking per fix
   push is what exhausted its rate limit on 2026-09-05 ('Review rate limited / Action not
   completed'), and it also strands its verdict on a commit the next push replaces, which
   then blocks the merge for a reason nothing on the PR explains.
   CodeRabbit also reviews every push on its own, so "asked ONCE" means asked only if its own review of the current head did not already approve.
   Immediately before posting, re-read its reviews for THIS head and skip the ask when one is APPROVED.
   If its check is still pending or it is mid-burst (reviews on this head within the last minute), wait for it to settle first.
   On maia#450 (2026-09-23) a read landed between its COMMENTED posts and its APPROVED four seconds later, and the ask went out six seconds after the approval.
5. Merge-ready contract, all six legs live in the reporting turn:
   (1) `gh-axi pr checks <n>` all required jobs run AND passed on the current head;
   (2) the AGGREGATE decision, read as `reviewDecision` from the GraphQL pullRequest,
       NOT "an approving review exists". Three values, three meanings: APPROVED passes;
       CHANGES_REQUESTED blocks; NULL means the branch requires no approving review at
       all (maia is such a repo - `required_pull_request_reviews: null` with required
       CONTEXTS instead), and there the leg is every binding reviewer having APPROVED
       the CURRENT head. Never read NULL as a block or APPROVED as automatic. Corroborate with `mergeStateStatus` in the same query: CLEAN means GitHub itself would allow the merge, BLOCKED means it would not - that one field would have caught eve-members#130, and it is cheaper than deriving the answer. It does not replace the other legs: it knows nothing about our second binding reviewer, the reviewed head, or unresolved threads. With two binding reviewers, one
       CHANGES_REQUESTED on an older commit still holds the merge after the other
       approves the current one, and resolving that reviewer's threads does NOT clear
       its verdict - only its own re-review does (`@coderabbitai review` asks for one).
       Measured 2026-09-05 on eve-members#130: bot APPROVED on the head, CodeRabbit
       CHANGES_REQUESTED on the parent, zero unresolved threads, decision still
       CHANGES_REQUESTED - reported merge-ready in error. The OCR bot gates
       every repo in `config/ocr-bot/repos` - read that file, do not carry a list
       here: today maia, eve-members, crew-watch, ocr-review-service and
       maia-eve-secretary. CodeRabbit binds additionally on maia and eve-members.
       maia-eve-secretary and ocr-review-service have the bot only and no
       CodeRabbit, so never wait for a reviewer that was never installed;
   (3) zero unresolved threads; (4) reviewed head == current head;
   (5) title/body describe the change; (6) full https URL in the report.
   Any failed leg: not ready — name the leg. The captain merges; record via
   bin/fm-pr-merge.sh.
6. Tails (batch when: user-facing fix >48h, or >=3 unreleased merges, or the captain
   asks):
   - eve-members: merge IS the release - a push-run on main deploys web+worker
     automatically (verify both deploy jobs green post-merge). AUTO_DEPLOY=false is an
     OPTIONAL emergency hold only (repo variable; absent = normal auto-deploy) - never
     the default posture, and PR-run deploy jobs skipping is correct, not a hold.
   - maia: merge -> :latest + dev tarball, operator pulls manually; docs-only merges
     skip publish. Versioned cut: tag v* (semver images + notes-generated release).
   - crew-watch: release PR (bump + notes from
     `git log v<prev>..HEAD --merges --format='- %s (%h)'`) -> merge -> annotated tag
     push = trusted publish -> rebuild PATH binary (crew-watch-release skill).

## Monthly cost read (first fleet review of each month)
for r in maia eve-members: sum completed-run wall time this month from
`gh-axi api --paginate "repos/ppetermann/$r/actions/runs?created=<YYYY-MM>-01..<today>&per_page=100"`
((.updated_at - .run_started_at) summed; approximate — parallel jobs undercount) and
surface one line per repo in the digest. Billing API endpoints 404 for this token
(verified 2026-08-29); the runs-list sum is the workable measure.
In the same turn print `bin/fm-review-tally.sh summary --since <YYYY-MM>-01`: the CodeRabbit-only catch rate per PR is the number the retire-CodeRabbit decision reads, and the coverage line says whether recording lapsed.

## Checklists
A intake: registry mode/yolo -> PR shape -> plan-first if sizeable -> trigger audit ->
  brief points at the project's Delivery section.
B pre-push: ladder green (gate-pass head= matches) -> pushed once -> DRAFT opened ->
  merge watch AND PR-readiness watch armed (bin/fm-pr-draft-check.sh <id> <PR url>; readiness recipe in process-event-sources) -> zero Actions runs fired ->
  backlog updated.
C flip: landing turn -> rebased -> ladder green -> flip via bin/fm-pr-flip.sh (bot round
  starts now) -> within ~2 min verify CI + ocr-review on this head (else seen-state
  recovery) -> CodeRabbit in flight where applicable.
D merge-ready: the six legs, live -> `bin/fm-maia-notify.sh send merge-ready --id merge-ready:<PR url>:<head sha> project=<repo> task=<id> pr_url=<PR url> pr_number=<n> title="<PR title>"` (a no-op unless config/maia-notify exists; the watcher now sends it automatically once a task PR is approved and green, so this line is the backstop and a repeat is dropped by its id; data/fleet-docs/maia-notify.md).
E post-merge: clone refreshed -> `bin/fm-review-tally.sh record <PR url>` (read the
  candidates it prints; re-run with --judge for any CodeRabbit finding the bot read and
  declined in its report; where both reviewers' candidates share a file, check which push actually fixed each and pass --acted-at <n>=<sha> wherever the proxy credits the wrong commit)
  -> queue advanced -> worker torn down -> tail evaluated
  against the batching triggers -> backlog updated.
F release: per-project tail from the Delivery section -> once verified live, `bin/fm-maia-notify.sh send deployed --id deployed:<project>:<version> project=<project> version=<version> url=<release URL>` -> report with full URL(s).
