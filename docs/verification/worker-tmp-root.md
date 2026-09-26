# Worker temp root verification

Evidence that worker agents follow `TMPDIR`, which is what makes the optional `config/worker-tmp-root` keep every worker's temporary files inside its own per-task root.
The setting is documented in [`../configuration.md`](../configuration.md) ("Worker temp root") and its contract is owned by [`../../bin/fm-task-tmp-lib.sh`](../../bin/fm-task-tmp-lib.sh); this page records evidence only.

Date: 2026-09-26.
Host: Linux, `/tmp` a memory-backed tmpfs, the base on the home directory's disk.
Versions: Claude Code 2.1.283, opencode 1.18.32.

## Claude Code

On Linux Claude Code resolves its per-uid temp directory from `CLAUDE_CODE_TMPDIR`, then `TMPDIR`, `TMP`, and `TEMP`, and falls back to `/tmp` (it ignores `TMPDIR` on macOS).
Setting `TMPDIR` alone is enough; `CLAUDE_CODE_TMPDIR` is not needed.

An interactive session started under `env -i ... TMPDIR=<dir> TMP=<dir> TEMP=<dir> claude --model haiku` and asked to write into its scratchpad and run `mktemp` produced:

```console
$ find <dir> -maxdepth 5
<dir>/cc-socks/<pid>.sock
<dir>/claude-1000/<project>/<session>/tasks
<dir>/claude-1000/<project>/<session>/scratchpad
<dir>/claude-1000/<project>/<session>/scratchpad/probe.txt
<dir>/tmp.1WnHyF7jbO
```

The socket directory lands under `TMPDIR` only when `XDG_RUNTIME_DIR` is unset; a normal login session keeps it under `XDG_RUNTIME_DIR`.

## opencode

opencode's own temp directory, the native libraries it extracts at start (5 to 14 MB each, previously accumulating as hidden `.so` files in `/tmp`), and its compile cache all follow `TMPDIR`:

```console
$ TMPDIR=<dir> opencode debug paths | grep tmp
tmp        <dir>/opencode
$ find <dir> -maxdepth 2    # after starting the opencode TUI under TMPDIR=<dir>
<dir>/.bcd9f57eb59ff67d-00000001.so
<dir>/.9adbfdfbfee9ffb7-00000000.so
<dir>/node-compile-cache/v24.19.0-x64-cf738c9d-1000
<dir>/opencode
```

No new `.so` file appeared in `/tmp` during that start.

## Real spawn and teardown

A scratch home with `config/worker-tmp-root` set to `~/.cache/fm-wtr-live-probe` spawned a real Claude worker (`bin/fm-spawn.sh wtrlive <project> --mode local-only --yolo off --harness claude --model haiku`) on a private tmux server.
The worker wrote into its scratchpad, ran `mktemp`, and printed Python's `tempfile.gettempdir()`:

```console
$ find ~/.cache/fm-wtr-live-probe -maxdepth 7
.../fm-wtrlive/.fm-home
.../fm-wtrlive/gotmp
.../fm-wtrlive/tmp/tmp.dVJ05ETTEf
.../fm-wtrlive/tmp/claude-1000/<project>/<session>/tasks
.../fm-wtrlive/tmp/claude-1000/<project>/<session>/scratchpad/probe.txt
worker: python3 tempfile.gettempdir() -> /home/<user>/.cache/fm-wtr-live-probe/fm-wtrlive/tmp
```

No new entry appeared under `/tmp/claude-1000/`, and the only new `/tmp` entry of the spawn was its own staged launch namespace.
`bin/fm-teardown.sh wtrlive` then left `~/.cache/fm-wtr-live-probe/` empty and removed the launch namespace.

## Regression suites

```console
$ bash tests/fm-worker-tmp-root.test.sh | grep -c '^ok'
8
$ bash tests/fm-gotmp.test.sh | grep -c '^ok'
6
```

`tests/fm-worker-tmp-root.test.sh` executes the launch a real `bin/fm-spawn.sh` emitted, with the harness replaced by a probe, and covers the absent-config default, the relocated private root and its exported variables with and without the launch allowlist, the `~/` form, secondmate launch and inheritance, refusal of unsafe or foreign roots, unsafe bases and malformed values, the brief's cache rule, and the leftover-root report.
`tests/fm-gotmp.test.sh` covers teardown of a relocated root, the plain report of what it could not remove, and refusal to remove another home's or a misnamed root.
Rerun both after a Claude Code or opencode upgrade, and repeat the Claude Code and opencode probes above when either vendor changes its temp handling.
