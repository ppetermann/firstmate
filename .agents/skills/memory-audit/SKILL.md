---
name: memory-audit
description: >-
  Captain-invoked curation pass over the home's always-loaded memory files. Hunts four
  things: entries whose premise died (outdated), rules whose caution outlived their
  evidence (overcautious), conditional knowledge paying rent in every session (moveable
  to a reference owner), and procedures stored as facts (skill candidates). Use when the
  captain asks what is outdated or prunable in memory, whether anything can move to a
  reference or skill, or says to audit or curate memory. The /stow skill owns tiers,
  markers, decay clocks, the archive helper, and the budget-driven session-end pass;
  this skill owns only the on-demand audit judgments and reuses stow's mechanics.
user-invocable: false
metadata:
  internal: true
---

# memory-audit

An on-demand audit is judgment work the captain commissions; it never replaces the /stow
pass and never writes markers, archives, or destinations except through the owners below.

## Scope

- Read `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` completely.
- Verdict every entry: keep, rewrite, archive, or move - with a one-line reason each.
- Execute only through existing owners: `bin/fm-stow-plan.sh archive` provenance (or a
  hand-written equivalent block in `data/memory-archive.md` when the helper cannot parse
  the entry's format), stow's local-skill destination rules with `check-destination`,
  and `bin/fm-startup-memory-budget.sh report` before and after.
- A captain answer surfacing mid-audit is recorded at answer time, not deferred.

## The four hunts

1. **Outdated premise.** Not date-staleness (stow's clocks own that): ask whether the
   world the entry describes still exists. Superseded conclusions (measurement history
   whose practice became standing routine), dead tools, renamed paths, resolved
   conditions. Test: does any current decision still read this fact to fire?
2. **Overcaution.** A rule whose restriction outlived its incident. Test: knowing what
   we know now, would we write this rule today - and at what strength? If the answer is
   "yes, but weaker", rewrite it weaker in place. Evidence for the weakening must be
   nameable, not vibes.
3. **Moveable scope.** The nameable-context test: a session that never touches the
   trigger loses nothing by not having the fact loaded.
   The captain-endorsed placement criterion (2026-08-28): a need that announces itself
   by domain belongs to a local skill; one that can ambush from outside its domain
   stays in memory.
   Move to a reference owner per stow's destination rules (local untracked skill via
   the repository-local exclude file, an existing JIT note, or a project surface
   through its delivery path). Leave no
   pointer by default; at most one line when the cost of a missed load is a known trap.
4. **Procedure stored as fact.** Memory entries that are really HOW-TO knowledge -
   steps, checklists, brief-building rules - belong in a skill with a precise trigger,
   not in always-loaded memory. Convert the same way as hunt 3; the skill's description
   line is the whole trigger. A fact that fires at nearly every session stays memory
   even if it reads procedural.

## Keep-at-attention floor

Never move safety-relevant diagnostics or facts that fire in any session with live work
(worker-state reads, output-truncation discipline, quota/dispatch arithmetic), and never
archive a unique current fact - archive is a move with provenance, not deletion.
Captain-preference entries in `data/captain.md` change only through inspect-then-update
or the captain's own words; the audit may propose, not rewrite, his rulings.

## Receipt

Report per entry: verdict, reason, and for moves the live destination and actual budget
relief; totals before and after; anything left deliberately with the judgment it waits
on. The session is reset-safe only when every disposition is executed or explicitly
deferred with a reason.
