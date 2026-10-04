#!/usr/bin/env bash
# tests/fm-maia-notify.test.sh - opt-in maia notifications: bin/fm-maia-notify.sh
# send, flush and follow, plus its hooks in bin/fm-captain-hold.sh and the
# watcher. docs/maia-notify.md owns the operator contract. Every delivery goes
# through the FM_MAIA_NOTIFY_EXEC seam or a closed local port, never a real maia.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-maia-notify)
NOTIFY="$ROOT/bin/fm-maia-notify.sh"
TOKEN="mfm_test-token-value-0123456789"

# Sets HOME_DIR FAKEBIN REC for one isolated case. <on|off> writes the config.
make_case() {  # <name> <on|off> [extra config line...]
  local name=$1 mode=$2 line
  shift 2
  HOME_DIR="$TMP_ROOT/$name/home"
  REC="$TMP_ROOT/$name/rec"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$REC"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name")
  # The transport fake records its argv and body, then answers the status
  # named in $REC/status (default 202).
  fm_fakebin_write "$FAKEBIN/maia-post" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_REC/argv"
cat >> "$FM_TEST_REC/bodies"
printf '\n' >> "$FM_TEST_REC/bodies"
cat "$FM_TEST_REC/status" 2>/dev/null || printf '202'
SH
  chmod +x "$FAKEBIN/maia-post"
  if [ "$mode" = on ]; then
    {
      printf 'url=http://maia.test/pub/plugins/firstmate/notify\n'
      printf 'token=%s\n' "$TOKEN"
      for line in "$@"; do printf '%s\n' "$line"; done
    } > "$HOME_DIR/config/maia-notify"
    chmod 600 "$HOME_DIR/config/maia-notify"
  fi
}

in_home() {  # <command...>
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_TEST_REC="$REC" FM_MAIA_NOTIFY_EXEC="$FAKEBIN/maia-post" \
    FM_MAIA_NOTIFY_FLUSH="${FLUSH_MODE:-sync}" PATH="$FAKEBIN:$PATH" "$@"
}

spool_count() {
  find "$HOME_DIR/state/maia-notify/spool" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

bodies() {
  cat "$REC/bodies" 2>/dev/null || true
}

test_off_without_config() {
  local out
  make_case off off
  out=$(in_home "$NOTIFY" send decision project=p task=t 2>&1) || fail "send failed while off: $out"
  in_home "$NOTIFY" flush >/dev/null 2>&1 || fail "flush failed while off"
  : > "$HOME_DIR/config/fleet-ledger"
  printf '{"v":1,"ts":1,"event":"task.merged","task":"t","via":"local"}\n' > "$HOME_DIR/state/fleet-ledger.jsonl"
  in_home "$NOTIFY" follow >/dev/null 2>&1 || fail "follow failed while off"
  assert_equals "" "$out" "send output while off"
  assert_absent "$HOME_DIR/state/maia-notify" "notify state while off"
  assert_absent "$REC/bodies" "transport calls while off"
  pass "off: without config/maia-notify, send, flush and follow write and send nothing"
}

test_send_delivers_with_token_only_in_the_body() {
  local body
  make_case deliver on
  in_home "$NOTIFY" send deployed --id deployed:z2m-mcp:v0.4.2 project=z2m-mcp version=v0.4.2 key=shadow \
    || fail "send failed"
  body=$(bodies)
  assert_equals "deployed" "$(printf '%s' "$body" | jq -r .key)" "body key"
  assert_equals "deployed:z2m-mcp:v0.4.2" "$(printf '%s' "$body" | jq -r .id)" "body id"
  assert_equals "$TOKEN" "$(printf '%s' "$body" | jq -r .token)" "body token"
  assert_equals '{"project":"z2m-mcp","version":"v0.4.2","key":"shadow"}' \
    "$(printf '%s' "$body" | jq -c .vars)" "body vars, including one named like a member"
  assert_equals "http://maia.test/pub/plugins/firstmate/notify" "$(cat "$REC/argv")" "transport argv"
  assert_equals 0 "$(spool_count)" "spool after a 202"
  assert_grep "delivered key=deployed id=deployed:z2m-mcp:v0.4.2 status=202" "$HOME_DIR/state/maia-notify/log" "log or capture check: delivered key=deployed id=deployed:z2m-mcp:v0.4.2 status=202"
  assert_no_grep "$TOKEN" "$HOME_DIR/state/maia-notify/log" "log or capture check: TOKEN"
  assert_no_grep "z2m-mcp version" "$HOME_DIR/state/maia-notify/log" "log or capture check: z2m-mcp version"
  pass "send: the notification is delivered with key, id and vars, and the token reaches only the request body"
}

test_token_never_in_spool_or_argv() {
  local file
  make_case spool-private on
  FLUSH_MODE=none in_home "$NOTIFY" send decision --id d1 project=p question="pick one" || fail "send failed"
  assert_equals 1 "$(spool_count)" "spooled files"
  file=$(find "$HOME_DIR/state/maia-notify/spool" -name '*.json')
  assert_no_grep "$TOKEN" "$file" "log or capture check: TOKEN"
  case "${file##*/}" in *mfm*|*token*) fail "spool file name carries token material: ${file##*/}" ;; esac
  # Real curl against a closed local port: its argv must not carry the token.
  printf 'url=http://127.0.0.1:9/notify\ntoken=%s\n' "$TOKEN" > "$HOME_DIR/config/maia-notify"
  fm_fakebin_write "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC/curl-argv"
cat > "$REC/curl-stdin"
printf '000'
exit 7
SH
  chmod +x "$FAKEBIN/curl"
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN:$PATH" "$NOTIFY" flush \
    || fail "flush failed"
  assert_no_grep "$TOKEN" "$REC/curl-argv" "log or capture check: TOKEN"
  assert_grep "$TOKEN" "$REC/curl-stdin" "log or capture check: TOKEN"
  assert_equals 1 "$(spool_count)" "spool after an unreachable maia"
  pass "token: never in a spool file, its name, or the HTTP client's argv; it reaches curl on stdin"
}

test_maia_down_keeps_the_spool_and_returns_fast() {
  local start end
  make_case down on
  printf 'url=http://127.0.0.1:9/notify\ntoken=%s\n' "$TOKEN" > "$HOME_DIR/config/maia-notify"
  start=$(date +%s)
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_MAIA_NOTIFY_FLUSH=sync \
    "$NOTIFY" send merged --id m1 project=p || fail "send failed with maia down"
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_MAIA_NOTIFY_FLUSH=sync \
    "$NOTIFY" send failed --id f1 project=p || fail "second send failed with maia down"
  end=$(date +%s)
  [ $((end - start)) -le 12 ] || fail "two sends with maia down took $((end - start))s"
  assert_equals 2 "$(spool_count)" "spool with maia down"
  assert_grep "retry key=merged id=m1: maia unreachable" "$HOME_DIR/state/maia-notify/log" "log or capture check: retry key=merged id=m1: maia unreachable"
  # A background send returns at once even though delivery cannot finish.
  start=$(date +%s)
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$NOTIFY" send merged --id m2 project=p || fail "background send failed"
  end=$(date +%s)
  [ $((end - start)) -le 2 ] || fail "a background send blocked for $((end - start))s"
  pass "maia down: send exits 0, the spool keeps every notification for a later flush, and a background send never waits"
}

test_retry_classes() {
  local status
  for status in 200:0 202:0 400:0 401:0 413:0 429:1 502:1 503:1 000:1; do
    make_case "class-${status%%:*}" on
    printf '%s' "${status%%:*}" > "$REC/status"
    in_home "$NOTIFY" send merged --id "c-${status%%:*}" project=p || fail "send failed for ${status%%:*}"
    assert_equals "${status##*:}" "$(spool_count)" "spool after HTTP ${status%%:*}"
  done
  pass "flush: 2xx and 4xx other than 429 remove the notification; 429, 5xx and no answer keep it"
}

test_ttl_drops_old_notifications() {
  make_case ttl on ttl=60
  printf '503' > "$REC/status"
  FM_MAIA_NOTIFY_NOW=1000 in_home "$NOTIFY" send deployed --id t1 project=p || fail "send failed"
  assert_equals 1 "$(spool_count)" "spool after a 503"
  FM_MAIA_NOTIFY_NOW=1050 in_home "$NOTIFY" flush || fail "flush failed"
  assert_equals 1 "$(spool_count)" "spool within the ttl"
  FM_MAIA_NOTIFY_NOW=1061 in_home "$NOTIFY" flush || fail "flush failed"
  assert_equals 0 "$(spool_count)" "spool past the ttl"
  assert_grep "expired key=deployed id=t1" "$HOME_DIR/state/maia-notify/log" "log or capture check: expired key=deployed id=t1"
  pass "ttl: a notification still undelivered past the ttl is dropped with one log line"
}

test_event_selection() {
  make_case events-default on
  in_home "$NOTIFY" send blocked project=p || fail "send blocked failed"
  in_home "$NOTIFY" send pr-ready project=p || fail "send pr-ready failed"
  assert_absent "$REC/bodies" "default-off keys sent"
  for key in decision merge-ready merged deployed failed; do
    in_home "$NOTIFY" send "$key" --id "e-$key" project=p || fail "send $key failed"
  done
  assert_equals "decision merge-ready merged deployed failed" \
    "$(bodies | jq -r .key | tr '\n' ' ' | sed 's/ $//')" "default-on keys sent"
  make_case events-custom on 'events=blocked, custom-key'
  in_home "$NOTIFY" send decision project=p || fail "send decision failed"
  in_home "$NOTIFY" send blocked project=p || fail "send blocked failed"
  in_home "$NOTIFY" send custom-key project=p || fail "send custom-key failed"
  assert_equals "blocked custom-key" "$(bodies | jq -r .key | tr '\n' ' ' | sed 's/ $//')" "configured keys sent"
  pass "events: decision, merge-ready, merged, deployed and failed are on by default; the config's events list replaces them"
}

test_input_validation() {
  local long i rc
  local -a many=()
  make_case validate on
  in_home "$NOTIFY" send Bad_Key project=p || fail "a bad key changed the exit status"
  in_home "$NOTIFY" send decision Project=p || fail "a bad variable name changed the exit status"
  for i in $(seq 1 17); do many+=("v$i=x"); done
  in_home "$NOTIFY" send decision "${many[@]}" || fail "too many variables changed the exit status"
  assert_absent "$REC/bodies" "invalid notifications sent"
  rc=0; in_home "$NOTIFY" send 2>/dev/null || rc=$?
  expect_code 2 "$rc" "send without a key"
  rc=0; in_home "$NOTIFY" send decision stray-word 2>/dev/null || rc=$?
  expect_code 2 "$rc" "send with a stray word"
  long=$(printf 'é%.0s' $(seq 1 300))
  in_home "$NOTIFY" send decision project=p question="$long
second line" || fail "send failed"
  assert_equals 200 "$(bodies | jq -r '.vars.question | length')" "value length in characters"
  assert_contains "$(bodies | jq -r .vars.question)" "…" "cut marker"
  assert_not_contains "$(bodies | jq -r .vars.question)" $'\n' "control characters"
  pass "input: bad keys, bad names and more than 16 variables are dropped; values are cut to 200 characters without control characters"
}

test_spool_cap() {
  local i oldest
  make_case cap on
  mkdir -p "$HOME_DIR/state/maia-notify/spool"
  for i in $(seq 100 299); do
    printf '{"key":"merged","created":%s,"vars":{}}\n' "$(date +%s)" \
      > "$HOME_DIR/state/maia-notify/spool/1000000$i-1-1.json"
  done
  oldest="$HOME_DIR/state/maia-notify/spool/1000000100-1-1.json"
  FLUSH_MODE=none in_home "$NOTIFY" send merged --id newest project=p || fail "send failed"
  assert_equals 200 "$(spool_count)" "spool size at the cap"
  assert_absent "$oldest" "the oldest spool file"
  pass "spool: at 200 files the oldest is dropped to make room"
}

# Writes state/<task>.meta naming a project directory.
write_task_meta() {  # <task> <project>
  printf 'project=%s/projects/%s/\n' "$HOME_DIR" "$2" > "$HOME_DIR/state/$1.meta"
}

test_follow_maps_ledger_records() {
  local ledger
  make_case follow on
  : > "$HOME_DIR/config/fleet-ledger"
  ledger="$HOME_DIR/state/fleet-ledger.jsonl"
  write_task_meta t1 webapp
  write_task_meta t2 maia
  printf '{"v":1,"ts":5,"event":"task.merged","task":"old","via":"local"}\n' > "$ledger"
  in_home "$NOTIFY" follow || fail "first follow failed"
  assert_absent "$REC/bodies" "history replayed on the first follow"
  {
    printf '{"v":1,"ts":10,"event":"task.merged","task":"t1","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}\n'
    printf '{"v":1,"ts":11,"event":"task.merged","task":"t2","via":"local"}\n'
    printf '{"v":1,"ts":12,"event":"task.status","task":"t1","state":"failed","key":null,"text":" tests broke\\nbadly"}\n'
    printf '{"v":1,"ts":13,"event":"task.status","task":"t1","state":"blocked","key":null,"text":" need help"}\n'
    printf '{"v":1,"ts":14,"event":"task.status","task":"t1","state":"working","key":null,"text":" busy"}\n'
    printf '{"v":1,"ts":15,"event":"task.pr_ready","task":"t1","pr":"https://github.com/acme/webapp/pull/7"}\n'
    printf '{"v":1,"ts":16,"event":"task.future_event","task":"t1"}\n'
    printf 'not json\n'
    printf '{"v":1,"ts":17,"event":"task.merged","task":"t2","via":"pr","pr":"https://github.com/acme/maia/pull/9"}'
  } >> "$ledger"
  in_home "$NOTIFY" follow || fail "second follow failed"
  assert_equals '{"key":"merged","id":"merged:https://github.com/acme/webapp/pull/7","vars":{"project":"webapp","task":"t1","pr_url":"https://github.com/acme/webapp/pull/7","pr_number":"7","via":"pr"}}
{"key":"merged","id":"merged:local:t2","vars":{"project":"maia","task":"t2","via":"local"}}
{"key":"failed","id":"failed:t1:12","vars":{"project":"webapp","task":"t1","text":"tests broke badly"}}' \
    "$(bodies | jq -c 'del(.token)')" "mapped notifications"
  # The partial last line waits; completing it delivers it once.
  printf '\n' >> "$ledger"
  in_home "$NOTIFY" follow || fail "third follow failed"
  assert_equals "merged:https://github.com/acme/maia/pull/9" "$(bodies | jq -r .id | tail -n 1)" "completed line"
  assert_equals 4 "$(bodies | jq -r .id | wc -l | tr -d ' ')" "notifications after the partial line completed"
  in_home "$NOTIFY" follow || fail "idle follow failed"
  assert_equals 4 "$(bodies | jq -r .id | wc -l | tr -d ' ')" "notifications after an idle follow"
  # A truncated ledger is read again from its start.
  printf '{"v":1,"ts":20,"event":"task.status","task":"t2","state":"failed","key":null,"text":"x"}\n' > "$ledger"
  in_home "$NOTIFY" follow || fail "follow after truncation failed"
  assert_equals "failed:t2:20" "$(bodies | jq -r .id | tail -n 1)" "record after truncation"
  pass "follow: merges and failures map to keys with project, PR and ids; history, off keys, unknown records and partial lines are not sent"
}

test_follow_flushes_without_the_ledger() {
  make_case follow-flush on
  printf '503' > "$REC/status"
  in_home "$NOTIFY" send deployed --id r1 project=p || fail "send failed"
  assert_equals 1 "$(spool_count)" "spool after a 503"
  rm -f "$REC/status"
  in_home "$NOTIFY" follow || fail "follow failed"
  assert_equals 0 "$(spool_count)" "spool after follow retried it"
  assert_absent "$HOME_DIR/state/maia-notify/follow-offset" "ledger offset with the ledger off"
  pass "follow: retries the spool even when the fleet ledger is off"
}

test_dedup_ids_are_stable() {
  make_case dedup on
  : > "$HOME_DIR/config/fleet-ledger"
  write_task_meta t1 webapp
  : > "$HOME_DIR/state/fleet-ledger.jsonl"
  in_home "$NOTIFY" follow || fail "first follow failed"
  # An interrupted capture can repeat a record; both carry the same id, so the
  # plugin's dedup absorbs the repeat.
  printf '{"v":1,"ts":10,"event":"task.merged","task":"t1","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}\n%.0s' 1 2 \
    >> "$HOME_DIR/state/fleet-ledger.jsonl"
  in_home "$NOTIFY" follow || fail "second follow failed"
  assert_equals "merged:https://github.com/acme/webapp/pull/7
merged:https://github.com/acme/webapp/pull/7" "$(bodies | jq -r .id)" "repeated record ids"
  in_home "$NOTIFY" send decision project=p || fail "send without id failed"
  assert_equals "null" "$(bodies | jq -r .id | tail -n 1)" "id left to the plugin when none is given"
  pass "dedup: a repeated ledger record carries the same id, and a send without --id leaves the id to the plugin"
}

# --- hook: bin/fm-captain-hold.sh ---

run_hold() {  # <args...>
  (cd "$HOME_DIR" && FLUSH_MODE=none in_home "$ROOT/bin/fm-captain-hold.sh" hold "$@" >/dev/null 2>&1)
}

decision_spool() {
  find "$HOME_DIR/state/maia-notify/spool" -maxdepth 1 -name '*.json' -exec cat {} + 2>/dev/null \
    | jq -c '{key, id, vars}'
}

test_captain_hold_sends_decision_once() {
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  make_case hold on
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
  FM_CAPTAIN_HOLD_NOW=2026-10-03T10:00:00Z run_hold pick-db --title "Pick a database" --repo webapp \
    --reason "Postgres or SQLite?" || fail "hold failed"
  assert_equals '{"key":"decision","id":"decision:pick-db:2026-10-03T10:00:00Z","vars":{"project":"webapp","task":"pick-db","title":"Pick a database","question":"Postgres or SQLite?"}}' \
    "$(decision_spool)" "decision notification"
  FM_CAPTAIN_HOLD_NOW=2026-10-03T11:00:00Z run_hold pick-db --reason "Postgres or SQLite?" \
    || fail "repeated hold failed"
  assert_equals 1 "$(spool_count)" "notifications after a repeated hold"
  FM_CAPTAIN_HOLD_NOW=2026-10-03T12:00:00Z run_hold later-call --title "Later call" --repo webapp \
    --reason "Revisit next week" --until 2026-10-10 || fail "deferred hold failed"
  assert_equals 1 "$(spool_count)" "notifications after an --until deferral"
  rm -f "$HOME_DIR/config/maia-notify"
  rm -rf "$HOME_DIR/state/maia-notify"
  FM_CAPTAIN_HOLD_NOW=2026-10-03T13:00:00Z run_hold quiet-call --title "Quiet call" --repo webapp \
    --reason "No config" || fail "hold without config failed"
  assert_absent "$HOME_DIR/state/maia-notify" "notify state without config"
  pass "captain hold: a newly set hold sends one decision notification; a repeat, a deferral, or an absent config sends none"
}

# --- hold grace: a decision waits, then is re-checked against the backlog ---

hold_case() {  # <name>
  make_case "$1" on
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
}

flush_at() {  # <epoch>
  (cd "$HOME_DIR" && FM_MAIA_NOTIFY_NOW=$1 in_home "$NOTIFY" flush >/dev/null 2>&1)
}

test_decision_grace_sends_a_still_held_task() {
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  hold_case grace-held
  FM_MAIA_NOTIFY_NOW=1000 run_hold held-call --title "Held call" --repo webapp --reason "Which?" || fail "hold failed"
  # run_hold uses the real clock for created; rewrite the spool times to the test clock.
  local f
  f=$(find "$HOME_DIR/state/maia-notify/spool" -name '*.json')
  jq -c '.created = 1000 | .not_before = 1120' "$f" > "$f.new" && mv "$f.new" "$f"
  flush_at 1119
  assert_equals 1 "$(spool_count)" "spool inside the grace"
  assert_equals "" "$(bodies)" "bodies inside the grace"
  flush_at 1121
  assert_equals 0 "$(spool_count)" "spool after the grace"
  assert_equals decision "$(bodies | jq -r .key)" "delivered key"
  assert_equals null "$(bodies | jq -r .hold_task)" "hold_task is not posted"
  pass "grace: a decision waits out the grace, then is sent while its task is still held"
}

test_decision_grace_drops_an_answered_task() {
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  hold_case grace-answered
  run_hold answered-call --title "Answered call" --repo webapp --reason "Which?" || fail "hold failed"
  printf 'go with A\n' > "$HOME_DIR/answer.txt"
  (cd "$HOME_DIR" && in_home "$ROOT/bin/fm-captain-hold.sh" answer answered-call --decision-file "$HOME_DIR/answer.txt" >/dev/null 2>&1) \
    || fail "answer failed"
  flush_at $(( $(date +%s) + 200 ))
  assert_equals 0 "$(spool_count)" "spool after an answer"
  assert_equals "" "$(bodies)" "bodies after an answer"
  assert_grep "task no longer held" \
    "$HOME_DIR/state/maia-notify/log" "log or capture check: dropped decision"
  pass "grace: a decision whose task was answered inside the grace is dropped with one log line"
}

test_decision_grace_sends_when_state_is_unreadable() {
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  hold_case grace-unreadable
  run_hold unread-call --title "Unread call" --repo webapp --reason "Which?" || fail "hold failed"
  rm -f "$HOME_DIR/data/backlog.md"
  mkdir "$HOME_DIR/data/backlog.md"
  flush_at $(( $(date +%s) + 200 ))
  assert_equals 0 "$(spool_count)" "spool with unreadable state"
  assert_equals decision "$(bodies | jq -r .key)" "delivered key with unreadable state"
  pass "grace: an unreadable backlog sends the decision rather than dropping it"
}

test_non_decision_keys_are_immediate() {
  make_case immediate on
  in_home "$NOTIFY" send merged --id m1 project=p || fail "send failed"
  in_home "$NOTIFY" send decision --id d1 project=p || fail "send without --check-hold failed"
  assert_equals 0 "$(spool_count)" "spool after immediate sends"
  assert_equals "merged decision" "$(bodies | jq -r .key | tr '\n' ' ' | sed 's/ $//')" "immediate keys"
  pass "grace: keys without --check-hold, such as merged, are delivered immediately"
}

# --- hook: the watcher ---

test_watcher_drives_follow() {
  local i
  make_case watcher on
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes
  printf '503' > "$REC/status"
  FLUSH_MODE=none in_home "$NOTIFY" send deployed --id w1 project=p || fail "send failed"
  rm -f "$REC/status"
  in_home env -u FM_TRACE_CONTEXT HOME="$HOME_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    TMUX="fake,1,0" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 >/dev/null 2>&1 || true
  for i in $(seq 1 50); do
    [ "$(spool_count)" = 0 ] && break
    sleep 0.1
  done
  assert_equals 0 "$(spool_count)" "spool after a watcher poll"
  assert_grep "delivered key=deployed id=w1" "$HOME_DIR/state/maia-notify/log" "log or capture check: delivered key=deployed id=w1"
  pass "watcher: a poll runs follow in the background, which delivers what the spool holds"
}

test_off_without_config
test_send_delivers_with_token_only_in_the_body
test_token_never_in_spool_or_argv
test_maia_down_keeps_the_spool_and_returns_fast
test_retry_classes
test_ttl_drops_old_notifications
test_event_selection
test_input_validation
test_spool_cap
test_follow_maps_ledger_records
test_follow_flushes_without_the_ledger
test_dedup_ids_are_stable
test_captain_hold_sends_decision_once
test_decision_grace_sends_a_still_held_task
test_decision_grace_drops_an_answered_task
test_decision_grace_sends_when_state_is_unreadable
test_non_decision_keys_are_immediate
test_watcher_drives_follow
