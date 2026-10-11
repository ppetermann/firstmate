# Worker-pool disk housekeeping

Rust worker copies are the largest thing Firstmate keeps on disk.
A Treehouse pool copy keeps its ignored `target/` when it goes back to the pool, so the next task in that copy starts warm, but most of that directory is incremental caches and linked test executables that no later task reuses.
Three pieces keep that in check: a trim when a copy returns to the pool, a nightly sweep of idle copies, and a free-space check before a Rust dispatch.
[`bin/fm-pool-disk-lib.sh`](../bin/fm-pool-disk-lib.sh) owns what each piece removes or measures and when a copy counts as idle.

## Trim when a copy returns to the pool

`bin/fm-teardown.sh` trims a ship or scout copy just before it hands the copy back to the pool, after every landed-work check has passed.
It deletes each `target/*/incremental/` directory and the linked test and binary executables in `target/*/deps/`, and keeps the compiled libraries, so the next task in that copy relinks and recompiles the project's own crates once but does not rebuild its dependencies.
Only the copy's own top-level `target/` is touched, only when the project clone has a `Cargo.toml` and git ignores `target/`, and never the project clone itself.
Files a container build left root-owned cannot be deleted by the fleet user; teardown prints how many survived and a root-container command that removes them, and finishes its cleanup anyway.

To apply the same trim to an idle copy by hand, or to see what it would remove:

```sh
bin/fm-pool-sweep.sh trim --dry-run ~/.treehouse/<pool>/<slot>/<repo>
bin/fm-pool-sweep.sh trim ~/.treehouse/<pool>/<slot>/<repo>
```

## Nightly sweep of idle copies

`bin/fm-pool-sweep.sh` walks every pool under `~/.treehouse` (or `$FM_TREEHOUSE_POOL_ROOT`) and, for each idle Rust copy, caps its `target/` at a size (default 15GB, `--max-size`) and then removes artifacts no build touched for two days (`--age-days`), through `cargo-sweep`.
A copy is idle only when Treehouse reports it available with no lease, no Firstmate slot-owner claim sits beside it, and no task record in any local Firstmate home names it.
Each copy is checked again and swept while the sweep holds that project's Treehouse lock, so a Firstmate spawn cannot take the copy mid-sweep; a spawn that arrives during that window refuses and can simply be retried, which is why the sweep belongs in a quiet hour.
`--dry-run` reports what would be removed and removes nothing.
The sweep needs `cargo-sweep`, `treehouse`, `jq`, and `git` on its `PATH`, and `FM_HOME` naming the root Firstmate home so it finds the right locks and task records.

A systemd user service and timer that run it nightly, replacing a plain `cargo-sweep --time 7` unit:

```ini
# ~/.config/systemd/user/fm-pool-sweep.service
[Unit]
Description=Trim Rust build output in idle Firstmate worker-pool copies

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
Environment=FM_HOME=%h/agents/firstmate
Environment=PATH=%h/.local/bin:%h/.cargo/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/agents/firstmate/bin/fm-pool-sweep.sh --max-size 15GB --age-days 2
```

```ini
# ~/.config/systemd/user/fm-pool-sweep.timer
[Unit]
Description=Nightly trim of idle Firstmate worker-pool copies

[Timer]
OnCalendar=*-*-* 04:30
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
```

Adjust `FM_HOME` and the `ExecStart` path to where the root Firstmate home lives.
Install with `systemctl --user daemon-reload && systemctl --user enable --now fm-pool-sweep.timer`, after disabling any older pool sweep timer, and run `systemctl --user start fm-pool-sweep.service` once to read its first report with `journalctl --user -u fm-pool-sweep.service`.

## Free-space check before a Rust dispatch

Before `bin/fm-spawn.sh` launches a fresh ship or scout for a project whose clone has a `Cargo.toml` at its top, it reads free space on the filesystem holding the Treehouse pool (the project clone for Orca).
Below 20% free it prints a warning for Firstmate to pass on to the captain; below 10% free it refuses before anything is created, naming the free space, and the backlog item stays queued.
`--allow-low-disk` launches anyway and is for the captain's explicit word only.
If free space cannot be read, the spawn warns and launches.
