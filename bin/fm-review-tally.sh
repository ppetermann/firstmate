#!/usr/bin/env bash
# fm-review-tally.sh - count what each reviewer uniquely catches, per merged PR.
#
# This header is the single owner of the tally's columns and definitions.
# It answers one question with a recorded number instead of an impression:
# "would we have missed this without CodeRabbit?" - and, symmetrically, what
# the OCR review bot caught that CodeRabbit did not, so the decision to retire
# one of the two reviewers can read both columns.
#
# Usage:
#   fm-review-tally.sh record <PR url> [--regime per-push|once-after-bot] [--judge <n>=<verdict>]... [--acted-at <n>=<sha>]... [--note <text>] [--allow-open]
#   fm-review-tally.sh candidates <PR url>
#   fm-review-tally.sh summary [--repo <owner/repo>] [--since YYYY-MM-DD]
# Environment:
#   FM_HOME                 home whose data/review-tally.tsv is written (required, same rule as fm-send.sh)
#   FM_TALLY_BOT_LOGIN      the App's login as GitHub shows it on a thread author (default firstmate-ocr-review)
#   FM_TALLY_CR_LOGIN       CodeRabbit's login (default coderabbitai)
#
# GitHub is read through the ambient `gh` (captain auth), read-only, GitHub.com
# pull requests only. Every read fails closed: any non-zero `gh` exit or
# unparseable JSON prints the first error line, exits 1, and writes nothing.
#
# Reads, in order:
#   1. One GraphQL query for the PR's mergedAt, headRefOid, first 100 review
#      threads (resolution state, resolver, and each thread's first comment:
#      author, path, originalLine, originalCommit, createdAt, body) and first
#      100 commits (oid, committedDate).
#   2. Per PR commit: repos/<o>/<r>/commits/<oid> for files[].filename, and
#      repos/<o>/<r>/commits/<oid>/check-runs?check_name=ocr-review for the
#      newest completed run's conclusion.
#
# Definitions (the header's contract; the counting implements exactly these):
#   finding      a review thread whose first comment's author.login, after
#                stripping a trailing "[bot]", equals the bot login or the
#                CodeRabbit login. Threads by anyone else are ignored.
#   severity     for the bot, the first _critical_|_high_|_medium_|_low_ token
#                in the body; for CodeRabbit, Critical|Major|Minor after a
#                coloured-circle glyph, mapped to high/medium/low. Unparseable
#                is "unknown". blocking = critical/high/medium for the bot,
#                Critical/Major for CodeRabbit.
#   shared(t)    t is paired with a finding by the OTHER reviewer. Pairing is
#                ONE-TO-ONE, so no single counterpart can mark two findings
#                shared: within a path, every cross-reviewer pair whose
#                originalLines are both non-null and at most 15 apart is a
#                candidate pair, and candidate pairs are consumed nearest line
#                distance first, ties broken by the pair's lower original line
#                and then by thread order, so the result does not depend on the
#                order the API happened to return the threads in. Whatever is
#                left unpaired is unique. A null line is never paired:
#                conservatively it surfaces as a candidate for judgement
#                instead of vanishing.
#   acted(t)     some PR commit with committedDate > t.createdAt lists t.path
#                among its files. That proxy credits the FIRST such commit, so
#                two findings on one file are both credited to whichever push
#                fixed either. --acted-at <n>=<sha> overrides it for one
#                candidate: that finding is acted with <sha> as its first acting
#                commit, and on_bot_approved is recomputed against <sha> under
#                the rule below. <n> is the `candidates` number and <sha> a full
#                or at least 7-character oid of a commit of this PR. An <n> with
#                no candidate, an unknown or ambiguous <sha>, a malformed pair,
#                or the same <n> pinned twice is a usage error naming the
#                offending argument (exit 2, nothing written).
#   on_bot_approved(t)  CodeRabbit findings only: some PR commit has check
#                conclusion "success", committedDate >= t.originalCommit's
#                committedDate, and, when acted, committedDate < the first
#                acting commit's date.
#   rejected(t)  not acted, isResolved, and resolvedBy.login does not end in
#                "[bot]".
#   unique_acted !shared && acted, after judgements.
#   judgement    --judge <n>=<verdict>, n from the `candidates` numbering:
#                missed (default, counts), declined (the bot read it and chose
#                not to file; excluded from unique counts, recorded), dup (same
#                substance as the other reviewer's finding at another path or
#                line; excluded), invalid (acted on but not a real defect;
#                excluded). Any other verdict is a usage error.
#   bot_rounds   distinct PR commits carrying a completed ocr-review check run.
#
# `candidates` prints, numbered from 1, every finding with !shared && acted:
#   <n> <reviewer> <path>:<originalLine> @<commit7> sev=<severity> acted=y bot_approved=<y|n|-> | <body first line, 100 chars>
# `record` prints the same list first, so firstmate sees what it is about to
# count, then writes.
#
# data/review-tally.tsv columns, in order:
#   recorded_at repo pr merged_at regime bot_rounds bot_findings bot_blocking
#   bot_unique_acted bot_rejected cr_findings cr_blocking cr_unique_acted
#   cr_unique_acted_on_bot_approved cr_rejected judged note
# The header line is written when the file is created. A line for the same repo
# and pr is REPLACED, so re-recording after a --judge is idempotent. A PR that
# is not merged is refused (exit 2, nothing written) unless --allow-open,
# because the acted proxy needs the final commit list. Default --regime is
# once-after-bot; pass per-push for anything before 2026-09-06.
# `judged` is a comma-joined list, in the order the flags were given, of
# <n>=<verdict> judgements and <n>=acted@<sha7> pins, or "-"; one candidate may
# carry both, and a re-record from that list reproduces the row. `note` is free
# text with tabs and newlines replaced by spaces, or "-".
#
# `summary` prints one line per repo and one total line with PRs recorded and
# every count column, then the two rate lines cr_unique_per_pr and
# bot_unique_per_pr, then, when --since is given, one coverage line per repo
# "recorded=<n> merged=<m>" where m is GitHub's merged-PR count since that date.
# The coverage line is what makes a lapse in recording visible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

BOT_LOGIN=${FM_TALLY_BOT_LOGIN:-firstmate-ocr-review}
CR_LOGIN=${FM_TALLY_CR_LOGIN:-coderabbitai}

COLUMNS='recorded_at	repo	pr	merged_at	regime	bot_rounds	bot_findings	bot_blocking	bot_unique_acted	bot_rejected	cr_findings	cr_blocking	cr_unique_acted	cr_unique_acted_on_bot_approved	cr_rejected	judged	note'

usage() {
  sed -n '/^# Usage:/,/^#   FM_TALLY_CR_LOGIN/p' "$SCRIPT_DIR/fm-review-tally.sh" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

die_read() {
  printf '%s\n' "$1" | head -n 1 >&2
  exit 1
}

WORK=
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

require_home() {
  if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
    echo "error: FM_HOME is not set; fm-review-tally refuses to guess which home's tally to read or write" >&2
    exit 2
  fi
  if [ ! -d "$FM_HOME" ]; then
    echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
    exit 2
  fi
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  TALLY="$DATA/review-tally.tsv"
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die_read "error: gh is not installed"
  command -v jq >/dev/null 2>&1 || die_read "error: jq is not installed"
}

# gh_read <destination> <label> <arg>...: run `gh` fail-closed into a file.
# Never call this inside a command substitution: die_read must exit the script,
# and a subshell would swallow that exit and let a failed read be recorded.
gh_read() {
  local dest=$1 label=$2 rc
  shift 2
  "$@" > "$dest" 2> "$WORK/gh.err"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ -s "$WORK/gh.err" ]; then
    die_read "$(head -n 1 "$WORK/gh.err")"
  fi
  die_read "error: $label read failed (gh exit $rc)"
}

# shellcheck disable=SC2016 # GraphQL variables are literal query syntax.
GRAPHQL_QUERY='query($owner:String!,$repo:String!,$number:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      mergedAt
      headRefOid
      reviewThreads(first:100){nodes{
        isResolved
        isOutdated
        resolvedBy{login}
        comments(first:1){nodes{
          author{login}
          path
          originalLine
          originalCommit{oid committedDate}
          createdAt
          body
        }}
      }}
      commits(first:100){nodes{commit{oid committedDate}}}
    }
  }
}'

# fetch_pr <owner> <repo> <number>: write $WORK/data.json with the PR node and
# one enriched record per PR commit (files touched, ocr-review conclusion).
fetch_pr() {
  local owner=$1 repo=$2 number=$3 oid
  gh_read "$WORK/graphql.json" "pull request" gh api graphql \
    -f query="$GRAPHQL_QUERY" -F owner="$owner" -F repo="$repo" -F number="$number"
  jq -e '.data.repository.pullRequest != null' "$WORK/graphql.json" >/dev/null 2>&1 \
    || die_read "error: cannot parse the pull request response for $owner/$repo#$number"
  jq '.data.repository.pullRequest' "$WORK/graphql.json" > "$WORK/pr.json" \
    || die_read "error: cannot parse the pull request response for $owner/$repo#$number"

  jq -r '.commits.nodes[]?.commit.oid // empty' "$WORK/pr.json" > "$WORK/oids" \
    || die_read "error: cannot read the commit list for $owner/$repo#$number"
  : > "$WORK/commits.jsonl"
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    gh_read "$WORK/commit.json" "commit $oid" gh api "repos/$owner/$repo/commits/$oid"
    gh_read "$WORK/checks.json" "check runs for $oid" \
      gh api "repos/$owner/$repo/commits/$oid/check-runs?check_name=ocr-review"
    jq --arg oid "$oid" \
       --slurpfile checks "$WORK/checks.json" \
       --slurpfile pr "$WORK/pr.json" \
       '{
          oid: $oid,
          committedDate: ($pr[0].commits.nodes[] | select(.commit.oid == $oid) | .commit.committedDate),
          files: [ (.files // [])[] | .filename ],
          conclusion: ([ (($checks[0].check_runs) // [])[]
                         | select(.status == "completed") ]
                       | sort_by(.completed_at // .started_at // "")
                       | last | .conclusion // null)
        }' "$WORK/commit.json" >> "$WORK/commits.jsonl" \
      || die_read "error: cannot parse commit $oid for $owner/$repo#$number"
  done < "$WORK/oids"

  jq -n --slurpfile pr "$WORK/pr.json" --slurpfile commits "$WORK/commits.jsonl" \
    '{pr: $pr[0], commits: $commits}' > "$WORK/data.json" \
    || die_read "error: cannot assemble the pull request data for $owner/$repo#$number"
}

# shellcheck disable=SC2016 # jq variables and filters are literal program syntax.
ANALYSIS_JQ='
def absn: if . < 0 then - . else . end;
def firstline: (. // "") | split("\n")[0] // "";
def sev_bot: (. // "") | [scan("_(critical|high|medium|low)_")] | (.[0][0] // "unknown");
def sev_cr:  (. // "") | [scan("\\p{So}[^A-Za-z]*(Critical|Major|Minor)")] | .[0][0]
             | if . == "Critical" then "high"
               elif . == "Major" then "medium"
               elif . == "Minor" then "low"
               else "unknown" end;

. as $root
| $root.pr as $pr
| $root.commits as $commits
| [ ($pr.reviewThreads.nodes // [])[]
    | . as $t
    | (.comments.nodes[0] // null) as $c
    | select($c != null and $c.path != null)
    | ((($c.author.login) // "") | sub("\\[bot\\]$"; "")) as $login
    | (if $login == $bot then "bot" elif $login == $cr then "cr" else null end) as $reviewer
    | select($reviewer != null)
    | (if $reviewer == "bot" then ($c.body | sev_bot) else ($c.body | sev_cr) end) as $sev
    | {
        reviewer: $reviewer,
        path: $c.path,
        line: $c.originalLine,
        created: ($c.createdAt // ""),
        oc_oid: ($c.originalCommit.oid // null),
        oc_date: ($c.originalCommit.committedDate // null),
        body: ($c.body | firstline),
        severity: $sev,
        blocking: (if $reviewer == "bot"
                   then ($sev == "critical" or $sev == "high" or $sev == "medium")
                   else ($sev == "high" or $sev == "medium") end),
        resolved: ($t.isResolved // false),
        resolved_by: ($t.resolvedBy.login // null)
      }
  ] as $raw
| [ $raw[]
    | . as $f
    | ([ $commits[]
         | select(.committedDate != null and .committedDate > $f.created
                  and ((.files // []) | index($f.path)) != null) ]
       | sort_by(.committedDate)) as $acting
    | $f + { acted: (($acting | length) > 0), acting_date: ($acting[0].committedDate // null) }
  ] as $withacted
| ($withacted | to_entries | map(.value + {idx: .key})) as $indexed
| ([ $indexed[] | select(.reviewer == "bot" and .line != null) ]) as $botlined
| ([ $indexed[] | select(.reviewer == "cr" and .line != null) ]) as $crlined
| ([ $botlined[] as $b
     | $crlined[] as $c
     | select($b.path == $c.path and ((($b.line) - ($c.line)) | absn) <= 15)
     | { b: $b.idx,
         c: $c.idx,
         key: [ ((($b.line) - ($c.line)) | absn),
                (if $b.line <= $c.line then $b.line else $c.line end),
                $b.idx,
                $c.idx ] } ]
   | sort_by(.key)) as $pairs
| (reduce $pairs[] as $p ({};
     if (.[($p.b | tostring)] // false) or (.[($p.c | tostring)] // false)
     then .
     else . + { ($p.b | tostring): true, ($p.c | tostring): true }
     end)) as $paired
| [ $indexed[] | . + { shared: ((($paired[(.idx | tostring)]) // false)) } ] as $prelim
| ([ $prelim[] | select((.shared | not) and .acted) ]
   | sort_by([.created, .path, (.line // -1), .reviewer])
   | to_entries
   | map({ key: ((.key + 1) | tostring), value: (.value.idx | tostring) })
   | from_entries) as $ntoidx
| (reduce ($pin | to_entries[]) as $p ({};
     if ($ntoidx[$p.key] // null) == null then . else . + { ($ntoidx[$p.key]): $p.value } end
   )) as $pinned
| [ $prelim[]
    | . as $f
    | (($pinned[($f.idx | tostring)]) // null) as $pinoid
    | (if $pinoid == null then $f.acted else true end) as $acted
    | (if $pinoid == null then $f.acting_date
       else ([ $commits[] | select(.oid == $pinoid) | .committedDate ] | .[0] // null)
       end) as $acting_date
    | (if $f.reviewer != "cr" then null
       elif $f.oc_date == null then false
       else ($commits
             | any(.conclusion == "success"
                   and .committedDate != null
                   and .committedDate >= $f.oc_date
                   and ($acting_date == null or .committedDate < $acting_date)))
       end) as $approved
    | ($f | del(.idx)) + {
        acted: $acted,
        acting_date: $acting_date,
        bot_approved: $approved,
        rejected: (($acted | not) and $f.resolved and $f.resolved_by != null
                   and (($f.resolved_by | test("\\[bot\\]$")) | not))
      }
  ] as $findings
| ([ $findings[] | select((.shared | not) and .acted) ]
   | sort_by([.created, .path, (.line // -1), .reviewer])
   | to_entries
   | map(.value + { n: (.key + 1) })
   | map(. + { verdict: ($judge[(.n | tostring)] // "missed") })) as $cands
| ($cands | map(select(.verdict == "missed"))) as $counted
| {
    merged_at: ($pr.mergedAt // null),
    head: ($pr.headRefOid // null),
    bot_rounds: ($commits | map(select(.conclusion != null)) | length),
    candidates: $cands,
    counts: {
      bot_findings: ($findings | map(select(.reviewer == "bot")) | length),
      bot_blocking: ($findings | map(select(.reviewer == "bot" and .blocking)) | length),
      bot_unique_acted: ($counted | map(select(.reviewer == "bot")) | length),
      bot_rejected: ($findings | map(select(.reviewer == "bot" and .rejected)) | length),
      cr_findings: ($findings | map(select(.reviewer == "cr")) | length),
      cr_blocking: ($findings | map(select(.reviewer == "cr" and .blocking)) | length),
      cr_unique_acted: ($counted | map(select(.reviewer == "cr")) | length),
      cr_unique_acted_on_bot_approved:
        ($counted | map(select(.reviewer == "cr" and .bot_approved == true)) | length),
      cr_rejected: ($findings | map(select(.reviewer == "cr" and .rejected)) | length)
    }
  }
'

# analyse <judge-json> <pin-json>: write $WORK/analysis.json from $WORK/data.json.
analyse() {
  local judge=$1 pin=$2
  jq --arg bot "$BOT_LOGIN" --arg cr "$CR_LOGIN" --argjson judge "$judge" --argjson pin "$pin" \
    "$ANALYSIS_JQ" "$WORK/data.json" > "$WORK/analysis.json" \
    || die_read "error: cannot analyse the review threads"
}

print_candidates() {
  jq -r '.candidates[]
         | [ (.n | tostring),
             .reviewer,
             (.path + ":" + (if .line == null then "-" else (.line | tostring) end)),
             ("@" + (if .oc_oid == null then "-------" else (.oc_oid[0:7]) end)),
             ("sev=" + .severity),
             "acted=y",
             ("bot_approved=" + (if .bot_approved == null then "-"
                                 elif .bot_approved then "y" else "n" end)),
             "|",
             (.body[0:100])
           ] | join(" ")' "$WORK/analysis.json"
}

sanitize_note() {
  printf '%s' "$1" | tr '\t\n\r' '   '
}

# write_record <repo> <pr> <regime> <judged> <note>
write_record() {
  local repo=$1 pr=$2 regime=$3 judged=$4 note=$5 merged_at recorded_at line
  merged_at=$(jq -r '.merged_at // "-"' "$WORK/analysis.json")
  recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line=$(jq -r --arg recorded_at "$recorded_at" --arg repo "$repo" --arg pr "$pr" \
    --arg merged_at "$merged_at" --arg regime "$regime" --arg judged "$judged" \
    --arg note "$note" \
    '[ $recorded_at, $repo, $pr, $merged_at, $regime,
       (.bot_rounds | tostring),
       (.counts.bot_findings | tostring),
       (.counts.bot_blocking | tostring),
       (.counts.bot_unique_acted | tostring),
       (.counts.bot_rejected | tostring),
       (.counts.cr_findings | tostring),
       (.counts.cr_blocking | tostring),
       (.counts.cr_unique_acted | tostring),
       (.counts.cr_unique_acted_on_bot_approved | tostring),
       (.counts.cr_rejected | tostring),
       $judged, $note ] | join("\t")' "$WORK/analysis.json") \
    || die_read "error: cannot format the tally record"

  mkdir -p "$DATA" || die_read "error: cannot create $DATA"
  {
    printf '%s\n' "$COLUMNS"
    if [ -f "$TALLY" ]; then
      awk -F'\t' -v repo="$repo" -v pr="$pr" \
        'NR == 1 && $1 == "recorded_at" { next }
         $2 == repo && $3 == pr { next }
         { print }' "$TALLY"
    fi
    printf '%s\n' "$line"
  } > "$WORK/tally.tsv" || die_read "error: cannot stage the tally"
  mv "$WORK/tally.tsv" "$TALLY" || die_read "error: cannot write $TALLY"
  printf 'recorded %s#%s -> %s\n' "$repo" "$pr" "$TALLY"
}

# resolve_pins <pin-json>: set PIN_RESOLVED, mapping each pinned candidate number
# to the full oid of the one PR commit its <sha> names. Never call this inside a
# command substitution: die_usage must exit the script.
resolve_pins() {
  local pins=$1 n sha matches count
  PIN_RESOLVED='{}'
  [ "$pins" != '{}' ] || return 0
  while IFS='	' read -r n sha; do
    [ -n "$n" ] || continue
    matches=$(jq -r --arg s "$sha" '.commits[].oid | select(startswith($s))' "$WORK/data.json") \
      || die_read "error: cannot read the commit list for --acted-at $n=$sha"
    count=$(printf '%s' "$matches" | grep -c . || true)
    [ "$count" -ne 0 ] || die_usage "--acted-at $n=$sha names no commit of this pull request"
    [ "$count" -eq 1 ] \
      || die_usage "--acted-at $n=$sha is ambiguous: it matches $count commits of this pull request"
    PIN_RESOLVED=$(printf '%s' "$PIN_RESOLVED" \
      | jq -c --arg n "$n" --arg oid "$(printf '%s\n' "$matches" | head -n 1)" '. + {($n): $oid}') \
      || die_read "error: cannot record the --acted-at pin for candidate $n"
  done < <(printf '%s' "$pins" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
}

parse_pr_url() {
  local url=$1
  fm_pr_url_parse "$url" || die_usage "not a pull request URL: $url"
  [ "$FM_PR_PROVIDER" = github ] \
    || die_usage "only GitHub pull requests carry the review threads this tally reads: $url"
}

cmd_record_or_candidates() {
  local mode=$1 url='' regime=once-after-bot note=- allow_open=0
  local judge_json='{}' pin_json='{}' judged_list='' n verdict sha spec
  local -a judged_parts=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --regime)
        [ "$#" -gt 1 ] || die_usage "--regime requires a value"
        case "$2" in
          per-push|once-after-bot) regime=$2 ;;
          *) die_usage "unknown regime: $2" ;;
        esac
        shift 2
        ;;
      --judge)
        [ "$#" -gt 1 ] || die_usage "--judge requires <n>=<verdict>"
        spec=$2
        n=${spec%%=*}
        verdict=${spec#*=}
        case "$spec" in *=*) : ;; *) die_usage "--judge needs <n>=<verdict>, got: $spec" ;; esac
        case "$n" in ''|*[!0-9]*) die_usage "--judge candidate must be a number, got: $n" ;; esac
        [ "$n" -ge 1 ] || die_usage "--judge candidate numbers start at 1"
        case "$verdict" in
          missed|declined|dup|invalid) : ;;
          *) die_usage "unknown judgement verdict: $verdict (missed, declined, dup, invalid)" ;;
        esac
        printf '%s' "$judge_json" | jq -e --arg n "$n" 'has($n)' >/dev/null 2>&1 \
          && die_usage "--judge $n was already given"
        judge_json=$(printf '%s' "$judge_json" \
          | jq -c --arg n "$n" --arg v "$verdict" '. + {($n): $v}') \
          || die_usage "cannot record judgement: $spec"
        judged_parts+=("v:$n=$verdict")
        shift 2
        ;;
      --acted-at)
        [ "$#" -gt 1 ] || die_usage "--acted-at requires <n>=<sha>"
        spec=$2
        case "$spec" in *=*) : ;; *) die_usage "--acted-at needs <n>=<sha>, got: $spec" ;; esac
        n=${spec%%=*}
        sha=${spec#*=}
        sha=${sha,,}
        case "$n" in ''|*[!0-9]*) die_usage "--acted-at candidate must be a number, got: $n" ;; esac
        [ "$n" -ge 1 ] || die_usage "--acted-at candidate numbers start at 1"
        case "$sha" in ''|*[!0-9a-f]*) die_usage "--acted-at needs a commit oid, got: $spec" ;; esac
        [ "${#sha}" -ge 7 ] \
          || die_usage "--acted-at needs at least 7 characters of the commit oid, got: $spec"
        printf '%s' "$pin_json" | jq -e --arg n "$n" 'has($n)' >/dev/null 2>&1 \
          && die_usage "--acted-at $n was already given"
        pin_json=$(printf '%s' "$pin_json" \
          | jq -c --arg n "$n" --arg s "$sha" '. + {($n): $s}') \
          || die_usage "cannot record pin: $spec"
        judged_parts+=("p:$n")
        shift 2
        ;;
      --note)
        [ "$#" -gt 1 ] || die_usage "--note requires a value"
        note=$(sanitize_note "$2")
        [ -n "$note" ] || note=-
        shift 2
        ;;
      --allow-open)
        allow_open=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die_usage "unknown option: $1"
        ;;
      *)
        [ -z "$url" ] || die_usage "only one PR URL is accepted"
        url=$1
        shift
        ;;
    esac
  done
  [ -n "$url" ] || die_usage "$mode requires a PR URL"
  if [ "$mode" = candidates ]; then
    [ "$regime" = once-after-bot ] && [ "$judge_json" = '{}' ] && [ "$pin_json" = '{}' ] \
      && [ "$note" = - ] \
      || die_usage "candidates takes only a PR URL"
  fi

  require_home
  require_tools
  parse_pr_url "$url"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-review-tally.XXXXXX") || die_read "error: cannot create a work directory"
  fetch_pr "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER"
  resolve_pins "$pin_json"
  analyse "$judge_json" "$PIN_RESOLVED"

  local total
  total=$(jq -r '.candidates | length' "$WORK/analysis.json") \
    || die_read "error: cannot read the candidate list"
  if [ "$judge_json" != '{}' ]; then
    local bad
    bad=$(printf '%s' "$judge_json" | jq -r --argjson total "$total" \
      'keys_unsorted[] | select((. | tonumber) > $total)' | head -n 1)
    [ -z "$bad" ] || die_usage "--judge $bad has no candidate (this PR has $total)"
  fi
  if [ "$PIN_RESOLVED" != '{}' ]; then
    local badpin
    badpin=$(printf '%s' "$PIN_RESOLVED" | jq -r --argjson total "$total" \
      'keys_unsorted[] | select((. | tonumber) > $total)' | head -n 1)
    [ -z "$badpin" ] || die_usage "--acted-at $badpin has no candidate (this PR has $total)"
  fi
  print_candidates

  [ "$mode" = record ] || return 0

  local part tok oid
  if [ "${#judged_parts[@]}" -gt 0 ]; then
    for part in "${judged_parts[@]}"; do
      case "$part" in
        p:*)
          n=${part#p:}
          oid=$(printf '%s' "$PIN_RESOLVED" | jq -r --arg n "$n" '.[$n] // ""') \
            || die_read "error: cannot format the --acted-at pin for candidate $n"
          [ -n "$oid" ] || die_read "error: cannot format the --acted-at pin for candidate $n"
          tok="$n=acted@${oid:0:7}"
          ;;
        *) tok=${part#v:} ;;
      esac
      judged_list="${judged_list:+$judged_list,}$tok"
    done
  fi

  local merged
  merged=$(jq -r '.merged_at // "null"' "$WORK/analysis.json")
  if [ "$merged" = null ] && [ "$allow_open" -eq 0 ]; then
    printf 'error: %s is not merged; the acted proxy needs the final commit list (pass --allow-open to record anyway)\n' \
      "$url" >&2
    exit 2
  fi
  write_record "$FM_PR_PATH" "$FM_PR_NUMBER" "$regime" "${judged_list:--}" "$note"
}

cmd_summary() {
  local repo_filter='' since='' repo recorded merged
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -gt 1 ] || die_usage "--repo requires <owner/repo>"
        repo_filter=$2
        shift 2
        ;;
      --since)
        [ "$#" -gt 1 ] || die_usage "--since requires YYYY-MM-DD"
        case "$2" in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) since=$2 ;;
          *) die_usage "--since must be YYYY-MM-DD, got: $2" ;;
        esac
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die_usage "unknown argument: $1"
        ;;
    esac
  done

  require_home
  if [ ! -f "$TALLY" ]; then
    printf 'total: prs=0 cr_findings=0 cr_unique_acted=0 cr_unique_acted_on_bot_approved=0 cr_rejected=0 bot_findings=0 bot_blocking=0 bot_unique_acted=0 bot_rejected=0\n'
    printf 'cr_unique_per_pr=0.00\nbot_unique_per_pr=0.00\n'
    return 0
  fi

  awk -F'\t' -v filter="$repo_filter" '
    NR == 1 && $1 == "recorded_at" { next }
    NF < 15 { next }
    filter != "" && $2 != filter { next }
    {
      if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1 }
      prs[$2]++
      rounds[$2] += $6; bf[$2] += $7; bb[$2] += $8; bu[$2] += $9; br[$2] += $10
      cf[$2] += $11; cb[$2] += $12; cu[$2] += $13; cua[$2] += $14; cr[$2] += $15
    }
    END {
      tp = 0
      for (i = 1; i <= n; i++) {
        r = order[i]
        printf "repo %s: prs=%d cr_findings=%d cr_unique_acted=%d cr_unique_acted_on_bot_approved=%d cr_rejected=%d bot_findings=%d bot_blocking=%d bot_unique_acted=%d bot_rejected=%d\n", \
          r, prs[r], cf[r], cu[r], cua[r], cr[r], bf[r], bb[r], bu[r], br[r]
        tp += prs[r]; tcf += cf[r]; tcu += cu[r]; tcua += cua[r]; tcr += cr[r]
        tbf += bf[r]; tbb += bb[r]; tbu += bu[r]; tbr += br[r]
      }
      printf "total: prs=%d cr_findings=%d cr_unique_acted=%d cr_unique_acted_on_bot_approved=%d cr_rejected=%d bot_findings=%d bot_blocking=%d bot_unique_acted=%d bot_rejected=%d\n", \
        tp, tcf, tcu, tcua, tcr, tbf, tbb, tbu, tbr
      printf "cr_unique_per_pr=%.2f\n", (tp > 0 ? tcu / tp : 0)
      printf "bot_unique_per_pr=%.2f\n", (tp > 0 ? tbu / tp : 0)
    }' "$TALLY"

  [ -n "$since" ] || return 0
  require_tools
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-review-tally.XXXXXX") || die_read "error: cannot create a work directory"
  while IFS='	' read -r repo recorded; do
    [ -n "$repo" ] || continue
    gh_read "$WORK/search.json" "merged PR count for $repo" \
      gh api "search/issues?q=repo:$repo+is:pr+is:merged+merged:>=$since"
    merged=$(jq -r '.total_count // 0' "$WORK/search.json") \
      || die_read "error: cannot read the merged PR count for $repo"
    printf 'coverage %s: recorded=%s merged=%s\n' "$repo" "$recorded" "$merged"
  done < <(awk -F'\t' -v filter="$repo_filter" '
    NR == 1 && $1 == "recorded_at" { next }
    NF < 15 { next }
    filter != "" && $2 != filter { next }
    { if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1 } count[$2]++ }
    END { for (i = 1; i <= n; i++) printf "%s\t%d\n", order[i], count[order[i]] }' "$TALLY")
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  record|candidates) cmd_record_or_candidates "$COMMAND" "$@" ;;
  summary) cmd_summary "$@" ;;
  -h|--help) usage ;;
  *) die_usage "unknown command: $COMMAND" ;;
esac
