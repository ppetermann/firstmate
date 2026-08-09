#!/usr/bin/env bash
# tests/fm-composer-classify-probe.sh - invoke the shared composer classifier in
# a fresh shell so a caller can pin the locale for the whole process.
# Used by tests/fm-composer-lib.test.sh; it owns no expectations of its own.
set -u

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-composer-lib.sh"

fm_composer_classify_content "$@"
