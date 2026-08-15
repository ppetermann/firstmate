#!/usr/bin/env bash
# Install, mint through, validate, or remove Firstmate's guarded Kimi crew
# turn-end hook.
#
# This command is the sole owner of the text-level edit to
# $HOME/.kimi-code/config.toml. It validates the existing TOML but never
# serializes it: install adds or replaces one marker-delimited Firstmate region,
# and remove excises only that region. Missing, malformed, symlinked, partially
# marked, or otherwise surprising config is refused without a config write.
#
# remove refuses when the registry directory is non-empty, so a retirement can
# never sweep a live task's auth token via shutil.rmtree. The teardown and
# relaunch retirement paths (bin/fm-control-lib.sh
# fm_control_harness_turnend_maybe_retire_global) count the registry first and
# call remove only when it is empty; the guard here is the authoritative in-lock
# check for that decision.
#
# Concurrency contract: this script takes no lock itself. Every mutating caller
# (fm-spawn.sh around mint, fm-control-lib.sh around remove) holds the
# per-harness registry lock (fm_control_harness_turnend_lock_path) across the
# whole invocation, so install/mint and remove can never interleave and the
# non-empty refusal above is decided with no token able to appear after it.
#
# mint is the spawn-side installer: it ensures the hook script, config region,
# and registry exactly like install, then creates one auth token naming the
# given absolute *.turn-ended path and prints the token's basename on stdout.
# validate is the spawn's read-only pre-flight: it runs install's refusal checks
# without writing anything, so a spawn that never reaches mint cannot resurrect
# a retired hook by installing hook files no live token guards.
#
# The installed Stop hook always exits 0 and stays silent. It reads cwd from the
# hook payload, checks for a .fm-kimi-turnend pointer before registry work, and
# touches a task turn-end marker only when the pointer names a Firstmate-created
# token in $HOME/.kimi-code/fm-turn-end.d/.
#
# Usage:
#   fm-kimi-turnend-hook.sh install
#   fm-kimi-turnend-hook.sh mint <absolute-*.turn-ended-path>
#   fm-kimi-turnend-hook.sh remove
#   fm-kimi-turnend-hook.sh validate
set -u

case "${1:-}" in
  install|remove|mint|validate) ACTION=$1 ;;
  -h|--help)
    sed -n '2,40{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|mint <path>|remove|validate\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-kimi-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.\n' >&2
  exit 1
fi
if { [ "$ACTION" = install ] || [ "$ACTION" = mint ]; } && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-kimi-turnend-hook: refused: jq is required by the installed Kimi turn-end hook.\n' >&2
  exit 1
fi

MINT_TARGET=
MINT_AUTH_FILE=
if [ "$ACTION" = mint ]; then
  case "${2:-}" in
    /**.turn-ended) MINT_TARGET=$2 ;;
    *)
      printf 'fm-kimi-turnend-hook: refused: mint needs an absolute *.turn-ended path, got '%s'.\n' "${2:-}" >&2
      exit 2
      ;;
  esac
  # Mint stages the auth token BEFORE running the install ensure, matching the
  # historical spawn order: a task's registry entry exists before its hook files
  # do, and a failed ensure below removes the staged token so a refused spawn
  # leaves no live-looking entry behind.
  mkdir -p "$HOME/.kimi-code/fm-turn-end.d"
  old_umask=$(umask)
  umask 077
  MINT_AUTH_FILE=$(mktemp "$HOME/.kimi-code/fm-turn-end.d/fm.XXXXXXXXXXXX") || {
    umask "$old_umask"
    printf 'fm-kimi-turnend-hook: refused: could not create a registry entry.\n' >&2
    exit 1
  }
  umask "$old_umask"
  printf '%s\n' "$MINT_TARGET" > "$MINT_AUTH_FILE"
fi

python_action=$ACTION
[ "$ACTION" != mint ] || python_action=install
python_status=0
python3 - "$python_action" "$HOME/.kimi-code" <<'PY' || python_status=$?
import os
import re
import shutil
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print(
        "fm-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.",
        file=sys.stderr,
    )
    raise SystemExit(1)

ACTION = sys.argv[1]
CONFIG_DIR = sys.argv[2]
CONFIG = os.path.join(CONFIG_DIR, "config.toml")
HOOK = os.path.join(CONFIG_DIR, "fm-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-turn-end.d")
BEGIN = b"# BEGIN FIRSTMATE KIMI TURN-END HOOK"
BEGIN_OWNS_NEWLINE = BEGIN + b" (OWNS PRECEDING NEWLINE)"
END = b"# END FIRSTMATE KIMI TURN-END HOOK"
IDENTIFIER = b"FIRSTMATE KIMI TURN-END HOOK"
HOOK_NAME = b"fm-turn-end.sh"
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")

HOOK_BYTES = b'''#!/usr/bin/env bash
# Firstmate Kimi turn-end hook. Managed by fm-kimi-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er 'select(.hook_event_name == "Stop") | .cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
pointer="$workspace/.fm-kimi-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir=${HOME:-}/.kimi-code/fm-turn-end.d
[ -n "${HOME:-}" ] || exit 0
target=$(cat "$auth_dir/$token" 2>/dev/null) || exit 0
case "$target" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch -- "$target" 2>/dev/null || true
exit 0
'''


def refuse(reason: str) -> None:
    print(f"fm-kimi-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str) -> os.stat_result:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def parse_toml(data: bytes, label: str):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        refuse(f"{label} is malformed TOML: {error}.")
    hooks = parsed.get("hooks")
    if hooks is not None and not isinstance(hooks, list):
        refuse(f"{label} has an unexpected non-array 'hooks' value.")
    return parsed


def locate_region(data: bytes):
    normal_count = data.count(BEGIN + b"\n")
    owned_count = data.count(BEGIN_OWNS_NEWLINE + b"\n")
    end_count = data.count(END)
    identifier_count = data.count(IDENTIFIER)
    if normal_count + owned_count == 0 and end_count == 0 and identifier_count == 0:
        return None
    if normal_count + owned_count != 1 or end_count != 1 or identifier_count != 2:
        refuse("config.toml has partial, duplicated, or altered Firstmate region markers.")
    marker = BEGIN_OWNS_NEWLINE if owned_count else BEGIN
    marker_at = data.find(marker)
    if marker_at != 0 and data[marker_at - 1 : marker_at] != b"\n":
        refuse("the Firstmate begin marker is not at a line boundary.")
    start = marker_at
    if owned_count:
        if marker_at == 0 or data[marker_at - 1 : marker_at] != b"\n":
            refuse("the Firstmate region claims a preceding newline that is absent.")
        start -= 1
    end_at = data.find(END, marker_at + len(marker))
    if end_at < 0:
        refuse("the Firstmate end marker is missing.")
    after = end_at + len(END)
    if after < len(data):
        if data[after : after + 1] != b"\n":
            refuse("the Firstmate end marker is not a complete line.")
        after += 1
    return start, after, marker


def block(marker: bytes) -> bytes:
    return b"\n".join(
        (
            marker,
            b"[[hooks]]",
            b'event = "Stop"',
            b'matcher = "^$"',
            b'command = "bash \\"$HOME/.kimi-code/fm-turn-end.sh\\" >/dev/null 2>&1 || true"',
            b"timeout = 1",
            END,
            b"",
        )
    )


def without_region(data: bytes, region) -> bytes:
    prefix = data[: region[0]]
    suffix = data[region[1] :]
    # Retain a newline so removal cannot join the captain's preceding line to content appended after installation.
    separator = b"\n" if region[2] == BEGIN_OWNS_NEWLINE and suffix else b""
    return prefix + separator + suffix


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_firstmate_files_for_remove() -> None:
    if os.path.lexists(HOOK):
        info = regular_not_symlink(HOOK, "Firstmate hook script")
        with open(HOOK, "rb") as stream:
            if stream.read() != HOOK_BYTES:
                refuse(f"Firstmate hook script has unexpected content at {HOOK}.")
        if stat.S_IMODE(info.st_mode) & 0o077:
            refuse(f"Firstmate hook script has unexpectedly broad permissions at {HOOK}.")
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
        entries = os.listdir(REGISTRY)
        for name in entries:
            path = os.path.join(REGISTRY, name)
            child = os.lstat(path)
            if not TOKEN_NAME.fullmatch(name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
                refuse(f"Firstmate registry contains an unexpected entry at {path}.")
        if entries:
            refuse(
                "Firstmate registry is not empty; refusing to remove the global "
                "hook while tasks are still active."
            )


def validate_firstmate_files_for_install() -> None:
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
    if os.path.lexists(HOOK):
        regular_not_symlink(HOOK, "Firstmate hook script")
        with open(HOOK, "rb") as stream:
            existing_hook = stream.read()
        if existing_hook != HOOK_BYTES and not existing_hook.startswith(
            b"#!/usr/bin/env bash\n# Firstmate Kimi turn-end hook."
        ):
            refuse(f"Firstmate hook path has unexpected content at {HOOK}.")


try:
    if not os.path.isdir(CONFIG_DIR) or os.path.islink(CONFIG_DIR):
        refuse(f"Kimi config directory is missing or unexpected at {CONFIG_DIR}.")
    config_info = regular_not_symlink(CONFIG, "Kimi config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    parse_toml(original, "config.toml")
    region = locate_region(original)
    outside = original if region is None else without_region(original, region)
    if HOOK_NAME in outside:
        refuse("config.toml references fm-turn-end.sh outside the Firstmate-owned region.")

    if ACTION == "validate":
        # Read-only pre-flight: install's refusal checks with no writes, so a
        # spawn that never reaches mint cannot resurrect a retired hook.
        validate_firstmate_files_for_install()
        raise SystemExit(0)

    if ACTION == "install":
        validate_firstmate_files_for_install()
        if region is None:
            marker = BEGIN if original.endswith(b"\n") else BEGIN_OWNS_NEWLINE
            addition = block(marker)
            candidate = original + (b"" if original.endswith(b"\n") else b"\n") + addition
        else:
            candidate = original[: region[0]] + (
                (b"\n" if region[2] == BEGIN_OWNS_NEWLINE else b"") + block(region[2])
            ) + original[region[1] :]
        parse_toml(candidate, "updated config.toml")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
        if installed_hook != HOOK_BYTES or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_firstmate_files_for_remove()
        candidate = outside
        parse_toml(candidate, "config.toml after Firstmate region removal")
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY

if [ "$python_status" -ne 0 ]; then
  if [ "$ACTION" = mint ]; then
    rm -f -- "$MINT_AUTH_FILE"
  fi
  exit "$python_status"
fi
if [ "$ACTION" = mint ]; then
  printf '%s\n' "${MINT_AUTH_FILE##*/}"
fi
