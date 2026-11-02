#!/usr/bin/env bash
# tests/fm-contributions-fleet.test.sh - this fleet's own published-contribution
# cases: settled history cannot starve a live contribution under the check
# bound, settled final records leave the per-poll working set, and a local
# bookkeeping overrun is reported once per episode. They live beside
# upstream's tests/fm-contributions.test.sh so a take-in never re-resolves them.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions-fleet)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# The fixture helpers below are copies of upstream's suite's.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  fm_fakebin_write "$home/fakebin/tmux" < <(printf '#!/bin/sh\nexit 1\n')
  fm_fakebin_write "$home/fakebin/no-mistakes" < <(printf '#!/bin/sh\nexit 0\n')
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$home"
}

record() { # home id number forge-state mergeability [hold]
  local home=$1 id=$2 number=$3 state=$4 mergeable=$5 hold=${6:-}
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship) %s\n' \
    "$id" "$id" "$number" "$hold" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" \
    --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" --arg mergeable "$mergeable" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:$mergeable,
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/$id/contributions.json"
}

# A task's durable records wherever they live: the working copy of a pair
# first, then the archive that a settled final or retired record moves to.
saved_record() { # home task
  local file
  local -a files=()
  for file in "$1/data/$2/contributions.json" "$1/data/$2/contributions-archive.json"; do
    [ ! -f "$file" ] || files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  jq -S -s '{schema:.[0].schema,task:.[0].task,
    records:(reduce (.[].records[]) as $r ([]; if any(.[]; .url == $r.url) then . else . + [$r] end))}' "${files[@]}"
}

mutate_record() {
  jq "$3" "$1/data/$2/contributions.json" > "$1/update.json" || fail 'fixture mutation failed'
  mv "$1/update.json" "$1/data/$2/contributions.json"
}

forge_home() {
  local home=$1
  mkdir -p "$home/forge" "$home/root/bin" "$home/wt"
  fm_fakebin_write "$home/root/bin/fm-guard.sh" < <(printf '#!/bin/sh\nexit 0\n')
  chmod +x "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  record "$home" delivery 8 open mergeable
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '[]\n' > "$home/forge/threads.json"
  printf '[]\n' > "$home/forge/labels.json"
  printf '[]\n' > "$home/forge/events.json"
  fm_fakebin_write "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8'|'api repos/o/r/pulls/9'|'api repos/o/r/pulls/10')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api graphql '*)
    jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

# Settled final records, each carrying a review-sized history, as a live home
# accumulates them; written without a process per record.
final_history() { # home count
  local i body
  body=$(printf '%2000s' '' | tr ' ' x)
  for ((i = 1; i <= $2; i++)); do
    mkdir -p "$1/data/landed-$i"
    printf '{"schema":"fm-contributions.v1","task":"landed-%s","records":[{"url":"https://github.com/o/r/pull/%s","kind":"pr","checked_at":"%s","error":null,"pending":[],"seen":[],"notified":[],"verdict":null,"observation":{"head":"%s","state":"merged","draft":false,"mergeable":"unknown","review_decision":"APPROVED","can_merge":false,"checks":[],"reviews":[],"events":[%s]}}]}\n' \
      "$i" "$((1000 + i))" "$NOW" "$HEAD_A" \
      "$(for e in 1 2 3 4 5 6 7 8; do printf '%s{"token":"comment:%s:x","type":"comment","author":"m","body":"%s"}' "$([ "$e" = 1 ] || printf ,)" "$e" "$body"; done)" \
      > "$1/data/landed-$i/contributions.json"
  done
}

test_history_cannot_starve_a_live_contribution_under_the_check_bound() {
  local home out rc
  home=$(new_home history-check-bound)
  forge_home "$home"
  final_history "$home" 300
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"This will be closed by another change",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || fail 'could not arm the contribution check'
  rc=0
  out=$(with_home "$home" env FM_CHECK_TIMEOUT=15 timeout 15 bash "$home/state/contributions.check.sh") || rc=$?
  [ "$rc" -eq 0 ] || fail "the check was killed at its time limit (rc $rc) behind 300 settled records: $out"
  printf '%s\n' "$out" | grep -E '^contribution-wake: check: contributions delivery [0-9a-f]{64}$' >/dev/null \
    || fail "the maintainer comment on the live contribution was not surfaced: $out"
  saved_record "$home" delivery | jq -e --arg now "$NOW" '.records[0].checked_at == $now and (.records[0].pending | length) == 1' >/dev/null \
    || fail 'the live contribution was not observed on the first bounded run'
  pass 'settled history cannot starve a live contribution of its observation under the check bound'
}

test_settled_finals_leave_the_per_poll_working_set() {
  local count home real_jq calls=()
  real_jq=$(command -v jq)
  for count in 3 30; do
    home=$(new_home "settled-working-set-$count")
    forge_home "$home"
    final_history "$home" "$count"
    printf -- '- [ ] landed-1 - Linked https://github.com/o/r/pull/1001 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'settling poll failed'
    [ ! -e "$home/data/landed-1/contributions.json" ] || fail 'a settled final record stayed in the per-poll working set'
    fm_fakebin_write "$home/fakebin/jq" < <(printf '#!/bin/sh\nprintf x >> "%s/jq-calls"\nexec "%s" "$@"\n' "$home" "$real_jq")
    chmod +x "$home/fakebin/jq"
    : > "$home/forge/calls"
    with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll over archived finals failed'
    grep -Eq '^api repos/o/r/pulls/10[0-9][0-9]$' "$home/forge/calls" && fail 'an archived final contribution was read from the forge'
    calls+=("$(wc -c < "$home/jq-calls" | tr -d '[:space:]')")
    with_home "$home" "$ROOT/bin/fm-contributions.sh" owned | jq -e --argjson count "$count" '
      length == $count + 1 and ([.[] | select(.final)] | length) == $count' >/dev/null \
      || fail 'archived finals left the ownership view'
    with_home "$home" "$ROOT/bin/fm-contributions.sh" enroll landed-2 https://github.com/o/r/pull/1002 >/dev/null \
      || fail 'enrolling an archived final contribution failed'
    [ ! -e "$home/data/landed-2/contributions.json" ] || fail 'enrolling an archived final contribution rediscovered it as new'
    with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'contribution input failed'
    with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" | jq -e --argjson count "$count" '
      .known == $count + 1 and .counts.nobody == $count' >/dev/null \
      || fail 'archived finals left measured coverage'
  done
  [ "${calls[0]}" = "${calls[1]}" ] \
    || fail "settled final contributions still cost per-poll jq calls: ${calls[0]} with 3, ${calls[1]} with 30"
  pass 'settled final records leave the per-poll working set yet stay owned, final and measured'
}

test_local_bookkeeping_overrun_is_reported_once_per_episode() {
  local home out run real_jq
  home=$(new_home bookkeeping-overrun)
  forge_home "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  real_jq=$(command -v jq)
  # Local bookkeeping turns slow only while the slow marker exists.
  fm_fakebin_write "$home/fakebin/jq" < <(printf '#!/bin/sh\ncase "$*" in *view.json*) [ ! -e "%s/slow" ] || sleep 5 ;; esac\nexec "%s" "$@"\n' "$home" "$real_jq")
  chmod +x "$home/fakebin/jq"
  for run in slow repeat recovered again; do
    case "$run" in recovered) rm -f "$home/slow" ;; *) : > "$home/slow" ;; esac
    out=$(with_home "$home" env FM_CHECK_TIMEOUT=10 "$ROOT/bin/fm-contributions.sh" poll) || fail "$run poll failed"
    case "$run" in
      slow|again)
        printf '%s\n' "$out" | grep -E '^contributions: local bookkeeping used [0-9]+s of the 10s check bound, leaving [0-9]+s of forge budget for 1 owned contributions$' >/dev/null \
          || fail "a $run bookkeeping overrun was not reported: $out" ;;
      *) [ -z "$out" ] || fail "a $run poll reported again within one episode: $out" ;;
    esac
  done
  pass 'local bookkeeping that cuts the forge budget is reported once per episode'
}

failures=0
for test_name in test_local_bookkeeping_overrun_is_reported_once_per_episode test_settled_finals_leave_the_per_poll_working_set test_history_cannot_starve_a_live_contribution_under_the_check_bound; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures contribution regressions"
