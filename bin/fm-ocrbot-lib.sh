#!/usr/bin/env bash
# Shared config and shim resolution for the OCR review bot (fm-ocrbot-token.sh
# and fm-ocrbot-poll.sh, plus the bootstrap shim writer and the watcher's
# dispatch validation). The bot is opt-in: the captain drops a config/ocr-bot
# directory into the firstmate home. Until that directory exists every bot code
# path is a hard no-op, so a home without it sees zero change.
#
# This file is sourced, never executed. It defines:
#   ocrbot_repos_file <config-root>        - path of the registered-repos file
#   ocrbot_app_env_file <config-root>      - path of the App credentials file
#   ocrbot_key_file <config-root>          - path of the App RS256 private key
#   ocrbot_load_app_env <config-root>      - set OCRBOT_CLIENT_ID, OCRBOT_APP_ID,
#                                and OCRBOT_INSTALLATION_ID (a non-empty
#                                environment value wins over app.env); fails
#                                when app.env is missing
#   ocrbot_repos_list <repos-file>         - print valid owner/repo entries, one
#                                per line; print the first invalid non-comment
#                                entry to stderr and fail when any exists
#   ocrbot_registered_repo <repos-file> <owner/repo> - print the registered
#                                spelling of that repo (GitHub names compare
#                                case-insensitively); fail when it is not
#                                registered or the file has an invalid entry
#   ocrbot_state_name <owner/repo>         - flat private-state filename for a
#                                registered repo
#   ocrbot_seen_line <number> <head_sha> <draft:0|1> - one seen-state record
#   ocrbot_wake_line <owner/repo> <number> <head_sha> - one reviewable-PR wake
#                                line, the format ocr-bot-review handles
#   ocrbot_wake_key <shim> <wake-line> - the durable wake-queue key for one
#                                poll output line: "<shim> <owner/repo>#<n>"
#                                for an ocr-pr line, so the drain's kind+key
#                                dedupe keeps one wake per PR and a flip and a
#                                poll for the same PR still collapse; the bare
#                                shim path for any other line
#   ocrbot_seen_upsert <state-root> <owner/repo> <number> <head_sha> <draft>
#                              - replace that PR's seen-state record, keeping
#                                every other PR's, through the guarded writer
#   ocrbot_poll_shim_content <home> <root> - the byte-static watcher shim body
#   ocrbot_poll_shim_valid <file> <home> <root> - private-identity plus
#                                byte-compare validation for that shim
# Callers must resolve their home/config/state roots (including the usual
# FM_HOME, FM_CONFIG_OVERRIDE, and FM_STATE_OVERRIDE overrides) before use.
#
# .env-style parsing and guarded private-artifact publication are reused from
# fm-x-lib.sh, which owns those contracts; nothing here restates them.

if ! command -v fmx_env_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-x-lib.sh
  . "${FM_OCRBOT_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/fm-x-lib.sh"
fi

ocrbot_repos_file() {
  printf '%s/ocr-bot/repos\n' "$1"
}

ocrbot_app_env_file() {
  printf '%s/ocr-bot/app.env\n' "$1"
}

ocrbot_key_file() {
  printf '%s/ocr-bot/private-key.pem\n' "$1"
}

ocrbot_load_app_env() {
  local config_root=$1 env_file
  env_file=$(ocrbot_app_env_file "$config_root")
  [ -f "$env_file" ] || return 1
  if [ -n "${OCRBOT_CLIENT_ID:-}" ]; then :; else
    OCRBOT_CLIENT_ID=$(fmx_env_get OCRBOT_CLIENT_ID "$env_file")
  fi
  if [ -n "${OCRBOT_APP_ID:-}" ]; then :; else
    OCRBOT_APP_ID=$(fmx_env_get OCRBOT_APP_ID "$env_file")
  fi
  if [ -n "${OCRBOT_INSTALLATION_ID:-}" ]; then :; else
    OCRBOT_INSTALLATION_ID=$(fmx_env_get OCRBOT_INSTALLATION_ID "$env_file")
  fi
}

# One registered repo per line; blank lines and #-comments are ignored. A valid
# entry is owner/repo over GitHub-name characters with an alphanumeric first
# character per part, which is also what keeps the derived state filename safe.
ocrbot_repos_list() {
  local file=$1 line rc=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      [A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*) printf '%s\n' "$line" ;;
      *)
        [ "$rc" -eq 0 ] && printf 'invalid repos entry: %s\n' "$line" >&2
        rc=1
        ;;
    esac
  done < "$file"
  return "$rc"
}

ocrbot_registered_repo() {
  local file=$1 want entries entry
  entries=$(ocrbot_repos_list "$file" 2>/dev/null) || return 1
  want=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done <<EOF
$entries
EOF
  return 1
}

ocrbot_state_name() {
  printf '%s\n' "${1//\//__}"
}

ocrbot_seen_line() {
  printf '%s %s %s\n' "$1" "$2" "$3"
}

ocrbot_wake_line() {
  printf 'ocr-pr %s#%s %s\n' "$1" "$2" "$3"
}

ocrbot_wake_key() {
  local shim=$1 line=$2 pr
  case $line in
    'ocr-pr '?*' '?*)
      pr=${line#ocr-pr }
      printf '%s %s\n' "$shim" "${pr%% *}"
      ;;
    *) printf '%s\n' "$shim" ;;
  esac
}

ocrbot_seen_upsert() {
  local state_root=$1 repo=$2 num=$3 sha=$4 draft=$5 name seen_dir
  name=$(ocrbot_state_name "$repo")
  seen_dir="$state_root/ocrbot/seen"
  {
    awk -v n="$num" '$1 != n' "$seen_dir/$name" 2>/dev/null
    ocrbot_seen_line "$num" "$sha" "$draft"
  } | fmx_private_artifact_publish_stdin "$seen_dir" "$name" 600
}

ocrbot_poll_shim_content() {
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - OCR review bot poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-ocrbot-poll.sh")"
}

ocrbot_poll_shim_valid() {
  local file=$1 home=$2 root=$3
  fmx_single_link_file_mode_valid "$file" 700 || return 1
  cmp -s "$file" <(ocrbot_poll_shim_content "$home" "$root")
}
