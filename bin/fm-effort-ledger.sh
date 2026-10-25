#!/usr/bin/env bash
# fm-effort-ledger.sh - keep each task's planned and actual agent wall-clock
# time in Firstmate's own records, and summarize it for planners.
#
# Usage:
#   fm-effort-ledger.sh record <task-id>
#   fm-effort-ledger.sh stats [--kind <kind>] [--project <name>]
#   fm-effort-ledger.sh backfill
#
# record appends one JSON object on one line of data/effort-ledger.jsonl, at
# most once per task incarnation (task id plus the record's spawn_gen), so a
# retried cleanup never counts a task twice. bin/fm-teardown.sh calls it for
# every ship and scout task before it removes state/<id>.meta, and never lets a
# failed record stop the cleanup. The ledger is private and gitignored with the
# rest of data/.
#
# stats prints, per kind, per project, and per model, the count, median, and
# p90 of dispatch->ready and dispatch->landed in agent wall-clock minutes, then
# the actual/estimate ratio (median, p90) for records that carry an estimate.
# --kind and --project keep only matching records. With no matching records it
# prints `effort ledger: no records yet` and exits 0. Planners read this output
# to size work; bin/fm-brief.sh's scout scaffold points them here.
#
# backfill appends what the markdown backlog still knows about finished tasks,
# read from data/backlog.md's Done section and data/done-archive.md: an entry
# whose note carries a `dispatch-facts at=` stamp becomes a record when its
# ready time is recoverable - for an entry with a pull request URL on its title
# line, the forge's createdAt and mergedAt; for a scout, the mtime of
# data/<id>/report.md. Entries already in the ledger are skipped, so backfill
# is safe to repeat. Backfilled records carry backfill=true and no spawn_gen,
# harness, or model. A non-markdown backlog has nothing to backfill.
#
# Estimate. A planner's estimate is recorded as one `estimate=<N>m` token in
# the task's backlog note, in agent wall-clock minutes from dispatch to draft
# PR plus one CI/review round. record reads it through bin/fm-tasks-axi.sh show;
# a missing token, or a backlog that cannot be read, records estimate_min=null.
#
# Record schema (this header is its one owner). One JSON object:
#   task, spawn_gen        task id and the incarnation recorded in its meta
#   recorded_at            UTC time the record was built
#   project, kind, mode    project directory name, task kind, delivery mode
#   harness, model, effort as recorded in the task's meta
#   dispatched_at          the earlier of the spawn_gen stamp and the first
#                          [at=] stamp in state/<id>.status, so a relaunch
#                          does not restart the clock
#   ready_at, ready_source when the deliverable was first ready: "pr-opened"
#                          (the recorded pr='s forge createdAt), "done-status"
#                          (the first done line's [at=] stamp), or "report"
#                          (data/<id>/report.md's mtime for a scout); null when
#                          none is recoverable
#   landed_at, landed_source  "merged" (the forge's mergedAt) or "teardown"
#                          (the time of this record)
#   estimate_min           the planner's estimate in minutes, or null
#   backfill               true only on records written by backfill
# Times are UTC ISO-8601 strings. Forge reads use `gh pr view`, bounded by 20
# seconds each; an unreadable forge leaves the time to the next source.
#
# Exit status: 0 when a record was written or already present, or stats or
# backfill completed; 1 when the task record is missing, names a secondmate, or
# the ledger could not be read or written; 2 for bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TIMEOUT=20
LEDGER="$DATA/effort-ledger.jsonl"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-effort-ledger: %s\n' "$*" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# Prints "<createdAt> <mergedAt>" for a PR URL, either field "-" when unknown.
pr_times() {  # <url>
  local out
  command -v gh >/dev/null 2>&1 || { echo "- -"; return 0; }
  out=$(fm_run_timed "$TIMEOUT" gh pr view "$1" --json createdAt,mergedAt \
    --jq '"\(.createdAt // "-") \(.mergedAt // "-")"' 2>/dev/null) || out=
  case "$out" in
    *' '*) printf '%s\n' "$out" ;;
    *) echo "- -" ;;
  esac
}

# The one shared appender: reads JSON records from a file and appends each one
# whose (task, spawn_gen) - or, for a backfilled record, whose task - is not
# already in the ledger, under an exclusive lock.
append_records() {  # <records-file>
  python3 - "$LEDGER" "$1" <<'PY'
import fcntl
import json
import os
import sys

ledger = sys.argv[1]
records = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
try:
    fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        content = f.read()
        seen, tasks = set(), set()
        for existing in content.splitlines():
            try:
                row = json.loads(existing)
            except ValueError:
                continue
            if isinstance(row, dict):
                seen.add((row.get("task"), row.get("spawn_gen")))
                tasks.add(row.get("task"))
        out = []
        for rec in records:
            if rec.get("backfill") and rec["task"] in tasks:
                print("already recorded %s" % rec["task"])
                continue
            key = (rec["task"], rec.get("spawn_gen"))
            if key in seen:
                print("already recorded %s %s" % (rec["task"], rec.get("spawn_gen") or "-"))
                continue
            seen.add(key)
            tasks.add(rec["task"])
            out.append(json.dumps(rec, separators=(",", ":")))
            print("recorded %s %s" % (rec["task"], rec.get("spawn_gen") or "-"))
        if out:
            f.write(("\n" if content and not content.endswith("\n") else "") + "\n".join(out) + "\n")
            f.flush()
            os.fsync(f.fileno())
except OSError as err:
    sys.stderr.write("fm-effort-ledger: cannot write %s: %s\n" % (ledger, err))
    sys.exit(1)
PY
}

cmd_record() {
  local id=$1 meta status kind pr times created merged estimate report_mtime
  fm_task_id_path_safe "$id" || { echo "fm-effort-ledger: invalid task id" >&2; exit 2; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "no task record for $id"
  meta_value() {  # <key>
    grep "^$1=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
  }
  kind=$(meta_value kind)
  [ "$kind" != secondmate ] || fail "$id is a secondmate, not a task"
  [ -d "$DATA" ] || fail "data directory $DATA is missing"
  status="$STATE/$id.status"
  [ -f "$status" ] || status=/dev/null
  pr=$(meta_value pr)
  created=- merged=-
  if [ -n "$pr" ]; then
    times=$(pr_times "$pr")
    created=${times% *} merged=${times#* }
  fi
  estimate=$(fm_run_timed "$TIMEOUT" env FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null \
    | grep -oE '(^|[^[:alnum:]_-])estimate=[0-9]+m' | head -1 | sed 's/.*estimate=//; s/m$//') || estimate=
  report_mtime=
  if [ "$kind" = scout ] && [ -f "$DATA/$id/report.md" ]; then
    report_mtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$DATA/$id/report.md" 2>/dev/null) || report_mtime=
  fi
  python3 - "$id" "$(meta_value spawn_gen)" "$(basename "$(meta_value project)")" "$kind" \
      "$(meta_value mode)" "$(meta_value harness)" "$(meta_value model)" "$(meta_value effort)" \
      "$created" "$merged" "$estimate" "$report_mtime" "$status" <<'PY' >"$TMPFILE" || fail "could not build the effort record for $id"
import json
import re
import sys
import time

(task, spawn_gen, project, kind, mode, harness, model, effort,
 created, merged, estimate, report_mtime, status) = sys.argv[1:]


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


stamps, done = [], None
for line in open(status, encoding="utf-8", errors="replace"):
    m = re.search(r"\[at=([0-9]+)\]", line)
    if not m:
        continue
    stamps.append(int(m.group(1)))
    if done is None and line.startswith("done "):
        done = int(m.group(1))
starts = stamps[:1]
m = re.match(r"s([0-9]+)\.", spawn_gen)
if m:
    starts.append(int(m.group(1)))
now = time.time()
if created != "-":
    ready, ready_source = created, "pr-opened"
elif done is not None:
    ready, ready_source = utc(done), "done-status"
elif report_mtime:
    ready, ready_source = utc(int(report_mtime)), "report"
else:
    ready, ready_source = None, None
landed, landed_source = (merged, "merged") if merged != "-" else (utc(now), "teardown")
print(json.dumps({
    "task": task,
    "spawn_gen": spawn_gen or None,
    "recorded_at": utc(now),
    "project": project or None,
    "kind": kind or "ship",
    "mode": mode or None,
    "harness": harness or None,
    "model": model or None,
    "effort": effort or None,
    "dispatched_at": utc(min(starts)) if starts else None,
    "ready_at": ready,
    "ready_source": ready_source,
    "landed_at": landed,
    "landed_source": landed_source,
    "estimate_min": int(estimate) if estimate else None,
    "backfill": False,
}))
PY
  append_records "$TMPFILE"
}

cmd_backfill() {
  local sources=() src task kind url times report mtime
  [ -d "$DATA" ] || fail "data directory $DATA is missing"
  for src in "$DATA/backlog.md" "$DATA/done-archive.md"; do
    [ -f "$src" ] && sources+=("$src")
  done
  [ "${#sources[@]}" -gt 0 ] || { echo "effort ledger: no markdown backlog to backfill"; return 0; }
  # One tab-separated line per Done entry: task, project, kind, dispatched_at,
  # first PR URL on the title line, estimate.
  python3 - "${sources[@]}" <<'PY' >"$TMPFILE.entries" || fail "could not read the markdown backlog"
import re
import sys

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8", errors="replace").read()
    if path.endswith("backlog.md"):
        m = re.search(r"^## Done$(.*?)(?=^## |\Z)", text, re.M | re.S)
        text = m.group(1) if m else ""
    for block in re.split(r"(?m)^(?=- \[x\] )", text):
        if not block.startswith("- [x] "):
            continue
        head = block.split("\n", 1)[0]
        tm = re.match(r"- \[x\] (\S+) ", head)
        at = re.search(r"dispatch-facts at=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)([+-]\d{4}|Z)", block)
        if not tm or not at:
            continue
        repo = re.search(r"\(repo: ([^)]+)\)", head)
        kind = re.search(r"\(kind: ([a-z]+)\)", head)
        pr = re.search(r"https://\S+/pull/\d+", head)
        est = re.search(r"(?:^|[^\w-])estimate=(\d+)m", block)
        print("\t".join([
            tm.group(1),
            repo.group(1).rsplit("/", 1)[-1] if repo else "-",
            kind.group(1) if kind else "-",
            at.group(1) + at.group(2),
            pr.group(0).rstrip(").,") if pr else "-",
            est.group(1) if est else "-",
        ]))
PY
  [ -s "$TMPFILE.entries" ] || { echo "effort ledger: nothing recoverable to backfill"; return 0; }
  : >"$TMPFILE.times"
  while IFS="$(printf '\t')" read -r task _ kind _ url _; do
    times="- -"
    if [ "$url" != - ]; then
      times=$(pr_times "$url")
    fi
    report="$DATA/$task/report.md"
    mtime=-
    if [ "$kind" = scout ] && [ -f "$report" ]; then
      mtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$report" 2>/dev/null) || mtime=-
    fi
    printf '%s\t%s\t%s\n' "$task" "$times" "$mtime" >>"$TMPFILE.times"
  done <"$TMPFILE.entries"
  python3 - "$TMPFILE.entries" "$TMPFILE.times" <<'PY' >"$TMPFILE" || fail "could not build the backfill records"
import json
import sys
import time
from datetime import datetime, timezone

def utc_iso(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%S%z").astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

times = {}
for line in open(sys.argv[2], encoding="utf-8"):
    task, pr, mtime = line.rstrip("\n").split("\t")
    created, merged = pr.split(" ", 1)
    times[task] = (created, merged, mtime)
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    task, project, kind, at, url, est = line.split("\t")
    created, merged, mtime = times.get(task, ("-", "-", "-"))
    if created != "-":
        ready, source = created, "pr-opened"
    elif mtime != "-":
        ready, source = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(mtime))), "report"
    else:
        continue
    print(json.dumps({
        "task": task, "spawn_gen": None, "recorded_at": now,
        "project": None if project == "-" else project,
        "kind": None if kind == "-" else kind,
        "mode": None, "harness": None, "model": None, "effort": None,
        "dispatched_at": utc_iso(at.replace("Z", "+0000")),
        "ready_at": ready, "ready_source": source,
        "landed_at": None if merged == "-" else merged,
        "landed_source": None if merged == "-" else "merged",
        "estimate_min": None if est == "-" else int(est),
        "backfill": True,
    }))
PY
  append_records "$TMPFILE"
}

cmd_stats() {
  local kind_filter='' project_filter=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; kind_filter=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; project_filter=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  if [ ! -f "$LEDGER" ]; then
    echo "effort ledger: no records yet"
    return 0
  fi
  python3 - "$LEDGER" "$kind_filter" "$project_filter" <<'PY' || fail "could not read $LEDGER"
import json
import math
import sys
from datetime import datetime

ledger, kind_filter, project_filter = sys.argv[1:]


def epoch(text):
    if not text:
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").timestamp()
    except ValueError:
        return None


def minutes(start, end):
    a, b = epoch(start), epoch(end)
    return None if a is None or b is None or b < a else (b - a) / 60.0


def median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def p90(xs):
    s = sorted(xs)
    return s[max(0, math.ceil(0.9 * len(s)) - 1)]


def fmt(xs, unit):
    if not xs:
        return "-"
    if unit == "x":
        return "%.2fx/%.2fx" % (median(xs), p90(xs))
    return "%dm/%dm" % (round(median(xs)), round(p90(xs)))


rows = []
for line in open(ledger, encoding="utf-8", errors="replace"):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if not isinstance(r, dict):
        continue
    if kind_filter and r.get("kind") != kind_filter:
        continue
    if project_filter and r.get("project") != project_filter:
        continue
    r["_ready"] = minutes(r.get("dispatched_at"), r.get("ready_at"))
    r["_landed"] = minutes(r.get("dispatched_at"), r.get("landed_at"))
    est = r.get("estimate_min")
    r["_ratio"] = r["_ready"] / est if r["_ready"] is not None and isinstance(est, (int, float)) and est > 0 else None
    rows.append(r)
if not rows:
    print("effort ledger: no records yet")
    sys.exit(0)

print("effort ledger: %d records; agent wall-clock minutes from dispatch, median/p90" % len(rows))
header = "%-10s %-34s %5s  %-15s %-15s %s" % ("group", "value", "n", "to-ready", "to-landed", "actual/estimate")
for field, label in (("kind", "kind"), ("project", "project"), ("model", "model")):
    print()
    print(header)
    groups = {}
    for r in rows:
        groups.setdefault(r.get(field) or "unknown", []).append(r)
    for value in sorted(groups):
        g = groups[value]
        print("%-10s %-34s %5d  %-15s %-15s %s" % (
            label, value[:34], len(g),
            fmt([r["_ready"] for r in g if r["_ready"] is not None], "m"),
            fmt([r["_landed"] for r in g if r["_landed"] is not None], "m"),
            fmt([r["_ratio"] for r in g if r["_ratio"] is not None], "x"),
        ))
PY
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  record) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
  backfill) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  stats) ;;
  *) usage >&2; exit 2 ;;
esac
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/fm-effort-ledger.XXXXXX")
trap 'rm -f "$TMPFILE" "$TMPFILE.times" "$TMPFILE.entries"' EXIT
case "$1" in
  record) cmd_record "$2" ;;
  backfill) cmd_backfill ;;
  stats) shift; cmd_stats "$@" ;;
esac
