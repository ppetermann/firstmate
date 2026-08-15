---
name: ocr-delegate-review
description: >-
  Agent-only procedure for the captain-invoked OpenCodeReview (OCR) delegation-mode review round on a single task.
  Load only when the captain explicitly requests an OCR review for a specific task; never load or apply it as a default or automatic gate.
  Owns the worker instruction block, its intake and mid-task delivery, the failure-soft policy, and the reporting shape.
user-invocable: false
metadata:
  internal: true
---

# ocr-delegate-review

## Opt-in guard

This round is per task and per request: it runs only when the captain explicitly requested an OCR review round for that specific task.
Never apply it as a standing posture, a default gate, or an automatic step on any project or delivery mode.
Standing yolo authority is not a substitute for the explicit request.
If the captain ever asks to make OCR review standing or automatic for a project, do not silently comply.
Surface that this contradicts the recorded opt-in-only constraint and ask the captain to confirm changing the constraint itself.

## When it applies

The round runs after the implementation is committed and before the delivery mode's completion step.
That is before `/no-mistakes` starts, before a `direct-PR` push, and before the `local-only` ready report.
If the captain asks for the round after validation has started or the PR exists, report that the pre-PR window has passed instead of improvising a post-hoc variant.

## Intake delivery

Paste the worker block below into the brief's `{TASK}` area as a task-specific constraint.
Replace `{OCR_BASE}` with the project's default-branch ref, normally `origin/main`, the same base the ship branch was created from.
Optionally append captain-requested `--exclude` patterns to the preview and rule commands.

## Mid-task delivery

Write the filled worker block to `data/<task-id>/ocr-review.md` in the active home.
Then steer the worker through fail-closed `fm-send` with this single line: `Captain requests an OCR review round before completion: read and execute data/<task-id>/ocr-review.md`.

## Worker block

Paste this block verbatim, after replacing `{OCR_BASE}`:

```markdown
## OCR review round (captain-requested for this task)
The captain requested an OpenCodeReview delegation-mode review of this change before it leaves your branch.
Run it after your implementation is committed and BEFORE this task's completion step (before starting /no-mistakes, before pushing a direct-PR branch, or before reporting a local-only ready branch).
OCR only selects files and supplies rules; YOU perform the review with your own reasoning.

1. Run `command -v ocr`. If it is missing, append
   `working: OCR review skipped (ocr not installed); continuing delivery`
   to the status file and continue the normal delivery steps. Do the same, after one retry,
   if any ocr command below exits nonzero or prints unparseable JSON (use the error's first line as the reason).
2. Run `ocr delegate preview --from {OCR_BASE} --to HEAD -f json`.
   If `reviewable_count` is 0, note "no reviewable files (<total_files> excluded)" for your done summary and continue the delivery steps.
3. Run `ocr delegate rule -f json <every path in reviewable_files>`.
4. For each reviewable file, run `git diff <merge_base from step 2>..HEAD -- <path>` and review the diff
   against that file's rule group AND this brief's task intent. Tag each finding with category (bug/security/performance/maintainability/test/style/documentation/other) and severity (critical/high/medium/low), plus path and line range in the new file.
   Track a checklist keyed by (path, status);
   every file must end reviewed, or skipped with a concrete reason. Do not stop at the first finding.
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

## Reporting and translation

Worker status reporting is sparse and follows the shapes embedded in the worker block.
A skipped round (ocr missing or broken) always reports `working: OCR review skipped ({reason}); continuing delivery`, because the captain asked for the review and must hear it did not run.
A substantive fix round reports `working: OCR review: {n} findings, {m} fixed, {k} rejected; re-review clean`.
A clean round or an empty preview adds no extra status line: fold a short clause into the mode's existing done summary, such as `done: {summary} (OCR review clean)`, `done: PR {url} (OCR: 2 fixed, 1 rejected)`, or `done: ready in branch fm/<id> (OCR review clean)`.
When the task opens a PR, the PR description carries a `## Pre-PR OCR review` section with files reviewed and skipped, findings by severity, and one line per fixed, rejected, and residual finding.
For `local-only` there is no PR surface: the done clause carries the counts.
Translate for the captain per AGENTS.md section 9: the pre-PR review you asked for found N issues; the worker fixed X and set aside Y with reasons - details in the PR description.
Never expose raw status lines or OCR CLI terms such as "delegate preview" or "reviewable_count" to the captain.
Relay any skip to the captain in the next natural reply, since a requested-but-skipped review is captain-relevant.

## Failure policy

The round never blocks a delivery path: the selected delivery path, its automated gates, and the configured merge authority remain the authoritative rigor.
If `ocr` is not on PATH, the worker appends the skip status line and the delivery path continues unchanged.
If `ocr delegate preview` or `ocr delegate rule` exits nonzero or prints unparseable JSON, the worker retries once, then skips with the error's first line as the reason.
An empty preview (`reviewable_count: 0`, common for doc-only diffs) is not an error: note "no reviewable files (N excluded)" in the done clause and continue.
The worker runs at most two preview-to-review rounds; residual findings are reported, never looped.
A finding the worker cannot resolve is either rejected with a one-line reason or escalated through the existing `needs-decision` contract; it is never silently dropped.

## Closing pointer

`ocr delegate --help` and the upstream `skills/open-code-review-delegate/SKILL.md` own the CLI mechanics.
This skill owns only the firstmate procedure (one-owner rule).
