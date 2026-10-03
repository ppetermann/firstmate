# maia notifications

A firstmate home can send keyed notifications to the `maia-firstmate` plugin running in a maia instance.
Each notification carries a key, such as `decision` or `merged`, and a few variables, such as the project and the PR URL.
The plugin picks the prompt templates written for that key in its admin panel, fills in the variables, and hands the result to maia.
The plugin's own repository owns the templates, the endpoint, and the panel; this page covers only the firstmate side.

## Turning it on and off

Create `config/maia-notify` in a firstmate home to turn notifications on, and delete it to turn them off.
The file is local, gitignored, per home, and not inherited by second mate homes.
Keep it at mode `0600`, because it holds the plugin token; a looser mode is reported in the log.
While the file is absent, each hook performs one file-existence test and nothing else.

The file holds `field=value` lines; blank lines and other lines are ignored, and the last line for a field wins.

| Field    | Meaning |
| -------- | ------- |
| `url`    | The plugin endpoint, for example `http://maia.lan:31337/pub/plugins/firstmate/notify`. Required. |
| `token`  | The token generated in the plugin's admin panel. Required. |
| `events` | Optional space- or comma-separated list of the keys to send. Absent: `decision merge-ready merged deployed failed`. |
| `ttl`    | Optional seconds a notification may wait for delivery before it is dropped. Absent: `900`. |

```text
url=http://maia.lan:31337/pub/plugins/firstmate/notify
token=mfm_...
events=decision merge-ready merged deployed failed
ttl=900
```

`merged`, `failed`, `blocked`, and `pr-ready` come from the [fleet activity ledger](fleet-ledger.md), so they also need `config/fleet-ledger`.

## Keys

| Key           | Sent when | Variables | Default |
| ------------- | --------- | --------- | ------- |
| `decision`    | A task is newly held for the captain. A repeated hold and an `--until` deferral send nothing. | `project`, `task`, `title`, `question` | on |
| `merge-ready` | Firstmate finds all six merge-ready legs passing (`fleet-delivery-flow` checklist D). | `project`, `task`, `pr_url`, `pr_number`, `title` | on |
| `merged`      | The ledger records a PR merge or a local-only landing. | `project`, `task`, `pr_url`, `pr_number`, `via` | on |
| `deployed`    | Firstmate verifies a project's release live (`fleet-delivery-flow` checklist F). | `project`, `version`, `url` | on |
| `failed`      | The ledger records a `failed` status line. | `project`, `task`, `text` | on |
| `blocked`     | The ledger records a `blocked` status line. | `project`, `task`, `text` | off |
| `pr-ready`    | The ledger records a PR registered for review. | `project`, `task`, `pr_url` | off |

`project` is the project directory name.
Each value is cut to 200 characters; the plugin cleans and fences every value again before it reaches maia.
Every notification carries an id the plugin uses to drop repeats: `decision:<task>:<hold time>`, `merge-ready:<PR URL>:<head sha>`, `merged:<PR URL>` or `merged:local:<task>`, `deployed:<project>:<version>`, and `<state>:<task>:<time>` for status lines.

A key can also be sent by hand: `bin/fm-maia-notify.sh send <key> [--id <id>] name=value...`.
Any key listed in `events` is sent, so a custom key needs only a template in the panel and an `events` entry here.

## Delivery

Sending only writes a file to `state/maia-notify/spool/` and starts delivery in the background, so a slow or unreachable maia never delays firstmate.
Each delivery attempt gives up after 5 seconds.
The supervision monitor retries what is left on every poll.
A notification that is still undelivered after `ttl` seconds is dropped, because a late "deployed" announcement is worse than none.
The plugin's refusal of a notification, such as a wrong token or an unknown key, drops it; a rate-limit answer or a server error keeps it for the next attempt.
At most 200 notifications wait in the spool; the oldest is dropped to make room.

The token is added only at delivery time and reaches the HTTP client on its standard input.
It never appears in a command line, in a spool file or its name, or in the log.

`state/maia-notify/log` records one line per outcome with the key, the id, and the HTTP status, and never a variable's value.
The ledger position is kept in `state/maia-notify/follow-offset`; when it is absent, reading starts at the end of the ledger, so earlier history is not sent.

`bin/fm-maia-notify.sh`'s header owns the exact mechanics, and `tests/fm-maia-notify.test.sh` covers them.
