Part of the harness-adapters skill; load per its "Per-harness facts" table. Verification headers are authoritative here, not in SKILL.md.

## claude (VERIFIED; busy-state hooks live-verified 2026-07-28 on Claude Code 2.1.220)

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks: `UserPromptSubmit` opens a turn, while `Stop`, `StopFailure`, and `SessionEnd` close it; because Claude fires no hook for a manual interrupt, `bin/fm-control.sh interrupt` reports only delivered keys and the verified endpoint or live agent, publishes no idle event, makes no cancellation claim, and leaves adapter-observed state unchanged, so a mid-turn worker typically remains busy via `claude-hook`. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree may show a project-trust confirmation ("Is this a project you created or one you trust?" with "Yes, I trust this folder" preselected, accepted by Enter; verified on Claude Code 2.1.231).
`bin/fm-spawn.sh` gates every claude launch against this dialog automatically, and no manual peek or Enter is needed for a crewmate, scout, or secondmate.
Readiness is the gate's PRIMARY signal: its real question is "did the agent start processing the brief?", not "is the prompt on screen?".
For a crewmate or scout, processing is confirmed through the busy-state hook protocol (claude's `UserPromptSubmit` advancing the seeded record past the `fm-spawn` entry), a protocol fact rather than a rendered string, so that path is version-drift-safe.
Trust-prompt recognition is only a secondary aid that clears a known blocker so processing can start: it reads more than one independent rendered fragment and lets any one carry the detection, so no single vendor string is load-bearing.
If a future rewording matches no fragment, the prompt is never cleared, the hook never fires, and the gate fails loudly ("did not confirm brief processing") instead of printing success; that is the version-drift protection, and `tests/fm-claude-trust-gate.test.sh` covers it alongside the cleared, fast-path, unclearable, and no-hammer cases.
The gate is bounded and tears nothing down: on failure it reports clearly and leaves the endpoint and task record for firstmate to act on.
A claude secondmate has no per-task hooks, so its path clears the dialog if present and waits for the pane to settle clear of it; that removes the known trust blocker but cannot positively confirm processing the way the crewmate hook can, and closing that gap would need a positive secondmate readiness signal in a later pass.
The equivalent trust dialogs for codex and pi (`references/codex.md` and `references/pi.md`) are not yet gated and still require a manual accept on first launch.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on every styled reader (tmux, herdr, and Zellij).
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md` "Composer and injection safety", with active captures in `docs/verification/runtime-backends.md`.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, Claude Code 2.1.219).**
This is separate from the per-task crewmate turn-end hook above (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.
