#!/usr/bin/env bash
# Behavior tests for the OCR review bot token helper (bin/fm-ocrbot-token.sh)
# and its config parsing (bin/fm-ocrbot-lib.sh).
#
# Hermetic by construction: a throwaway RSA key signs real JWTs with the real
# openssl, and the installation-token exchange is a fakebin `curl` so no
# network is ever touched. The suite pins the JWT header/payload contract
# (RS256, claim windows, iss = the numeric App ID the live endpoint demands),
# the cache reuse/re-mint thresholds, the token-only stdout contract, and the
# loud failure modes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ocrbot-token-tests)

CLIENT_ID=Iv1.abc123def456
APP_ID=123456
INSTALLATION_ID=778899

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# A fakebin `curl` that models the GitHub installation-token exchange: it
# records the Authorization header and URL to OCR_CURL_LOG (reading the header
# from the -H @file so the JWT never hits argv), writes the response body from
# OCR_FAKE_BODY (defaulting to a fresh 1-hour token), and prints the HTTP code
# from OCR_FAKE_CODE exactly as the real `-w '%{http_code}'` would.
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" auth="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -H)
      case "$2" in
        @*) while IFS= read -r h; do case "$h" in Authorization:*) auth=$h ;; esac; done < "${2#@}" ;;
      esac
      shift 2
      ;;
    -m|-w|-X) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${OCR_CURL_LOG:-}" ]; then
  { echo "auth=$auth"; echo "url=$url"; } >> "$OCR_CURL_LOG"
fi
[ -n "$ofile" ] || exit 0
if [ -n "${OCR_FAKE_BODY:-}" ]; then
  printf '%s\n' "${OCR_FAKE_BODY:-}"
else
  jq -cn --arg token "${OCR_FAKE_TOKEN:-ghs_faketoken1}" \
    --argjson ttl "${OCR_FAKE_EXPIRES_IN:-3600}" \
    '{token: $token, expires_at: ((now + $ttl) | todateiso8601)}'
fi > "$ofile"
printf '%s' "${OCR_FAKE_CODE:-201}"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/config/ocr-bot"
  printf 'OCRBOT_CLIENT_ID=%s\nOCRBOT_APP_ID=%s\nOCRBOT_INSTALLATION_ID=%s\n' \
    "$CLIENT_ID" "$APP_ID" "$INSTALLATION_ID" > "$home/config/ocr-bot/app.env"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$home/config/ocr-bot/private-key.pem" 2>/dev/null \
    || fail "openssl must generate a throwaway test key"
  chmod 0600 "$home/config/ocr-bot/private-key.pem"
  openssl pkey -in "$home/config/ocr-bot/private-key.pem" -pubout \
    -out "$home/pub.pem" 2>/dev/null || fail "openssl must derive the test public key"
}

# Decode one base64url JWT segment from stdin to stdout.
b64url_decode() {
  local s pad
  s=$(cat)
  pad=$(( (4 - ${#s} % 4) % 4 ))
  [ "$pad" -ne 0 ] && s="$s$(printf '%*s' "$pad" '' | tr ' ' '=')"
  printf '%s' "$s" | tr '_-' '/+' | openssl base64 -d -A
}

# Extract the bearer JWT recorded by the fake curl: the last logged auth line.
logged_jwt() {
  local log=$1 auth
  auth=$(grep '^auth=' "$log" | tail -n 1 | sed 's/^auth=Authorization: Bearer //')
  [ -n "$auth" ] || fail "the exchange must present a bearer JWT (log: $(cat "$log"))"
  printf '%s\n' "$auth"
}

# ---------------------------------------------------------------------------

test_token_unconfigured_fails_loudly() {
  local home fakebin out rc
  home="$TMP_ROOT/unconfigured"; mkdir -p "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-ocrbot-token.sh" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfigured home must exit non-zero"
  [ -z "$out" ] || fail "an unconfigured home must print no token (got: $out)"
  assert_grep "config/ocr-bot/app.env" "$home/err" "the diagnostic must name the missing config"
  assert_absent "$home/state/ocrbot/token" "no config must leave no cache"
  [ ! -f "$home/curl-calls" ] || [ ! -s "$home/curl-calls" ] || fail "no config must not call the exchange"
  pass "fm-ocrbot-token fails loudly and calls nothing without config"
}

test_token_missing_key_fails_loudly() {
  local home fakebin out rc
  home="$TMP_ROOT/missing-key"; mkdir -p "$home/config/ocr-bot"
  printf 'OCRBOT_CLIENT_ID=%s\nOCRBOT_APP_ID=%s\nOCRBOT_INSTALLATION_ID=%s\n' \
    "$CLIENT_ID" "$APP_ID" "$INSTALLATION_ID" > "$home/config/ocr-bot/app.env"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    "$ROOT/bin/fm-ocrbot-token.sh" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing private key must exit non-zero"
  [ -z "$out" ] || fail "a missing private key must print no token"
  assert_grep "private-key.pem" "$home/err" "the diagnostic must name the missing key"
  assert_absent "$home/state/ocrbot/token" "a missing key must leave no cache"
  pass "fm-ocrbot-token fails loudly without the App private key"
}

test_token_mints_valid_jwt_and_prints_token_only() {
  local home fakebin log out rc t0 t1 jwt h p s payload iat exp sigfile
  home="$TMP_ROOT/mint"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  t0=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_CURL_LOG="$log" \
    "$ROOT/bin/fm-ocrbot-token.sh" 2>"$home/err"); rc=$?
  t1=$(date +%s)
  expect_code 0 "$rc" "mint exit"
  [ -z "$(cat "$home/err")" ] || fail "a successful mint must be silent on stderr (got: $(cat "$home/err"))"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "stdout must be exactly one line"
  [ "$out" = ghs_faketoken1 ] || fail "stdout must be the token only (got: $out)"
  assert_grep "url=https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" "$log" \
    "the exchange must hit the installation access_tokens endpoint"

  jwt=$(logged_jwt "$log")
  h=${jwt%%.*}
  p=$(printf '%s' "$jwt" | cut -d. -f2)
  s=$(printf '%s' "$jwt" | cut -d. -f3)
  [ "$(printf '%s' "$h" | b64url_decode | jq -r .alg)" = RS256 ] || fail "JWT header alg must be RS256"
  [ "$(printf '%s' "$h" | b64url_decode | jq -r .typ)" = JWT ] || fail "JWT header typ must be JWT"
  payload=$(printf '%s' "$p" | b64url_decode)
  [ "$(printf '%s' "$payload" | jq -r .iss)" = "$APP_ID" ] \
    || fail "JWT iss must be the numeric App ID (got: $(printf '%s' "$payload" | jq -r .iss))"
  [ "$(printf '%s' "$payload" | jq -r .iss)" != "$CLIENT_ID" ] \
    || fail "JWT iss must not be the client id"
  iat=$(printf '%s' "$payload" | jq -r .iat)
  exp=$(printf '%s' "$payload" | jq -r .exp)
  [ "$iat" -ge $((t0 - 60)) ] && [ "$iat" -le $((t1 - 60)) ] \
    || fail "JWT iat must be now-60 (got $iat, window $((t0-60))..$((t1-60)))"
  [ "$((exp - iat))" = 600 ] || fail "JWT lifetime must be exp=iat+600 (got $((exp - iat)))"
  [ "$exp" -le $((t1 + 540)) ] || fail "JWT exp must stay inside GitHub's 10-minute maximum"

  sigfile="$home/sig.bin"
  printf '%s' "$s" | b64url_decode > "$sigfile"
  printf '%s.%s' "$h" "$p" \
    | openssl dgst -sha256 -verify "$home/pub.pem" -signature "$sigfile" >/dev/null 2>&1 \
    || fail "the JWT signature must verify with the private key's public half"

  assert_present "$home/state/ocrbot/token" "a successful mint must write the cache"
  [ "$(path_mode "$home/state/ocrbot")" = 700 ] || fail "the cache directory must be private"
  [ "$(path_mode "$home/state/ocrbot/token")" = 600 ] || fail "the cache file must be private"
  [ "$(sed -n 1p "$home/state/ocrbot/token")" = ghs_faketoken1 ] || fail "the cache must hold the token"
  local cached_exp
  cached_exp=$(sed -n 2p "$home/state/ocrbot/token")
  case "$cached_exp" in
    ''|*[!0-9]*) fail "the cache must hold a numeric expiry epoch (got: $cached_exp)" ;;
  esac
  [ "$cached_exp" -gt "$t0" ] || fail "the cached expiry must be in the future"
  pass "fm-ocrbot-token mints an RS256 JWT with pinned claim windows and prints only the token"
}

test_token_reuses_fresh_cache_without_exchange() {
  local home fakebin out rc
  home="$TMP_ROOT/cache-reuse"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_CURL_LOG="$home/curl.log" \
    "$ROOT/bin/fm-ocrbot-token.sh") || fail "first mint must succeed"
  [ "$out" = ghs_faketoken1 ] || fail "first mint must print the exchanged token"
  mv "$home/curl.log" "$home/curl-first.log"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_CURL_LOG="$home/curl.log" \
    "$ROOT/bin/fm-ocrbot-token.sh"); rc=$?
  expect_code 0 "$rc" "cached exit"
  [ "$out" = ghs_faketoken1 ] || fail "the cached token must be reprinted"
  [ ! -e "$home/curl.log" ] || fail "a fresh cache must not trigger a second exchange"
  pass "fm-ocrbot-token reuses a fresh cache without another exchange"
}

test_token_remints_near_expiry_and_when_expired() {
  local home fakebin out rc epoch
  home="$TMP_ROOT/cache-stale"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  for offset in 300 -60; do
    rm -rf "$home/state"
    epoch=$(date +%s)
    mkdir -p "$home/state/ocrbot"
    chmod 700 "$home/state/ocrbot"
    printf 'ghs_cachedtok\n%s\n' "$((epoch + offset))" > "$home/state/ocrbot/token"
    chmod 600 "$home/state/ocrbot/token"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
      OCR_FAKE_TOKEN=ghs_reminted OCR_CURL_LOG="$home/curl.log" \
      "$ROOT/bin/fm-ocrbot-token.sh"); rc=$?
    expect_code 0 "$rc" "re-mint (offset ${offset}s) exit"
    [ "$out" = ghs_reminted ] \
      || fail "a cache with ${offset}s remaining must re-mint (got: $out)"
    assert_grep "url=https://api.github.com/app/installations/" "$home/curl.log" \
      "a stale cache must hit the exchange"
    [ "$(sed -n 1p "$home/state/ocrbot/token")" = ghs_reminted ] \
      || fail "the re-mint must refresh the cache"
    rm -f "$home/curl.log"
  done
  pass "fm-ocrbot-token re-mints under the 10-minute floor and after expiry"
}

test_token_ignores_malformed_cache() {
  local home fakebin out rc
  home="$TMP_ROOT/cache-garbage"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  mkdir -p "$home/state/ocrbot"
  chmod 700 "$home/state/ocrbot"
  printf 'not a token!\n9999999999\n' > "$home/state/ocrbot/token"
  chmod 600 "$home/state/ocrbot/token"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" OCR_FAKE_TOKEN=ghs_clean \
    "$ROOT/bin/fm-ocrbot-token.sh"); rc=$?
  expect_code 0 "$rc" "malformed-cache exit"
  [ "$out" = ghs_clean ] || fail "a malformed cache must be ignored and re-minted (got: $out)"
  pass "fm-ocrbot-token treats a malformed cache as absent"
}

test_token_exchange_error_fails_loudly() {
  local home fakebin out rc
  home="$TMP_ROOT/exchange-401"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    OCR_FAKE_CODE=401 OCR_FAKE_BODY='{"message":"Bad credentials"}' \
    "$ROOT/bin/fm-ocrbot-token.sh" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed exchange must exit non-zero"
  [ -z "$out" ] || fail "a failed exchange must print no token"
  assert_grep "HTTP 401" "$home/err" "the diagnostic must name the status"
  assert_grep "Bad credentials" "$home/err" "the diagnostic must carry the API message"
  assert_absent "$home/state/ocrbot/token" "a failed exchange must leave no cache"
  pass "fm-ocrbot-token fails loudly on an exchange rejection"
}

test_token_malformed_response_fails() {
  local home fakebin out rc
  home="$TMP_ROOT/exchange-garbage"; make_home "$home"
  fakebin=$(make_fake_curl "$home")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" \
    OCR_FAKE_CODE=200 OCR_FAKE_BODY='not json at all' \
    "$ROOT/bin/fm-ocrbot-token.sh" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed response must exit non-zero"
  [ -z "$out" ] || fail "a malformed response must print no token"
  assert_absent "$home/state/ocrbot/token" "a malformed response must leave no cache"
  pass "fm-ocrbot-token fails loudly on a malformed exchange response"
}

test_token_help() {
  local home out rc
  home="$TMP_ROOT/help"; mkdir -p "$home"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-ocrbot-token.sh" --help); rc=$?
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" "fm-ocrbot-token.sh" "help must name the command"
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-ocrbot-token.sh" bogus 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "an unexpected argument must exit non-zero"
  pass "fm-ocrbot-token supports --help and rejects stray arguments"
}

# ---------------------------------------------------------------------------

test_token_unconfigured_fails_loudly
test_token_missing_key_fails_loudly
test_token_mints_valid_jwt_and_prints_token_only
test_token_reuses_fresh_cache_without_exchange
test_token_remints_near_expiry_and_when_expired
test_token_ignores_malformed_cache
test_token_exchange_error_fails_loudly
test_token_malformed_response_fails
test_token_help
