---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect the authoritative `data/secondmates.md` routing table and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's authoritative secondmate routing rules; if an existing scope owns that domain, route the new-project operation or work there instead of creating or registering a duplicate main-home clone.
Absence from the main `data/projects.md` registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery posture, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

The registry records the project's standing posture, which is the captain's default for the work rather than any task's answer; `AGENTS.md` section 7 owns how each task's concrete mode and yolo are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `direct-PR` has the worker run the local ladder, push once, and open a DRAFT PR; firstmate flips it at the landing turn, and the flip head gets one CI run and one review round.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.

`direct-PR` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch.
A legacy entry with no bracket also reads as `direct-PR`.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `direct-PR` project must have an `origin` remote.
A `local-only` project may have no remote.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `direct-PR`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally and add the registry entry.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

Creation is not finished until the repository holds at least one commit, so lay an empty root commit on whichever path created it.
A repository with no commit has an unborn `HEAD` and nothing `git worktree add` can check out, so no isolation backend can cut a task worktree from it and no worker can be dispatched into the project at all.
That also blocks creation's own last step below, because the committed `## Delivery` section is written by a crewmate working in a task worktree of that very project.
An empty commit is enough and leaves a worker nothing to reconcile.
An `origin`-backed creation needs it too: a newly created remote repository is empty and clones to the same unborn `HEAD`.
`bin/fm-spawn.sh` refuses a spawn into a project with no commits and names that cause, so a project still missing one for any other reason is reported as such instead of as a worktree that never appeared.

## Put the project on the delivery flow

Registration is not finished until the project's `AGENTS.md` carries a committed `## Delivery` section (captain, 2026-09-04: "you registered this project, so you didn't add it, please make sure this doesn't happen again").
Resolve it at add or create intake, in the same breath as the registry entry - not as an afterthought.
`fleet-delivery-flow` owns the contract; the section is its worker-facing half: the project's local ladder commands, trigger map, draft and flip mechanics, review setup, release tail, and batching triggers.

Firstmate never writes a project's `AGENTS.md`. Route it through a crewmate on that project's own delivery path using `bin/fm-ensure-agents-md.sh`, exactly as `AGENTS.md` section 6 requires.
Point that section at the shared contract rather than copying it, so one flow does not become one copy per project that drifts.

A project with no such section is not yet on the flow: say so plainly rather than assuming a worker there will infer a contract that is written nowhere it reads.
Every project registered between the flow's adoption and 2026-09-04 was missing one, which is how two pull requests on one repo ran outside the flow the day it mattered.
Do not commit the local configuration a tool generated merely because you ran that tool; the root commit above is a required step of creation, not an initialization side effect.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
