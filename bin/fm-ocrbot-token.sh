#!/usr/bin/env bash
# Mint a short-lived GitHub App installation access token for the OCR review bot.
#
# Prints the installation token as the ONLY stdout line, so a reviewer worker
# adopts the App identity with:
#   GH_TOKEN=$(bin/fm-ocrbot-token.sh) gh api ...
# Diagnostics go to stderr and every failure exits non-zero: this is a
# worker-invoked helper, not a watcher check, so it fails loudly.
#
# Config (activation = config/ocr-bot directory presence in the home):
#   config/ocr-bot/app.env         OCRBOT_CLIENT_ID, OCRBOT_APP_ID,
#                                  OCRBOT_INSTALLATION_ID; a non-empty
#                                  environment value wins over the file
#   config/ocr-bot/private-key.pem the App's RS256 key, a regular unlinked file
#
# JWT: RS256 signed with openssl, iat = now-60 (clock-drift allowance), exp =
# now+540 (inside GitHub's 10-minute maximum), iss = the App ID as a JSON
# integer. Verified against the live endpoint 2026-08-16: it rejects a string
# issuer ("'Issuer' claim ('iss') must be an Integer") before even checking
# the signature, so the client-id-as-iss shape some docs suggest is not usable
# here; the numeric App ID is.
# Exchange: POST <OCRBOT_API_URL>/app/installations/<installation id>/access_tokens
# with the JWT as a bearer header read from a 0600 file so it never touches
# argv. OCRBOT_API_URL defaults to https://api.github.com and exists for
# hermetic tests and local development.
#
# Cache: state/ocrbot/token (0600) holds "<token>\n<expiry-epoch>"; a cached
# token with at least 600 seconds remaining is reused without a mint, matching
# the re-mint-under-10-minutes contract. A malformed or non-private cache is
# ignored and re-minted.
#
# Usage: fm-ocrbot-token.sh [--help]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ocrbot-lib.sh
. "$SCRIPT_DIR/fm-ocrbot-lib.sh"

REMAIN_FLOOR=600

usage() {
  awk '
    NR == 1 { next }
    /^# Usage:/ { sub(/^# ?/, ""); print; exit }
  ' "$0"
}

die() {
  printf 'fm-ocrbot-token: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 0 ] || [ "$1" = "--help" ] || die "unexpected argument (usage: fm-ocrbot-token.sh [--help])"
[ $# -eq 0 ] || { usage; exit 0; }

command -v openssl >/dev/null 2>&1 || die "missing openssl"
command -v jq >/dev/null 2>&1 || die "missing jq"
command -v curl >/dev/null 2>&1 || die "missing curl"

ocrbot_load_app_env "$CONFIG" || die "missing config/ocr-bot/app.env"
[ -n "$OCRBOT_CLIENT_ID" ] || die "OCRBOT_CLIENT_ID is not set"
case "$OCRBOT_APP_ID" in
  ''|*[!0-9]*) die "OCRBOT_APP_ID is not a number" ;;
esac
case "$OCRBOT_INSTALLATION_ID" in
  ''|*[!0-9]*) die "OCRBOT_INSTALLATION_ID is not a number" ;;
esac
KEY_FILE=$(ocrbot_key_file "$CONFIG")
[ -f "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || die "missing config/ocr-bot/private-key.pem"

API_URL=${OCRBOT_API_URL:-https://api.github.com}
API_URL=${API_URL%/}
CACHE_DIR="$STATE/ocrbot"
TOKEN_CACHE="$CACHE_DIR/token"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# A GitHub token is an opaque [A-Za-z0-9_.-] string (modern installation tokens
# are ghs_<appid>_<jwt>, which contain dots); anything else in a response or
# cache is treated as malformed rather than printed as a token.
token_shape_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

now=$(date +%s)

# Reuse path: a private, well-formed cache with enough remaining lifetime.
if fmx_private_artifact_file_valid "$CACHE_DIR" token 600; then
  cached_token=$(sed -n '1p' "$TOKEN_CACHE" 2>/dev/null || true)
  cached_exp=$(sed -n '2p' "$TOKEN_CACHE" 2>/dev/null || true)
  if token_shape_valid "$cached_token" \
    && case "$cached_exp" in ''|*[!0-9]*) false ;; esac \
    && [ "$((cached_exp - now))" -ge "$REMAIN_FLOOR" ]; then
    printf '%s\n' "$cached_token"
    exit 0
  fi
fi

iat=$((now - 60))
exp=$((now + 540))
payload=$(jq -cn --argjson iat "$iat" --argjson exp "$exp" --argjson iss "$OCRBOT_APP_ID" \
  '{iat: $iat, exp: $exp, iss: $iss}') || die "cannot build the JWT payload"
header_b64=$(printf '%s' '{"typ":"JWT","alg":"RS256"}' | b64url) || die "cannot encode the JWT header"
payload_b64=$(printf '%s' "$payload" | b64url) || die "cannot encode the JWT payload"
sig_b64=$(printf '%s.%s' "$header_b64" "$payload_b64" | openssl dgst -sha256 -sign "$KEY_FILE" 2>/dev/null | b64url) \
  || die "cannot sign the JWT with config/ocr-bot/private-key.pem"
jwt="$header_b64.$payload_b64.$sig_b64"

AUTH_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-ocrbot-token.XXXXXX") || die "cannot create a temp file"
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-ocrbot-token.XXXXXX") || { rm -f "$AUTH_FILE"; die "cannot create a temp file"; }
trap 'rm -f "$AUTH_FILE" "$BODY_FILE"' EXIT
printf 'Authorization: Bearer %s\n' "$jwt" > "$AUTH_FILE"
chmod 0600 "$AUTH_FILE"

code=$(curl -m 10 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "@$AUTH_FILE" \
  -H 'Accept: application/vnd.github+json' \
  -X POST "$API_URL/app/installations/$OCRBOT_INSTALLATION_ID/access_tokens" 2>/dev/null) \
  || die "token exchange request failed"
case "$code" in
  200|201) ;;
  *)
    api_message=$(jq -r '.message // empty' "$BODY_FILE" 2>/dev/null | head -n 1 | cut -c1-160)
    [ -n "$api_message" ] || api_message="no response message"
    die "token exchange returned HTTP $code: $api_message"
    ;;
esac

token=$(jq -r '.token // empty' "$BODY_FILE" 2>/dev/null) || token=
token_shape_valid "$token" || die "token exchange response has no usable token"
expires_iso=$(jq -r '.expires_at // empty' "$BODY_FILE" 2>/dev/null) || expires_iso=
[ -n "$expires_iso" ] || die "token exchange response has no expires_at"
exp_epoch=$(printf '%s' "$expires_iso" | jq -Rr 'fromdateiso8601' 2>/dev/null) || die "cannot parse expires_at"
case "$exp_epoch" in
  ''|*[!0-9]*) die "cannot parse expires_at" ;;
esac
[ "$exp_epoch" -gt "$now" ] || die "token exchange returned an already-expired token"

printf '%s\n%s\n' "$token" "$exp_epoch" \
  | fmx_private_artifact_publish_stdin "$CACHE_DIR" token 600 \
  || die "cannot write the private token cache"

printf '%s\n' "$token"
