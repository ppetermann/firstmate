#!/usr/bin/env bash
# tests/fakebin-write.sh - the single owner of fixture tool-directory writes.
#
# Source this from a test file that is not already reaching tests/lib.sh:
#   # shellcheck source=tests/fakebin-write.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fakebin-write.sh"
#
# tests/lib.sh sources it, so every suite that reaches that library already has
# fm_fakebin_write in scope and must not source this file a second time.
#
# WHAT IT IS FOR
#
# A plain `cat > <path>` redirect FOLLOWS a symlink and overwrites whatever it
# points to. A fixture that symlinks a real host tool into its fakebin - so the
# fixture has a working copy of it - and then writes a stub under that same name
# is exactly how a 2026-09-15 incident replaced this box's real /usr/bin/jq with
# a 27-byte stub for three hours, silently: every dependent check kept passing
# on empty output rather than failing.
#
# The same shape reaches further than a fakebin. This tree symlinks the LIVE
# repository's own bin/ into a fixture home in eight places (`ln -s "$ROOT/bin"
# "$root/bin"`) and symlinks individual real repository scripts into a fixture
# bin/ in about a hundred more, so a plain redirect at `$root/bin/<script>` can
# overwrite firstmate's own source. Every write into a fixture tool directory -
# a fakebin sandbox or a fixture `bin/` - therefore goes through this carrier,
# and bin/fm-lint.sh's fixture-write purity check is what keeps that true.
#
# THE TWO SYMLINK SHAPES
#
# Two symlink shapes redirect such a write out of the fixture, and they need
# opposite answers:
#
#   leaf   - <fakebin>/jq is itself a symlink to the real tool. The caller owns
#            that entry and means to replace it, so unlink first and let the
#            write land on a fresh regular file.
#   parent - <fixture>/bin is a symlink to a real directory, and the caller
#            writes <fixture>/bin/fm-guard.sh. The caller owns NOTHING at the
#            destination: unlinking would delete a real script and writing would
#            replace it, so there is no safe write and the only correct answer
#            is to refuse and say where the path really led.
#
# The parent shape is caught by one resolve rather than a walk up the chain: a
# symlink anywhere in the path's directory components shows up as a resolved
# parent outside the test temp base, which is the one place a fixture stub may
# ever land. Both sides are resolved with `pwd -P`, so a host that reaches its
# temp base through a symlink of its own (macOS resolves /var to /private/var)
# compares equal instead of refusing every write on that platform.
#
# WHAT THE ENFORCEMENT DOES AND DOES NOT REACH
#
# bin/fm-lint.sh's fixture-write purity check reads the redirect target as it is
# written, so it covers every site in this tree and every ordinary new one. A
# redirect through an indirect target - `out=$fakebin/jq; cat > "$out"` - is
# invisible to it, and so is an `eval`. Nothing in shell can intercept a
# redirect, so that gap is real rather than something a better check would
# close; what closes it in practice is that the carrier is the only spelling
# the tree uses, so an indirect write reads as the anomaly it is.
#
# The other half of the hazard, the symlink itself, is deliberately left alone.
# About thirty fixtures symlink a real tool into a fakebin precisely to keep the
# real process identity - `ln -s /bin/bash "$FAKEBIN/claude"` is what makes an
# ancestry or process-walk assertion true - so replacing those symlinks with
# wrapper scripts would break the very cases they exist for. The leaf answer
# below (unlink, then write a fresh regular file) is what makes those fixtures
# safe to overwrite, which is why the write side is the side that is enforced.
#
# REPLACING AN ENTRY KEEPS ITS MODE
#
# A plain `cat >` redirect truncates in place, so an entry a fixture already
# made executable stays executable when the fixture rewrites it - and fixtures
# rely on that, writing the stub once with a `chmod +x` and then rewriting it
# per case with no chmod at all. Unlinking first is what makes the leaf answer
# safe, but it also drops the mode, so the carrier captures the mode it is
# about to replace and restores it after the write. A path that did not exist
# gets the umask default, exactly as the redirect would have.
#
# --append extends a file the fixture already created instead of replacing it.
# It keeps the parent check, and additionally REFUSES a leaf symlink: replacing
# an entry the caller owns is a deliberate act, but appending to one has no
# such reading - it can only mean the caller believed it owned bytes that
# actually live in the real tool the entry points at.

# Idempotent guard: tests/lib.sh sources this file, and a standalone suite that
# sources it directly may also reach a helper that sources the library.
if [ -n "${FM_TEST_FAKEBIN_WRITE_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FAKEBIN_WRITE_SOURCED=1

# Standalone suites that source this file without tests/lib.sh have no `fail`.
# The library defines its own before sourcing this file, so this never shadows
# the reporter a library-backed suite already has.
if ! declare -F fail > /dev/null 2>&1; then
  fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
  }
fi

# fm_fakebin_write [--append] <path>
# Writes stdin to <path> inside a fixture tool directory, refusing any write
# whose directory components leave the test temp base. The header above owns
# the contract and the incident it answers.
fm_fakebin_write() {
  local append=0 path parent resolved base mode
  if [ "${1:-}" = --append ]; then
    append=1
    shift
  fi
  path=${1:-}
  [ -n "$path" ] || fail "fm_fakebin_write: called without a path"
  case $path in
    */*) parent=${path%/*}; [ -n "$parent" ] || parent=/ ;;
    *) parent=. ;;
  esac
  [ -d "$parent" ] ||
    fail "fm_fakebin_write: $path: its directory $parent does not exist"
  resolved=$(cd -P -- "$parent" && pwd -P) ||
    fail "fm_fakebin_write: $path: cannot resolve its directory $parent"
  base=$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P) ||
    fail "fm_fakebin_write: cannot resolve the test temp base ${TMPDIR:-/tmp}"
  case "$resolved/" in
    "$base"/*) ;;
    *)
      fail "fm_fakebin_write: refusing to write $path: a directory in that path is a symlink out of the fixture, so the write would land on $resolved/${path##*/}, outside the test temp base $base"
      ;;
  esac
  if [ "$append" -eq 1 ]; then
    [ ! -L "$path" ] ||
      fail "fm_fakebin_write: refusing to append to $path: it is a symlink to $(readlink "$path"), so the appended bytes would land on the real file it points at"
    cat >> "$path"
    return 0
  fi
  # `cat >` truncates in place and keeps the mode; unlinking does not, so carry
  # the replaced entry's mode across. Dereferenced deliberately: replacing a
  # symlinked real tool should leave a stub as runnable as the tool was.
  mode=$(stat -Lc %a "$path" 2>/dev/null || stat -Lf %Lp "$path" 2>/dev/null) || mode=
  rm -f -- "$path"
  cat > "$path"
  [ -z "$mode" ] || chmod "$mode" "$path"
}
