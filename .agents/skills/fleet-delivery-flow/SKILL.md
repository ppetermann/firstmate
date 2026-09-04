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
1. Local ladder green on the exact push head (fm-local-gate or pipeline).
2. Push once; PR opens DRAFT, always. Drafts run no CI and get no review rounds.
3. Landing queue: one ready PR per repo. On merge: refresh clone -> next draft rebases
   onto new main -> ladder on rebased head -> `gh-axi pr ready <n>`. The flip is the
   sole CI + review trigger. Shared-file overlap governs simultaneous readiness only.
4. Gauntlet: one CI run + one review round on the flip head. Post-flip verify within
   ~5 min: `gh-axi pr checks <n>` must list the CI context(s) and ocr-review. If
   ocr-review is missing (resident bot missed the flip):
   `sed -i '/^<n> /d' $FM_HOME/state/ocrbot/seen/ppetermann__<repo>` and it
   re-detects next poll (retires with ocr-review-service). Flip-CI failure: fix via
   ladder + one push; longer work: `gh-axi pr ready <n> --undo`, iterate, re-flip.
   Converging cascade = stop and merge. Every thread resolved or rejected in-thread.
5. Merge-ready contract, all six legs live in the reporting turn:
   (1) `gh-axi pr checks <n>` all required jobs run AND passed on the current head;
   (2) `gh-axi pr view <n> --reviews` binding review APPROVED (CodeRabbit on
       maia/eve-members; the OCR bot's approving review on crew-watch);
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

## Checklists
A intake: registry mode/yolo -> PR shape -> plan-first if sizeable -> trigger audit ->
  brief points at the project's Delivery section.
B pre-push: ladder green (gate-pass head= matches) -> pushed once -> DRAFT opened ->
  merge watch AND PR-readiness watch armed (bin/fm-pr-check.sh <id> <PR url>; readiness recipe in process-event-sources) -> zero Actions runs fired ->
  backlog updated.
C flip: landing turn -> rebased -> ladder green -> flip -> verify CI + ocr-review on
  this head (else seen-state recovery) -> CodeRabbit in flight where applicable.
D merge-ready: the six legs, live.
E post-merge: clone refreshed -> queue advanced -> worker torn down -> tail evaluated
  against the batching triggers -> backlog updated.
F release: per-project tail from the Delivery section -> report with full URL(s).
