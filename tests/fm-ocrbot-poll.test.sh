#!/usr/bin/env bash
# Behavior tests for the OCR review bot poll (bin/fm-ocrbot-poll.sh) and
# bootstrap's shim activation for config/ocr-bot, plus the flip helper
# (bin/fm-pr-flip.sh) and the watcher's separate bot-poll cadence.
#
# The network is stubbed with a fakebin `gh` that models the live-verified
# `gh api -i` wire shapes: a 200 dump (status line, CRLF header block, CRLF
# blank separator, body), a 304 dump that exits 1, and hard failures that print
# one stderr line with no dump. Fixtures are plain files so each test drives listings, ETags, and
# failures declaratively. No GitHub network call is ever made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ocrbot-poll-tests)

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# A fakebin `gh` driven by fixture files under $OCR_GH_STATE/<owner>__<repo>/:
#   body       - the JSON PR listing returned on 200
#   etag       - the ETag header returned on 200 and 304
#   match-etag - when the request's If-None-Match equals this, answer 304
#                (headers only, exit 1, exactly like the real gh api -i)
#   fail-msg   - when present, print it to stderr and exit 1 with no dump
# Every invocation is logged to OCR_GH_LOG for conditional-request asserts.
make_fake_gh() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_write "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# fm-pr-flip.sh's two calls: `gh pr ready <url>` (fails when ready-fail
# exists) and a single-PR read answered from <owner>__<repo>/pr-<number>.
if [ "${1:-}" = pr ] && [ "${2:-}" = ready ]; then
  [ -z "${OCR_GH_LOG:-}" ] || echo "pr-ready $3" >> "$OCR_GH_LOG"
  if [ -f "${OCR_GH_STATE:?}/ready-fail" ]; then
    echo "ready failed" >&2
    exit 1
  fi
  exit 0
fi
case "${1:-} ${2:-}" in
  'api repos/'*/pulls/*)
    single=${2#repos/}
    repo=${single%/pulls/*}
    [ -z "${OCR_GH_LOG:-}" ] || echo "pr-get $2" >> "$OCR_GH_LOG"
    cat "${OCR_GH_STATE:?}/${repo//\//__}/pr-${single##*/}" 2>/dev/null || exit 1
    exit 0
    ;;
esac
url="" cond=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -H)
      case "$2" in
        If-None-Match:*) cond=$2 ;;
      esac
      shift 2
      ;;
    repos/*) url=$1; shift ;;
    *) shift ;;
  esac
done
slug=${url#repos/}
slug=${slug%/*}
name=${slug//\//__}
fix="${OCR_GH_STATE:?}/$name"
if [ -n "${OCR_GH_LOG:-}" ]; then
  echo "url=$url cond=$cond" >> "$OCR_GH_LOG"
fi
if [ -f "$fix/fail-msg" ]; then
  head -n 1 "$fix/fail-msg" >&2
  exit 1
fi
etag=$(cat "$fix/etag" 2>/dev/null || echo '"etag-none"')
match=$(cat "$fix/match-etag" 2>/dev/null || true)
if [ -n "$match" ] && [ "$cond" = "If-None-Match: $match" ]; then
  printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n' "$etag"
  exit 1
fi
printf 'HTTP/2.0 200 OK\r\nEtag: %s\r\n\r\n%s\n' "$etag" "$(cat "$fix/body")"
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

pr_json() {
  local num=$1 sha=$2 draft=$3
  printf '{"number":%s,"draft":%s,"head":{"sha":"%s"}}' "$num" "$draft" "$sha"
}

make_home() {
  local home=$1
  mkdir -p "$home/config/ocr-bot" "$home/ghfix/ppetermann__maia"
  printf 'ppetermann/maia\n' > "$home/config/ocr-bot/repos"
}

set_listing() {
  local home=$1; shift
  local body="[" separator="" num sha draft
  for spec in "$@"; do
    num=$(printf '%s' "$spec" | cut -d: -f1)
    sha=$(printf '%s' "$spec" | cut -d: -f2)
    draft=$(printf '%s' "$spec" | cut -d: -f3)
    body="$body$separator$(pr_json "$num" "$sha" "$draft")"
    separator=","
  done
  printf '%s\n' "$body]" > "$home/ghfix/ppetermann__maia/body"
  printf '"etag-maia-1"\n' > "$home/ghfix/ppetermann__maia/etag"
}

run_poll() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_GH_STATE="$home/ghfix" \
    OCR_GH_LOG="$home/gh.log" "$ROOT/bin/fm-ocrbot-poll.sh"
}

# ---------------------------------------------------------------------------

test_poll_no_config_is_hard_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/no-config"; mkdir -p "$home"
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "no-config exit"
  [ -z "$out" ] || fail "no config must be silent (got: $out)"
  assert_absent "$home/state" "no config must create no state"
  [ ! -e "$home/gh.log" ] || fail "no config must not call gh"
  pass "fm-ocrbot-poll is a hard no-op without config/ocr-bot"
}

test_poll_empty_repos_is_noop() {
  local home fakebin out rc
  home="$TMP_ROOT/empty-repos"; make_home "$home"
  : > "$home/config/ocr-bot/repos"
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "empty-repos exit"
  [ -z "$out" ] || fail "an empty repos file must be silent (got: $out)"
  [ ! -e "$home/gh.log" ] || fail "an empty repos file must not call gh"
  pass "fm-ocrbot-poll stays inert with an empty repos file"
}

test_poll_invalid_repos_entry_reports_once() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-repos"; make_home "$home"
  printf 'ppetermann/maia\nnot a slug\n' > "$home/config/ocr-bot/repos"
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "bad-repos exit"
  [ "$out" = "ocrbot-error invalid repos entry: not a slug" ] \
    || fail "a malformed repos entry must error once (got: $out)"
  assert_present "$home/state/ocrbot/poll.error" "the config error must leave a dedupe marker"
  [ ! -e "$home/gh.log" ] || fail "a malformed repos file must not call gh"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "bad-repos repeat exit"
  [ -z "$out" ] || fail "a repeated config error must be deduped (got: $out)"
  pass "fm-ocrbot-poll reports a malformed repos entry exactly once"
}

test_poll_new_pr_wakes_then_stays_silent() {
  local home fakebin out rc
  home="$TMP_ROOT/new-pr"; make_home "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "new-PR exit"
  [ "$out" = "ocr-pr ppetermann/maia#7 aaa111" ] \
    || fail "a new ready PR must wake with its head SHA (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "7 aaa111 0" ] \
    || fail "the seen-state must record number, sha, and draft flag"
  printf '"etag-maia-1"\n' > "$home/ghfix/ppetermann__maia/match-etag"
  : > "$home/gh.log"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "repeat exit"
  [ -z "$out" ] || fail "an unchanged listing must stay silent (got: $out)"
  assert_grep "cond=If-None-Match: \"etag-maia-1\"" "$home/gh.log" \
    "the second poll must send the cached ETag conditionally"
  assert_grep "url=repos/ppetermann/maia/pulls?state=open&per_page=50" "$home/gh.log" \
    "the listing request must use the pinned open-PR shape"
  pass "fm-ocrbot-poll wakes once for a new PR and goes conditional after"
}

test_poll_new_head_sha_wakes() {
  local home fakebin out rc
  home="$TMP_ROOT/new-sha"; make_home "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  run_poll "$home" "$fakebin" >/dev/null
  set_listing "$home" 7:bbb222:false
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "new-sha exit"
  [ "$out" = "ocr-pr ppetermann/maia#7 bbb222" ] \
    || fail "a new head SHA on a known PR must wake (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "7 bbb222 0" ] \
    || fail "the seen-state must advance to the new head SHA"
  pass "fm-ocrbot-poll wakes on a pushed head SHA"
}

test_poll_draft_lifecycle() {
  local home fakebin out rc
  home="$TMP_ROOT/draft"; make_home "$home"
  set_listing "$home" 9:ccc333:true
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "draft-first exit"
  [ -z "$out" ] || fail "a draft PR must not wake (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "9 ccc333 1" ] \
    || fail "a draft PR must still be recorded as seen"
  set_listing "$home" 9:ddd444:true
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "draft-new-sha exit"
  [ -z "$out" ] || fail "a draft PR with a new head SHA must stay silent (got: $out)"
  set_listing "$home" 9:ddd444:false
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "draft-ready exit"
  [ "$out" = "ocr-pr ppetermann/maia#9 ddd444" ] \
    || fail "a draft-to-ready transition must wake (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "9 ddd444 0" ] \
    || fail "the seen-state must record the ready state"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "ready-repeat exit"
  [ -z "$out" ] || fail "a stable ready PR must stay silent (got: $out)"
  pass "fm-ocrbot-poll tracks draft PRs silently and wakes on ready"
}

test_poll_draft_pending_bypasses_stale_etag() {
  local home fakebin out rc
  home="$TMP_ROOT/draft-stale-etag"; make_home "$home"
  set_listing "$home" 9:ccc333:true
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "draft-first exit"
  [ -z "$out" ] || fail "a draft PR must not wake (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "9 ccc333 1" ] \
    || fail "a draft PR must be recorded as seen"
  # GitHub's listing ETag does not reliably change on a draft-only flip
  # (fleet-delivery-flow "C flip", measured 2026-09-04): model that by
  # keeping the fixture's cached ETag valid even though the PR is now ready.
  set_listing "$home" 9:ccc333:false
  printf '"etag-maia-1"\n' > "$home/ghfix/ppetermann__maia/match-etag"
  : > "$home/gh.log"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "flip-with-stale-etag exit"
  assert_no_grep "cond=If-None-Match" "$home/gh.log" \
    "a pending draft must force an unconditional GET instead of trusting the stale ETag"
  [ "$out" = "ocr-pr ppetermann/maia#9 ccc333" ] \
    || fail "the flip must wake even though GitHub's ETag did not change (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "9 ccc333 0" ] \
    || fail "the seen-state must record the ready state"
  # With nothing left draft, the ETag optimization resumes normally.
  : > "$home/gh.log"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "steady-ready exit"
  [ -z "$out" ] || fail "a stable ready PR must stay silent (got: $out)"
  assert_grep "cond=If-None-Match" "$home/gh.log" \
    "once nothing tracked is draft, the cached ETag must be used again"
  pass "fm-ocrbot-poll bypasses a stale cached ETag while a tracked PR is still draft"
}

test_poll_multiple_repos_and_prs() {
  local home fakebin out rc
  home="$TMP_ROOT/multi"; mkdir -p "$home/config/ocr-bot" \
    "$home/ghfix/ppetermann__maia" "$home/ghfix/ppetermann__eve-members"
  printf 'ppetermann/maia\nppetermann/eve-members\n' > "$home/config/ocr-bot/repos"
  printf '[{"number":7,"draft":false,"head":{"sha":"aaa111"}}]\n' \
    > "$home/ghfix/ppetermann__maia/body"
  printf '"etag-maia"\n' > "$home/ghfix/ppetermann__maia/etag"
  printf '[{"number":12,"draft":false,"head":{"sha":"bbb222"}},{"number":13,"draft":false,"head":{"sha":"ccc333"}}]\n' \
    > "$home/ghfix/ppetermann__eve-members/body"
  printf '"etag-eve"\n' > "$home/ghfix/ppetermann__eve-members/etag"
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "multi exit"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] \
    || fail "every new PR across repos must wake (got: $out)"
  assert_contains "$out" "ocr-pr ppetermann/maia#7 aaa111" "repo one must wake"
  assert_contains "$out" "ocr-pr ppetermann/eve-members#12 bbb222" "repo two PR one must wake"
  assert_contains "$out" "ocr-pr ppetermann/eve-members#13 ccc333" "repo two PR two must wake"
  assert_absent "$home/state/ocrbot/poll.error" "a clean cycle must leave no error marker"
  pass "fm-ocrbot-poll wakes per reviewable PR across every registered repo"
}

test_poll_closed_pr_leaves_seen_state() {
  local home fakebin out rc
  home="$TMP_ROOT/closed"; make_home "$home"
  set_listing "$home" 7:aaa111:false 8:bbb222:false
  fakebin=$(make_fake_gh "$home")
  run_poll "$home" "$fakebin" >/dev/null
  set_listing "$home" 7:aaa111:false
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "closed exit"
  [ -z "$out" ] || fail "a closed sibling must not wake the survivor (got: $out)"
  [ "$(cat "$home/state/ocrbot/seen/ppetermann__maia")" = "7 aaa111 0" ] \
    || fail "a closed PR must be pruned from the seen-state"
  pass "fm-ocrbot-poll prunes closed PRs from the durable seen-state"
}

test_poll_gh_failure_reports_once_and_recovers() {
  local home fakebin out rc
  home="$TMP_ROOT/gh-fail"; make_home "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  run_poll "$home" "$fakebin" >/dev/null
  printf 'gh: HTTP 401 Bad credentials\n' > "$home/ghfix/ppetermann__maia/fail-msg"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "gh-fail exit"
  [ "$out" = "ocrbot-error gh: HTTP 401 Bad credentials" ] \
    || fail "a gh failure must surface one diagnostic (got: $out)"
  assert_present "$home/state/ocrbot/poll.error" "the failure must leave a dedupe marker"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "gh-fail repeat exit"
  [ -z "$out" ] || fail "a repeated identical failure must be deduped (got: $out)"
  rm -f "$home/ghfix/ppetermann__maia/fail-msg"
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "gh-fail recovery exit"
  [ -z "$out" ] || fail "a recovered poll with no changes must stay silent (got: $out)"
  assert_absent "$home/state/ocrbot/poll.error" "a fully successful cycle must clear the marker"
  pass "fm-ocrbot-poll dedupes gh failures and clears them on recovery"
}

test_poll_unparseable_listing_reports_once() {
  local home fakebin out rc
  home="$TMP_ROOT/bad-body"; make_home "$home"
  printf 'not json\n' > "$home/ghfix/ppetermann__maia/body"
  fakebin=$(make_fake_gh "$home")
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "bad-body exit"
  [ "$out" = "ocrbot-error cannot parse the PR listing for ppetermann/maia" ] \
    || fail "an unparseable listing must error once (got: $out)"
  pass "fm-ocrbot-poll reports an unparseable listing as a config error"
}

# ---------------------------------------------------------------------------

test_bootstrap_arms_ocrbot_shim() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; make_home "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "OCRBOT: OCR review bot poll armed via state/ocrbot-watch.check.sh" \
    "bootstrap must announce the armed bot poll"
  assert_present "$home/state/ocrbot-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/ocrbot-watch.check.sh" ] || fail "the check shim must be executable"
  [ "$(path_mode "$home/state/ocrbot-watch.check.sh")" = 700 ] \
    || fail "the check shim must be a private file"
  assert_grep "fm-ocrbot-poll.sh" "$home/state/ocrbot-watch.check.sh" \
    "the shim must exec the trusted poll script"
  assert_absent "$home/config/x-mode.env" "arming the bot must not add a cadence override"
  sum1=$(cat "$home/state/ocrbot-watch.check.sh" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/ocrbot-watch.check.sh" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap ocrbot setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'ocrbot-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap arms the OCR review bot shim from config/ocr-bot, idempotently"
}

test_bootstrap_relative_home_writes_absolute_shim() {
  local root home out quoted_home
  root="$TMP_ROOT/boot-relative"
  mkdir -p "$root/home" "$root/cdpath/home"
  home=$(cd "$root/home" && pwd -P)
  mkdir -p "$home/config/ocr-bot"
  printf 'ppetermann/maia\n' > "$home/config/ocr-bot/repos"
  out=$(
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
  )
  assert_contains "$out" "OCRBOT: OCR review bot poll armed" \
    "relative-home bootstrap must announce the bot poll"
  quoted_home=$(printf '%q' "$home")
  assert_grep "export FM_HOME=$quoted_home" "$home/state/ocrbot-watch.check.sh" \
    "relative FM_HOME leaked into the durable bot poll shim"
  pass "bootstrap ignores CDPATH when writing absolute FM_HOME into the bot shim"
}

test_bootstrap_inert_without_config() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "OCRBOT:" "no config must say nothing about the bot"
  assert_absent "$home/state/ocrbot-watch.check.sh" "no config -> no shim"
  pass "bootstrap is inert without config/ocr-bot"
}

test_bootstrap_opt_out_removes_shim() {
  local home out
  home="$TMP_ROOT/boot-optout"; make_home "$home"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/ocrbot-watch.check.sh" "opt-in must create the shim first"
  rm -rf "$home/config/ocr-bot"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "OCRBOT: OCR review bot off" "opt-out must be announced when it removed the shim"
  assert_absent "$home/state/ocrbot-watch.check.sh" "opt-out must remove the shim"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "OCRBOT:" "steady-state off must be silent"
  pass "bootstrap removes the bot shim on opt-out and is silent once off"
}

test_bootstrap_rejects_linked_shim_destination() {
  local home target out
  home="$TMP_ROOT/boot-linked"
  mkdir -p "$home/config/ocr-bot" "$home/ghfix/ppetermann__maia" "$home/state"
  printf 'ppetermann/maia\n' > "$home/config/ocr-bot/repos"
  target="$home/external-shim"
  printf 'external sentinel\n' > "$target"
  chmod 0640 "$target"
  ln -s "$target" "$home/state/ocrbot-watch.check.sh"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "OCRBOT: OCR review bot off - failed to arm the poll shim" \
    "bootstrap must reject a linked shim destination"
  assert_not_contains "$out" "OCRBOT: OCR review bot poll armed" \
    "bootstrap must not announce arming after rejecting the destination"
  [ "$(cat "$target")" = "external sentinel" ] || fail "bootstrap changed the linked shim target"
  [ "$(path_mode "$target")" = 640 ] || fail "bootstrap changed the linked shim target mode"
  assert_absent "$home/state/ocrbot-watch.check.sh" "bootstrap must remove the rejected shim link"
  pass "bootstrap rejects a linked bot shim without touching its target"
}

# ---------------------------------------------------------------------------

run_flip() {
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_GH_STATE="$home/ghfix" \
    OCR_GH_LOG="$home/gh.log" "$ROOT/bin/fm-pr-flip.sh" "$@"
}

# Print the payload of every queued wake row, one per line.
queued_wakes() {
  awk -F '\t' '{ print $3 "|" $5 }' "$1/state/.wake-queue" 2>/dev/null
}

test_flip_queues_round_and_records_seen() {
  local home fakebin out rc
  home="$TMP_ROOT/flip-bot"; make_home "$home"
  set_listing "$home" 7:aaa111:false 9:ddd444:true
  fakebin=$(make_fake_gh "$home")
  run_poll "$home" "$fakebin" >/dev/null
  pr_json 9 ddd444 false > "$home/ghfix/ppetermann__maia/pr-9"
  : > "$home/gh.log"
  out=$(run_flip "$home" "$fakebin" https://github.com/PPetermann/Maia/pull/9 2>&1); rc=$?
  expect_code 0 "$rc" "bot-repo flip exit"
  assert_grep "pr-ready https://github.com/PPetermann/Maia/pull/9" "$home/gh.log" \
    "the helper must flip the PR"
  assert_contains "$out" "review queued: ocr-pr ppetermann/maia#9 ddd444" \
    "the helper must report the queued round in the registered spelling"
  [ "$(queued_wakes "$home")" = "check|check: $home/state/ocrbot-watch.check.sh: ocr-pr ppetermann/maia#9 ddd444" ] \
    || fail "the flip must queue exactly the poll's ocr-pr wake (got: $(queued_wakes "$home"))"
  [ "$(sort "$home/state/ocrbot/seen/ppetermann__maia")" = "$(printf '7 aaa111 0\n9 ddd444 0')" ] \
    || fail "the flip must record the PR as seen and ready at its head, keeping other PRs"
  [ "$(path_mode "$home/state/ocrbot/seen/ppetermann__maia")" = 600 ] \
    || fail "the seen-state must stay a private file"
  set_listing "$home" 7:aaa111:false 9:ddd444:false
  out=$(run_poll "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "post-flip poll exit"
  [ -z "$out" ] || fail "the poll must not wake a second time for a flip the helper queued (got: $out)"
  pass "fm-pr-flip queues one ocr-pr round and records the flipped head as seen"
}

test_flip_unregistered_repo_only_flips() {
  local home fakebin out rc
  home="$TMP_ROOT/flip-other"; make_home "$home"
  fakebin=$(make_fake_gh "$home")
  out=$(run_flip "$home" "$fakebin" https://github.com/ppetermann/other/pull/3 2>&1); rc=$?
  expect_code 0 "$rc" "unregistered flip exit"
  assert_grep "pr-ready https://github.com/ppetermann/other/pull/3" "$home/gh.log" \
    "the helper must still flip an unregistered repo's PR"
  assert_no_grep "pr-get" "$home/gh.log" "an unregistered repo must not be read back"
  assert_not_contains "$out" "review queued" "an unregistered repo must not queue a round"
  [ -z "$(queued_wakes "$home")" ] || fail "an unregistered repo must queue no wake"
  assert_absent "$home/state/ocrbot/seen" "an unregistered repo must record no seen-state"
  pass "fm-pr-flip only flips a PR on a repo the bot does not gate"
}

test_flip_failures_queue_nothing() {
  local home fakebin rc
  home="$TMP_ROOT/flip-fail"; make_home "$home"
  fakebin=$(make_fake_gh "$home")
  : > "$home/ghfix/ready-fail"
  run_flip "$home" "$fakebin" https://github.com/ppetermann/maia/pull/9 >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "failed flip exit"
  assert_no_grep "pr-get" "$home/gh.log" "a failed flip must not go on to read the PR"
  rm -f "$home/ghfix/ready-fail"
  run_flip "$home" "$fakebin" https://github.com/ppetermann/maia/pull/9 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "flip with an unreadable PR exit"
  pr_json 9 ddd444 true > "$home/ghfix/ppetermann__maia/pr-9"
  run_flip "$home" "$fakebin" https://github.com/ppetermann/maia/pull/9 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "flip that still reads as draft exit"
  [ -z "$(queued_wakes "$home")" ] || fail "no failed flip may queue a wake"
  assert_absent "$home/state/ocrbot/seen" "no failed flip may record seen-state"
  run_flip "$home" "$fakebin" https://gitlab.com/a/b/-/merge_requests/1 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "non-GitHub PR exit"
  pass "fm-pr-flip queues nothing when the flip or its read-back fails"
}

# Arm the bot shim directly from the library, so a watcher run sees exactly the
# bytes bootstrap would write without running bootstrap's other steps.
arm_shim() {
  local home=$1 shim=$1/state/ocrbot-watch.check.sh
  mkdir -p "$home/state"
  ( . "$ROOT/bin/fm-ocrbot-lib.sh" && ocrbot_poll_shim_content "$home" "$ROOT" ) > "$shim"
  chmod 700 "$shim"
}

run_watch() {
  local home=$1 fakebin=$2 seconds=$3; shift 3
  env PATH="$fakebin:$PATH" FM_HOME="$home" OCR_GH_STATE="$home/ghfix" OCR_GH_LOG="$home/gh.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$seconds" 2>/dev/null
}

test_watcher_polls_bot_on_its_own_interval() {
  local home fakebin out rc
  home="$TMP_ROOT/watch-own"; make_home "$home"; arm_shim "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  # The shared sweep ran just now and is not due again for a long time.
  touch "$home/state/.last-check"
  out=$(run_watch "$home" "$fakebin" 10 FM_CHECK_INTERVAL=999999); rc=$?
  expect_code 0 "$rc" "own-interval watcher exit"
  assert_contains "$out" "ocr-pr ppetermann/maia#7 aaa111" \
    "the bot poll must run on its own interval while the shared sweep is not due"
  assert_present "$home/state/.last-ocrbot-check" "the bot poll must track its own cadence marker"
  pass "the watcher polls the OCR bot apart from the shared check sweep"
}

test_watcher_shared_sweep_skips_bot() {
  local home fakebin rc
  home="$TMP_ROOT/watch-skip"; make_home "$home"; arm_shim "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  # The shared sweep is due (no .last-check), the bot's own cadence is not.
  touch "$home/state/.last-ocrbot-check"
  run_watch "$home" "$fakebin" 4 FM_CHECK_INTERVAL=999999 FM_OCRBOT_CHECK_INTERVAL=999999 >/dev/null; rc=$?
  expect_code 124 "$rc" "skip watcher exit"
  assert_present "$home/state/.last-check" "the shared sweep must still have run"
  assert_absent "$home/gh.log" "the shared sweep must not run the bot poll"
  pass "the shared check sweep leaves the OCR bot poll to its own interval"
}

test_watcher_bot_interval_capped_by_check_interval() {
  local home fakebin out rc
  home="$TMP_ROOT/watch-cap"; make_home "$home"; arm_shim "$home"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  touch "$home/state/.last-ocrbot-check" "$home/state/.last-check"
  out=$(run_watch "$home" "$fakebin" 10 FM_CHECK_INTERVAL=2 FM_OCRBOT_CHECK_INTERVAL=999999); rc=$?
  expect_code 0 "$rc" "capped watcher exit"
  assert_contains "$out" "ocr-pr ppetermann/maia#7 aaa111" \
    "the bot poll must never be slower than the shared sweep"
  pass "the OCR bot interval is capped at the shared check interval"
}

test_watcher_rejects_tampered_bot_shim() {
  local home fakebin out rc
  home="$TMP_ROOT/watch-tampered"; make_home "$home"; arm_shim "$home"
  printf '# tampered\n' >> "$home/state/ocrbot-watch.check.sh"
  set_listing "$home" 7:aaa111:false
  fakebin=$(make_fake_gh "$home")
  out=$(run_watch "$home" "$fakebin" 10 FM_CHECK_INTERVAL=999999); rc=$?
  expect_code 0 "$rc" "tampered-shim watcher exit"
  assert_contains "$out" "rejected unauthenticated state check" \
    "a shim that fails validation must be reported by the shared sweep"
  assert_absent "$home/gh.log" "a shim that fails validation must never run the poll"
  pass "the watcher rejects a tampered OCR bot shim instead of polling"
}

# ---------------------------------------------------------------------------

test_poll_no_config_is_hard_noop
test_poll_empty_repos_is_noop
test_poll_invalid_repos_entry_reports_once
test_poll_new_pr_wakes_then_stays_silent
test_poll_new_head_sha_wakes
test_poll_draft_lifecycle
test_poll_draft_pending_bypasses_stale_etag
test_poll_multiple_repos_and_prs
test_poll_closed_pr_leaves_seen_state
test_poll_gh_failure_reports_once_and_recovers
test_poll_unparseable_listing_reports_once
test_bootstrap_arms_ocrbot_shim
test_bootstrap_relative_home_writes_absolute_shim
test_bootstrap_inert_without_config
test_bootstrap_opt_out_removes_shim
test_bootstrap_rejects_linked_shim_destination
test_flip_queues_round_and_records_seen
test_flip_unregistered_repo_only_flips
test_flip_failures_queue_nothing
test_watcher_polls_bot_on_its_own_interval
test_watcher_shared_sweep_skips_bot
test_watcher_bot_interval_capped_by_check_interval
test_watcher_rejects_tampered_bot_shim
