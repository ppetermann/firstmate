#!/usr/bin/env bash
# Behavior tests for the OCR review bot poll process-event adapter
# (bin/fm-procevent-ocrbot.sh), driven through the real process-event runner,
# plus bootstrap's arming of it and the leftover-shim cleanup.
#
# GitHub is stubbed with a fakebin `gh` answering the listing read the poll
# makes and the two calls bin/fm-pr-flip.sh makes. No network call is made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-ocrbot-tests)
# The runner's claim store is machine-wide; keep this suite's claims private.
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
ADAPTER="$ROOT/bin/fm-procevent-ocrbot.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"

# Fixture files under $OCR_GH_STATE: body (the listing JSON), pr-<n> (one PR
# read back by the flip), sleep (seconds to stall the listing read).
make_fake_gh() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fakebin_write "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = ready ]; then
  echo "pr-ready $3" >> "$OCR_GH_LOG"
  exit 0
fi
case "${1:-} ${2:-}" in
  'api repos/'*/pulls/*)
    cat "${OCR_GH_STATE:?}/pr-${2##*/}" 2>/dev/null || exit 1
    exit 0
    ;;
esac
echo "list $(date +%s)" >> "$OCR_GH_LOG"
[ ! -f "$OCR_GH_STATE/sleep" ] || sleep "$(cat "$OCR_GH_STATE/sleep")"
printf 'HTTP/2.0 200 OK\r\nEtag: "e-%s"\r\n\r\n%s\n' "$(cksum < "$OCR_GH_STATE/body" | cut -d' ' -f1)" "$(cat "$OCR_GH_STATE/body")"
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

make_home() {  # <name> -> home path, opted in for ppetermann/maia
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config/ocr-bot" "$home/state" "$home/ghfix"
  chmod 700 "$home/state"
  printf 'ppetermann/maia\n' > "$home/config/ocr-bot/repos"
  : > "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

set_listing() {  # <home> <num:sha:draft>...
  local home=$1 body="[" sep="" spec
  shift
  for spec in "$@"; do
    IFS=: read -r num sha draft <<EOF
$spec
EOF
    body="$body$sep{\"number\":$num,\"draft\":$draft,\"head\":{\"sha\":\"$sha\"}}"
    sep=,
  done
  printf '%s]\n' "$body" > "$home/ghfix/body"
}

in_home() {  # <home> <fakebin> <command...>
  local home=$1 fakebin=$2
  shift 2
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    OCR_GH_STATE="$home/ghfix" OCR_GH_LOG="$home/gh.log" "$@"
}

# Run the source's runner for <seconds>, then stop it through the adapter's
# retire, which also stops the runner's blocking child.
run_source() {  # <home> <fakebin> <seconds>
  local home=$1 fakebin=$2 seconds=$3 pid
  in_home "$home" "$fakebin" "$RUNNER" start ocrbot-poll > "$home/start.out" 2>&1 &
  pid=$!
  sleep "$seconds"
  in_home "$home" "$fakebin" "$ADAPTER" retire >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

queued_rows() {  # <home> - kind|key|payload per queued row
  awk -F '\t' '{ print $3 "|" $4 "|" $5 }' "$1/state/.wake-queue" 2>/dev/null
}

drained_wakes() {
  FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null \
    | awk -F '\t' 'NF >= 5 { print $3 "|" $5 }'
}

label() { printf '%s/state/ocrbot-watch.check.sh\n' "$1"; }

test_poll_wakes_per_pr_and_acknowledges_its_capture() {
  local home fakebin rows
  home=$(make_home wakes); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false 8:bbb222:false 9:ccc333:false
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 1 >/dev/null || fail "arm refused an opted-in home"
  run_source "$home" "$fakebin" 3
  rows=$(queued_rows "$home" | grep -v '^check|procevent:')
  [ "$rows" = "$(printf 'check|%s ppetermann/maia#7|check: %s: ocr-pr ppetermann/maia#7 aaa111\ncheck|%s ppetermann/maia#8|check: %s: ocr-pr ppetermann/maia#8 bbb222\ncheck|%s ppetermann/maia#9|check: %s: ocr-pr ppetermann/maia#9 ccc333' \
    "$(label "$home")" "$(label "$home")" "$(label "$home")" "$(label "$home")" "$(label "$home")" "$(label "$home")")" ] \
    || fail "the poll did not queue one keyed row per PR (got: $rows)"
  [ "$(queued_rows "$home" | grep -c '^check|procevent:ocrbot-poll:1|check: procevent ocrbot ocrbot-poll 1$')" = 1 ] \
    || fail "the runner did not publish its own procevent row (got: $(queued_rows "$home"))"
  [ "$(drained_wakes "$home" | grep -c 'ocr-pr ppetermann/maia#')" = 3 ] \
    || fail "three PRs did not survive the drain as three review wakes (got: $(drained_wakes "$home"))"
  [ "$(in_home "$home" "$fakebin" "$RUNNER" handled ocrbot-poll 1)" = "already-handled: ocrbot-poll 1" ] \
    || fail "the adapter did not acknowledge its own capture"
  pass "the poll queues one keyed wake per PR and acknowledges its own capture"
}

test_poll_runs_on_its_interval() {
  local home fakebin n
  home=$(make_home cadence); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 1 >/dev/null || fail "arm failed"
  run_source "$home" "$fakebin" 4
  n=$(grep -c '^list ' "$home/gh.log")
  [ "$n" -ge 2 ] || fail "a 1-second interval polled only $n time(s) in 4 seconds: $(cat "$home/start.out")"

  home=$(make_home cadence-slow); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 999 >/dev/null || fail "arm failed"
  run_source "$home" "$fakebin" 4
  n=$(grep -c '^list ' "$home/gh.log")
  [ "$n" = 1 ] || fail "a 999-second interval polled $n times in 4 seconds"
  pass "the poll runs once per interval inside one runner"
}

test_hung_poll_is_cut_and_retried() {
  local home fakebin n
  home=$(make_home hung); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false
  printf '30\n' > "$home/ghfix/sleep"
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 1 >/dev/null || fail "arm failed"
  FM_OCRBOT_POLL_TIMEOUT=1 run_source "$home" "$fakebin" 6
  n=$(grep -c '^list ' "$home/gh.log")
  [ "$n" -ge 2 ] || fail "a hung listing read was not cut and retried (reads: $n)"
  queued_rows "$home" | grep -q 'ocr-pr' && fail "a cut poll queued a review wake"
  pass "a hung poll is cut at its bound and retried on the next interval"
}

test_opt_out_retires_the_source() {
  local home fakebin
  home=$(make_home optout); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 1 >/dev/null || fail "arm failed"
  rm -rf "$home/config/ocr-bot"
  run_source "$home" "$fakebin" 5
  grep -q '^retired: ocrbot-poll (adapter classified' "$home/start.out" \
    || fail "an opt-out did not retire the source: $(cat "$home/start.out")"
  [ ! -s "$home/gh.log" ] || fail "an opted-out home still polled GitHub"
  if in_home "$home" "$fakebin" "$ADAPTER" arm >/dev/null 2>&1; then
    fail "arm accepted a home without config/ocr-bot"
  fi
  pass "removing config/ocr-bot retires the source on its next cycle and arm refuses"
}

test_flip_and_poll_for_one_head_collapse() {
  local home fakebin
  home=$(make_home collapse); fakebin=$(make_fake_gh "$home")
  set_listing "$home" 7:aaa111:false 9:ddd444:false
  in_home "$home" "$fakebin" "$ADAPTER" arm --interval 1 >/dev/null || fail "arm failed"
  run_source "$home" "$fakebin" 3
  printf '{"number":9,"draft":false,"head":{"sha":"ddd444"}}\n' > "$home/ghfix/pr-9"
  in_home "$home" "$fakebin" "$ROOT/bin/fm-pr-flip.sh" https://github.com/ppetermann/maia/pull/9 >/dev/null 2>&1 \
    || fail "the flip failed"
  [ "$(drained_wakes "$home" | grep 'ocr-pr')" = "$(printf 'check|check: %s: ocr-pr ppetermann/maia#7 aaa111\ncheck|check: %s: ocr-pr ppetermann/maia#9 ddd444' \
    "$(label "$home")" "$(label "$home")")" ] \
    || fail "a flip of a polled head did not collapse into the poll's wake (got: $(drained_wakes "$home"))"
  pass "the poll keeps one wake per PR and a flip of the same head collapses into it"
}

test_bootstrap_arms_and_retires_the_source() {
  local home fakebin out
  home=$(make_home boot); fakebin=$(make_fake_gh "$home")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/ocrbot-watch.check.sh"
  chmod 700 "$home/state/ocrbot-watch.check.sh"
  out=$(in_home "$home" "$fakebin" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "OCRBOT: OCR review bot poll armed as process-event source ocrbot-poll" \
    "bootstrap must announce the armed source"
  in_home "$home" "$fakebin" "$RUNNER" list | grep -q '^ocrbot-poll ' || fail "bootstrap did not register the source"
  assert_absent "$home/state/ocrbot-watch.check.sh" "bootstrap must remove the legacy watcher shim"
  in_home "$home" "$fakebin" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  [ "$(find "$home/state/procevent" -name 'ocrbot-poll*.source' | wc -l | tr -d ' ')" = 1 ] \
    || fail "a second bootstrap duplicated the registration"
  rm -rf "$home/config/ocr-bot"
  out=$(in_home "$home" "$fakebin" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "OCRBOT: OCR review bot off" "opt-out must be announced when it retired the source"
  [ "$(in_home "$home" "$fakebin" "$RUNNER" list)" = "no sources registered" ] || fail "opt-out did not retire the source"
  out=$(in_home "$home" "$fakebin" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "OCRBOT:" "steady-state off must be silent"
  pass "bootstrap arms the source idempotently, removes the legacy shim, and retires it on opt-out"
}

test_bootstrap_inert_without_config() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "OCRBOT:" "no config must say nothing about the bot"
  [ ! -e "$home/state/procevent/ocrbot-poll.source" ] || fail "no config must register no source"
  pass "bootstrap is inert without config/ocr-bot"
}

test_poll_wakes_per_pr_and_acknowledges_its_capture
test_poll_runs_on_its_interval
test_hung_poll_is_cut_and_retried
test_opt_out_retires_the_source
test_flip_and_poll_for_one_head_collapse
test_bootstrap_arms_and_retires_the_source
test_bootstrap_inert_without_config
