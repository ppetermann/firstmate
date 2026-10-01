---
name: validation-supervision
description: Load when a ship enters validation - its local gate, the flip, its one CI run, or its review round - including a mid-task requirement change or a review finding, and before deciding or answering any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

Validation is the flow's, and `fleet-delivery-flow` owns it: the worker runs the local gate on the exact head it pushes, firstmate rebases and flips at the landing turn, and the flip head gets one CI run and one review round.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker replaces the obsolete work from the correct pre-invalidation base rather than building on top of the obsolete head, keeping the superseded work out of what gets validated and shipped, and validates exactly once against that final head.

Review findings are the worker's to address in one push per round, and firstmate re-flips for the next round.
A fix round answers the finding's PREDICATE, not only the site it names: state the defect as a predicate, account for every site in the repository matching it, and where one fact has several carriers make one the carrier rather than correcting each copy - the same rule for wording, comments and documentation as for code (captain, 2026-09-09; `ocr-bot-review` owns the fix-round brief wording).
A finding that would expand the accepted contract, or is destructive, irreversible, or security-sensitive, returns as `needs-decision`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, the affected findings, the action, and instructions where needed, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge a worker by [`bin/fm-crew-state.sh`](../../../bin/fm-crew-state.sh), whose header owns outcome mappings, not by shell liveness or the last status event.
The worker reports the PR when its draft PR is open rather than waiting for the flip or the merge to finish.
