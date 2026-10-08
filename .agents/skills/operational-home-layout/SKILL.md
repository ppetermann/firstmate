---
name: operational-home-layout
description: Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
user-invocable: false
metadata:
  internal: true
---

# Operational home layout

This tree is the navigation view; [`docs/configuration.md`](../../../docs/configuration.md) "Operational home layout and state" is the single owner of the full `config/` and `state/` inventory and every schema.

```
AGENTS.md            the supervisor contract (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
.claude/mods/        Claude Code mods (function-hooks plugins), committed; Calm's module may load through CLAUDE_CODE_ENABLE_FUNCTION_HOOKS or tengu_plugin_hooks_modules, but activates only when CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is exactly "1" and is otherwise a complete no-op (docs/calm.md)
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional Relay pairing token (presence-gates section 14), mail-plane credentials (schema: docs/configuration.md "Mail plane"), and typed dispatch resolution keys TYPESAFE_API_KEY (direct) and FM_JEV_OPENROUTER_API_KEY (either presence-gates the typed dispatch resolution in section 4 and selects its transport; TYPESAFE_API_KEY wins when both are present; docs/configuration.md "Typed dispatch resolution"); LOCAL, gitignored
config/              local operating choices; docs/configuration.md owns every file and its schema
  worker-tmp-root    optional one-line real-disk base for per-task temp roots; inherited by secondmate homes; docs/configuration.md "Worker temp root"
  ocr-bot/           optional OCR review bot opt-in directory; not inherited; docs/configuration.md "OCR review bot"
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
  pipeline-spend.jsonl  optional per-task no-mistakes pipeline spend, written only when config/pipeline-spend is present; bin/fm-pipeline-spend.sh owns the schema
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime records and signals; gitignored
  <id>.status        append-only wake events, not current-state truth; bin/fm-classify-lib.sh owns their syntax
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  state/ (everything else)  watcher, poll, Relay, away-mode, and recovery machinery owned by its producing script - never touch; full inventory: docs/configuration.md
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
.no-mistakes/        local validation state and evidence; gitignored
```
