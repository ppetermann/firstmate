#!/usr/bin/env bash
# tests/fm-dispatch-facts.test.sh - behavior tests for bin/fm-dispatch-facts.sh.
#
# The stamp is a pure producer: a fixed clock (FM_DISPATCH_FACTS_NOW), a fake
# quota-axi on PATH emitting canned schema-v5 JSON, and fixture config dirs
# cover the peak-window boundaries (Beijing interpretation, end-exclusive),
# exact field extraction from the v5 schema, the unavailable/unknown
# degradations, quota staleness past 600 s, malformed-config refusal naming
# the file, and the missing-dependency exit paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FACTS="$ROOT/bin/fm-dispatch-facts.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-facts-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(dirname "$(command -v jq)") || fail "jq is required to test fm-dispatch-facts"

make_case() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/config" "$dir/home"
  fm_fakebin_write "$dir/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'quota-axi 0.1.51\n'
  exit 0
fi
if [ "${1:-}" = --json ]; then
  cat "$(dirname "$0")/../quota.json"
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/quota-axi"
  printf '%s\n' "$dir"
}

epoch_utc() {  # <YYYY-MM-DDTHH:MM:SSZ> -> epoch seconds (GNU -d, BSD -j -f)
  local iso=$1
  if date -u -d "$iso" +%s >/dev/null 2>&1; then
    date -u -d "$iso" +%s
  else
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
  fi
}

iso_utc() {  # <epoch> -> the script's at= rendering under TZ=UTC
  local epoch=$1
  if LC_ALL=C TZ=UTC date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z >/dev/null 2>&1; then
    LC_ALL=C TZ=UTC date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z
  else
    LC_ALL=C TZ=UTC date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z
  fi
}

iso_z() {  # <epoch> -> generatedAt shape (whole-second Z suffix)
  local epoch=$1
  if date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
  fi
}

run_facts() {  # <dir> [extra env assignments...] -> OUT, RC, ERR
  local dir=$1
  shift
  OUT=$(env PATH="$dir/fakebin:$JQ_DIR:$BASE_PATH" FM_HOME="$dir/home" \
    FM_CONFIG_OVERRIDE="$dir/config" TZ=UTC "$@" "$FACTS" 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
}

# The canned v5 fixture, modeled on a live quota-axi capture: claude carries
# the five_hour window plus all_models and model-scoped availability (spend
# known only on the model scope), zai carries all_models with full pace data
# plus a tools scope with nothing.
write_quota_json() {  # <dir> <generatedAt-epoch> [drop-zai]
  local dir=$1 gen=$2 zai_block claude_block
  zai_block='{
      "provider": "zai",
      "state": { "status": "fresh", "stale": false },
      "windows": [ { "id": "five_hour", "kind": "session", "percentRemaining": 87 } ],
      "quotaSemantics": { "effectiveAvailability": [
        { "scope": "all_models", "effectivePercentRemaining": 87,
          "selection": { "status": "known", "spendPriority": 2.5 },
          "pace": { "worstReservePercentPoints": 39.5, "worstReserveWindowId": "five_hour" } },
        { "scope": "tools", "effectivePercentRemaining": 100,
          "selection": { "status": "unknown" },
          "pace": { "worstReservePercentPoints": null, "worstReserveWindowId": null } }
      ] }
    }'
  [ "${3:-}" = drop-zai ] && zai_block=''
  claude_block='{
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 42 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 90 }
      ],
      "quotaSemantics": { "effectiveAvailability": [
        { "scope": "all_models", "effectivePercentRemaining": 42,
          "selection": { "status": "unknown" },
          "pace": { "worstReservePercentPoints": -3, "worstReserveWindowId": "five_hour" } },
        { "scope": "model:fable", "effectivePercentRemaining": 81,
          "selection": { "status": "known", "spendPriority": -1.25 },
          "pace": { "worstReservePercentPoints": -2, "worstReserveWindowId": "model:fable" } }
      ] }
    }'
  {
    printf '{\n  "generatedAt": "%s",\n  "schemaVersion": 5,\n  "providers": [\n' "$(iso_z "$gen")"
    printf '%s' "$claude_block"
    [ -n "$zai_block" ] && printf ',\n%s' "$zai_block"
    printf '\n  ]\n}\n'
  } > "$dir/quota.json"
}

test_stamp_fields_and_peak_boundaries() {
  local dir now expected rest
  # Wednesday 15:00 Beijing (07:00Z) is inside the default 14:00-18:00 window.
  dir=$(make_case peak-inside)
  now=$(epoch_utc 2026-08-26T07:00:00Z)
  write_quota_json "$dir" "$now"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "peak-inside stamp must succeed"
  expected="dispatch-facts at=$(iso_utc "$now") beijing=15:00-Wed peak=yes zai_worst=five_hour:87%:reserve=39.5pp claude_5h=42% spend=claude/all:unknown,claude/model:fable:-1.25,zai/all:2.5,zai/tools:unknown quota_age=0s"
  [ "$OUT" = "$expected" ] || fail "peak-inside stamp mismatch:
--want--
$expected
--got--
$OUT"

  # 13:59 Beijing is one minute early: peak=no.
  dir=$(make_case peak-before)
  now=$(epoch_utc 2026-08-26T05:59:00Z)
  write_quota_json "$dir" "$now"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "peak-before stamp must succeed"
  case $OUT in
    *" beijing=13:59-Wed peak=no "*) : ;;
    *) fail "peak-before boundary wrong: $OUT" ;;
  esac

  # 18:00 Beijing exactly is end-exclusive: peak=no.
  dir=$(make_case peak-at-end)
  now=$(epoch_utc 2026-08-26T10:00:00Z)
  write_quota_json "$dir" "$now"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "peak-at-end stamp must succeed"
  case $OUT in
    *" beijing=18:00-Wed peak=no "*) : ;;
    *) fail "peak-at-end boundary wrong: $OUT" ;;
  esac

  # Saturday 15:00 Beijing is outside Mon-Fri: peak=no.
  dir=$(make_case peak-weekend)
  now=$(epoch_utc 2026-08-29T07:00:00Z)
  write_quota_json "$dir" "$now"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "peak-weekend stamp must succeed"
  case $OUT in
    *" beijing=15:00-Sat peak=no "*) : ;;
    *) fail "peak-weekend day-set wrong: $OUT" ;;
  esac

  # A config window widens the rule: 09:30-19:00 daily makes Sunday 10:00 peak.
  dir=$(make_case peak-config-daily)
  now=$(epoch_utc 2026-08-23T02:00:00Z)
  write_quota_json "$dir" "$now"
  printf '09:30-19:00 Mon-Sun\n' > "$dir/config/zai-peak-window"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "config-window stamp must succeed"
  case $OUT in
    *" beijing=10:00-Sun peak=yes "*) : ;;
    *) fail "config window daily set wrong: $OUT" ;;
  esac
  pass "fm-dispatch-facts: peak window boundaries, config override, and every stamp field"
}

test_missing_zai_and_staleness() {
  local dir now
  # A fixture without the zai provider degrades, never guesses.
  dir=$(make_case no-zai)
  now=$(epoch_utc 2026-08-26T07:00:00Z)
  write_quota_json "$dir" "$now" drop-zai
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "no-zai stamp must succeed"
  case $OUT in
    *" zai_worst=unavailable "*) : ;;
    *) fail "missing zai provider must print zai_worst=unavailable: $OUT" ;;
  esac
  case $OUT in
    *" spend=claude/all:unknown,claude/model:fable:-1.25,zai/all:unknown "*) : ;;
    *) fail "missing zai provider must degrade spend to zai/all:unknown: $OUT" ;;
  esac

  # A snapshot 20 minutes old is flagged stale with its exact age.
  dir=$(make_case stale-quota)
  now=$(epoch_utc 2026-08-26T07:00:00Z)
  write_quota_json "$dir" "$(( now - 1200 ))"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "stale stamp must succeed"
  case $OUT in
    *" quota_age=1200s quota_stale=yes"*) : ;;
    *) fail "a 20-minute-old snapshot must print quota_age=1200s quota_stale=yes: $OUT" ;;
  esac

  # A fresh snapshot carries no stale flag.
  dir=$(make_case fresh-quota)
  now=$(epoch_utc 2026-08-26T07:00:00Z)
  write_quota_json "$dir" "$(( now - 60 ))"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 0 "$RC" "fresh stamp must succeed"
  case $OUT in
    *" quota_age=60s"*) : ;;
    *) fail "a fresh snapshot must print its age: $OUT" ;;
  esac
  case $OUT in
    *"quota_stale"*) fail "a fresh snapshot must not be flagged stale: $OUT" ;;
  esac
  pass "fm-dispatch-facts: unavailable degradation and quota staleness"
}

test_malformed_config_and_dependencies() {
  local dir now
  now=$(epoch_utc 2026-08-26T07:00:00Z)

  # A bad window line is an error naming the file, never a silent default.
  dir=$(make_case bad-window-hour)
  write_quota_json "$dir" "$now"
  printf '25:00-18:00 Mon-Fri\n' > "$dir/config/zai-peak-window"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 2 "$RC" "malformed window hour must exit 2"
  assert_contains "$ERR" "$dir/config/zai-peak-window" "malformed window error must name the file"

  # A second non-empty line is equally malformed.
  dir=$(make_case bad-window-multiline)
  write_quota_json "$dir" "$now"
  printf '14:00-18:00 Mon-Fri\nnotes: edited by hand\n' > "$dir/config/zai-peak-window"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 2 "$RC" "multi-line window file must exit 2"

  # An unknown day name is malformed too.
  dir=$(make_case bad-window-day)
  write_quota_json "$dir" "$now"
  printf '14:00-18:00 Mon-Fri,Someday\n' > "$dir/config/zai-peak-window"
  run_facts "$dir" FM_DISPATCH_FACTS_NOW="$now"
  expect_code 2 "$RC" "unknown day name must exit 2"

  # quota-axi missing from PATH (jq still visible via a fixture-only symlink,
  # since the real quota-axi lives beside the real jq) exits 1 with one line.
  dir=$(make_case no-quota-axi)
  write_quota_json "$dir" "$now"
  mkdir -p "$dir/jqonly"
  ln -s "$(command -v jq)" "$dir/jqonly/jq"
  OUT=$(env PATH="$dir/jqonly:$BASE_PATH" FM_HOME="$dir/home" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_DISPATCH_FACTS_NOW="$now" \
    TZ=UTC "$FACTS" 2>"$dir/err")
  RC=$?
  ERR=$(cat "$dir/err")
  expect_code 1 "$RC" "missing quota-axi must exit 1"
  assert_contains "$ERR" "quota-axi" "missing quota-axi error must name the tool"
  [ "$(printf '%s\n' "$ERR" | sed -n '/./p' | wc -l | tr -d ' ')" = "1" ] \
    || fail "missing-dependency error must be one line: $ERR"

  # --help works without touching any dependency.
  OUT=$(PATH="$BASE_PATH" "$FACTS" --help 2>/dev/null)
  RC=$?
  expect_code 0 "$RC" "--help must succeed with a stripped PATH"
  assert_contains "$OUT" "config/zai-peak-window" "--help must document the config file"
  pass "fm-dispatch-facts: malformed config refusal and dependency failures"
}

test_stamp_fields_and_peak_boundaries
test_missing_zai_and_staleness
test_malformed_config_and_dependencies
