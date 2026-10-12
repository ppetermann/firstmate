---
name: ocr-delegate-review
description: >-
  Agent-only procedure for the captain-invoked OpenCodeReview (OCR) delegation-mode review round on a task or a whole project.
  Load only when the captain explicitly requests an OCR review for a specific task or a whole project; never load or apply it as a default or automatic gate.
  Owns reviewer binding, the worker instruction block and its delivery paths, the whole-project scan shape, the failure-soft policy, and the reporting shape.
user-invocable: false
metadata:
  internal: true
---

# ocr-delegate-review

## Opt-in guard

This round is per request: it runs only when the captain explicitly requested it, as an OCR review round for a specific task or a whole-project review.
Never apply it as a standing posture, a default gate, or an automatic step on any project or delivery mode.
The one captain-approved standing exception: repositories listed in `config/ocr-bot/repos` are reviewed automatically by the OCR review bot per `ocr-bot-review`, which owns that exception's entire contract; manual rounds there and everywhere else stay opt-in-only.
Standing yolo authority is not a substitute for the explicit request.
If the captain ever asks to make OCR review standing or automatic beyond that registered set, do not silently comply.
Surface that this contradicts the recorded opt-in-only constraint and ask the captain to confirm changing the constraint itself.

## When it applies

A per-task round runs after the implementation is committed and before the delivery mode's completion step.
That is before a `direct-PR` push and before the `local-only` ready report.
If the captain asks for the round after validation has started or the PR exists, report that the pre-PR window has passed instead of improvising a post-hoc variant.
A whole-project review has no completion window: commission it as its own scout under the whole-project section below.

## Reviewer binding

A review round resolves its reviewer from `config/crew-dispatch.json` at dispatch rather than binding a harness or model here. Take that config's OCR review-round rule when one is present - the captain pins OCR rounds separately from the rest of the fleet, and on 2026-09-15 that pin is glm-5.3 while the active setup stays claude. With no OCR-specific rule, fall back to the JUDGEMENT AND CORRECTION class under the active setup.
Both paths below deliver the filled worker block: `{OCR_BASE}` becomes the project's default-branch ref, normally `origin/main`, the same base the ship branch was created from; `{OCR_RULE}` becomes the absolute path to `review-rule.json` beside this skill in the active firstmate home; and any captain-requested `--exclude` patterns are appended to the preview and rule commands.
`review-rule.json` is what makes documentation, container build, example configuration, and changelog files reviewable at all: `ocr` classifies none of Markdown, `Dockerfile*`, `*.example` (as in `env.example`), or `CHANGELOG*.txt`, so without it those files come back `unsupported_ext` and a diff carrying only them previews as zero reviewable files.
Its `include` list and its `rules` list do different jobs, and the difference is the trap: `include` is additive to file selection, while `rules` is first-match-wins and a matching custom pattern REPLACES the system group for those files rather than adding to it.
So a custom pattern must be checked for what it displaces before it is added: a `**/*.rs` entry silently swaps the whole system Rust group for whatever short rule it carries, and nothing reports the loss.
The current entries were chosen to displace nothing that was not carried forward (verified 2026-10-12 against `ocr` v1.12.13): `**/*.md`, the `Dockerfile*` patterns, `**/*.example`, and `**/CHANGELOG*.txt` replace only the generic `default` group, `.rs` and non-compose `.yaml` files keep their system groups untouched, and the compose pattern displaces the one-line system yaml-key spellcheck, which is folded into the compose rule's own `#### Spelling` section so no coverage is lost.

Path one: the task's own worker already runs pi on GLM-5.3.
Steer the block to that worker before its completion step.
At intake, paste the block into the brief's `{TASK}` area as a task-specific constraint.
Mid-task, write the filled block to `data/<task-id>/ocr-review.md` in the active home and steer through fail-closed `fm-send` with this single line: `Captain requests an OCR review round before completion: read and execute data/<task-id>/ocr-review.md`.

Path two: the task's worker runs on any other stack.
Firstmate spawns a separate reviewer worker, scout shape and report-only, in the same project on the reviewer profile resolved above.
The reviewer executes the block against the ship branch, replacing the block's HEAD targets with the ship branch so the preview reads `ocr delegate preview --from <base> --to <ship branch>`, and reports findings without changing code.
The reviewer reviews, the implementer fixes: firstmate relays the findings to the task worker, which fixes or rejects each one under the existing authority contract.

## Worker block

Paste this block verbatim, after replacing `{OCR_BASE}` and `{OCR_RULE}`:

```markdown
## OCR review round (captain-requested for this task)
The captain requested an OpenCodeReview delegation-mode review of this change before it leaves your branch.
Run it after your implementation is committed and BEFORE this task's completion step (before pushing a direct-PR branch, or before reporting a local-only ready branch).
OCR only selects files and supplies rules; YOU perform the review with your own reasoning.

1. Run `command -v ocr`. If it is missing, append
   `working: OCR review skipped (ocr not installed); continuing delivery`
   to the status file and continue the normal delivery steps. Do the same, after one retry,
   if any ocr command below exits nonzero or prints unparseable JSON (use the error's first line as the reason).
2. Run `ocr delegate preview --from {OCR_BASE} --to HEAD --rule {OCR_RULE} -f json`.
   If `reviewable_count` is 0, note "no reviewable files (<total_files> excluded)" for your done summary and continue the delivery steps.
3. Run `ocr delegate rule --rule {OCR_RULE} -f json <every path in reviewable_files>`.
4. For each reviewable file, run `git diff <merge_base from step 2>..HEAD -- <path>` and review the diff
   against that file's rule group AND this brief's task intent. Tag each finding with category (bug/security/performance/maintainability/test/style/documentation/other) and severity (critical/high/medium/low), plus path and line range in the new file.
   Track a checklist keyed by (path, status);
   every file must end reviewed, or skipped with a concrete reason. Do not stop at the first finding.
   Then ask the six standing questions below of the change as a whole, and put a `## Standing questions` table in your report with one row per question: its letter, what you checked (the sites walked, the tests broken, the greps run), and the result, either `clean` or the finding it produced.
   A row you cannot fill is a skipped file: give the concrete reason.
   a. Conditions. For every condition this diff adds or changes - a gate, guard, early return, query filter, or type predicate - read the code after it and name what that code assumes exists.
      Ask whether a state the condition now admits can lack it, and what another writer can change between the check and the act.
   b. Class, not instance. When the diff fixes a defect, state the defect as a predicate (the shape and the condition), search the whole repository for every site matching it, and account for each; the diff's own hunks are never the search scope.
      If `AGENTS.md` carries an `## Ask these of every change` section, ask each entry's test of this diff too, and cite the entry in any finding it yields.
      A finding that is the second or later instance of one predicate carries a `Class:` line naming the predicate and the earlier instances.
   c. Claims. Rebuild every enumeration the PR asserts - writers, callers, converted sites, "all N" - from the code before comparing it with the PR's table.
      A claim is checked against the thing it describes, never against the description.
   d. Tests. For every test the PR adds or says fails without the fix, break what it guards in a scratch copy and run it; the assertion that fails must be the new one.
      A test you could not make fail is a finding, not coverage.
      One mutation per claimed test, the tree restored after each.
   e. New paths. For any new migration, repair, retry, startup step, or background write, name what happens on the first input it cannot handle, whether a second run is a no-op, and whether one failure stops the rest.
   f. Classification. When the diff decides membership - is this a document, valid, complete, an admin - prefer a positive test for the class over an exclusion list.
      The list is a finding when a member it omits is constructible.
5. Triage findings:
   - Fix clear defects that are within this task's accepted scope now; commit the fixes as ordinary commits.
   - Reject false positives or out-of-scope findings, each with a one-line reason.
   - Critical/high findings are always reported; medium with context; low only if clearly valuable; discard likely false positives silently.
   - A finding that would expand the task's scope, or is destructive or security-sensitive, is not yours to decide:
     append `needs-decision [key=<slug>]: <one-line summary>` and stop, exactly as for any other decision.
6. If you committed fixes, repeat steps 2-4 once over the fixed files. Two rounds maximum;
   report any residual findings instead of looping.
7. If a fix round ran, append `working: OCR review: <n> findings, <m> fixed, <k> rejected; re-review clean`.
   Otherwise add a short clause to your normal done summary, e.g. `(OCR review clean)` or `(OCR: no reviewable files)`.
8. If this task opens a PR, include a `## Pre-PR OCR review` section in the PR description:
   files reviewed/skipped, findings by severity, and one line per fixed, rejected, and residual finding.
```

## Standing questions

Step 4's six lettered questions are the standing reviewer instructions, stated once for the manual round, the bot round (which pastes steps 2-4 of the block), and the successor service's parity.
They are capped at six.
Add one only by retiring one, or by citing a round report in which a real miss would not have been found by any existing question, and say which in the commit message.
Each question is one imperative with one named report row, so a skipped question is visible rather than silent.
Anything true of one pull request - the decision it answers, the record shape to construct, what the other reviewer found on the parent, a proportionality ruling - is round intent and belongs in the brief's `{OCR_INTENT}` section owned by `ocr-bot-review`, never here.

## Whole-project review

A captain ask like "review the whole project" is not workspace mode.
Workspace mode reviews uncommitted working-tree changes only, and fleet branches are committed before review, so a workspace preview would come back empty.
The ask takes the scan shape instead.
Run `ocr delegate rule --rule {OCR_RULE} -f json` over the project's source paths, batched, then review each full file against its rule group plus the project context.
The scan runs as a scout on the reviewer profile resolved above, and the coverage, failure-soft, and reporting contracts in the sections below apply unchanged.

## Reporting and translation

Worker status reporting is sparse and follows the shapes embedded in the worker block.
A skipped round (ocr missing or broken) always reports `working: OCR review skipped ({reason}); continuing delivery`, because the captain asked for the review and must hear it did not run.
A substantive fix round reports `working: OCR review: {n} findings, {m} fixed, {k} rejected; re-review clean`.
A clean round or an empty preview adds no extra status line: fold a short clause into the mode's existing done summary, such as `done: {summary} (OCR review clean)`, `done: PR {url} (OCR: 2 fixed, 1 rejected)`, or `done: ready in branch fm/<id> (OCR review clean)`.
When the task opens a PR, the PR description carries a `## Pre-PR OCR review` section with files reviewed and skipped, findings by severity, and one line per fixed, rejected, and residual finding.
For `local-only` there is no PR surface: the done clause carries the counts.
A separate-reviewer round and a whole-project scan report through these same shapes.
Translate for the captain per AGENTS.md section 9: the pre-PR review you asked for found N issues; the worker fixed X and set aside Y with reasons - details in the PR description.
Never expose raw status lines or OCR CLI terms such as "delegate preview" or "reviewable_count" to the captain.
Relay any skip to the captain in the next natural reply, since a requested-but-skipped review is captain-relevant.

## Failure policy

The round never blocks a delivery path: the selected delivery path, its automated gates, and the configured merge authority remain the authoritative rigor.
If `ocr` is not on PATH, the worker appends the skip status line and the delivery path continues unchanged.
If `ocr delegate preview` or `ocr delegate rule` exits nonzero or prints unparseable JSON, the worker retries once, then skips with the error's first line as the reason.
An empty preview (`reviewable_count: 0`) is not an error: note "no reviewable files (N excluded)" in the done clause and continue.
With `review-rule.json` passed, a doc-only, Dockerfile-only, example-config-only, or changelog-only diff is no longer empty, so an empty preview now means the diff genuinely holds nothing this reviewer selects - a `.md`, `Dockerfile*`, `*.example`, or `CHANGELOG*.txt` file coming back `unsupported_ext` means the rule file was not passed, and the round must be re-run with it.
An empty preview is still worth reporting rather than swallowing: name the excluded paths and their reasons, because a file type the project cares about landing in `unsupported_ext` is a gap in this rule file, not a clean change.
The worker runs at most two preview-to-review rounds; residual findings are reported, never looped.
A finding the worker cannot resolve is either rejected with a one-line reason or escalated through the existing `needs-decision` contract; it is never silently dropped.

## Closing pointer

`ocr delegate --help` and the upstream `skills/open-code-review-delegate/SKILL.md` own the CLI mechanics.
This skill owns only the firstmate procedure (one-owner rule).
