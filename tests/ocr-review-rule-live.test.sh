#!/usr/bin/env bash
# tests/ocr-review-rule-live.test.sh - live drift guard proving the shipped
# .agents/skills/ocr-delegate-review/review-rule.json still selects the file
# types the OCR review rounds are supposed to read, and still displaces nothing
# it does not carry forward.
#
# Why this file exists: on 2026-09-07 ocr-review-service#113 changed only
# Dockerfile.runner, previewed as "no reviewable files, 1 excluded", and was
# APPROVED without a line of the diff being read. Container build files are
# where pinned versions, base images, and privilege decisions live, so an
# exclusion there is the most expensive kind.
# On 2026-10-12 the maia#556 round excluded env.example and
# CHANGELOG-features.txt the same way, both documented surfaces its PRs change.
#
# The verdict here comes entirely from what the `ocr` binary emits, which is a
# vendor surface that changes without notice: its supported-extension table
# decides selection and its first-match-wins rule resolution decides which group
# a file lands in. A stub could only confirm the assumption already written into
# the stub, so this runs against the real tool. The two properties it pins are
# independent and fail for different reasons:
#
#   selection    - `include` is additive, so the container, example, and
#                  changelog patterns must turn an excluded file of each class
#                  into a reviewable one.
#   displacement - `rules` is first-match-wins and a matching custom pattern
#                  REPLACES the system group rather than adding to it, so every
#                  file the rule file does not claim must keep the group it had
#                  before, and the one group the compose pattern does displace
#                  must survive inside the rule that displaced it.
#
# Standard CI has no `ocr`, so this reports a capability skip there. Run it
# after an `ocr` upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OCR_RULE_LIVE ocr git python3

RULE="$ROOT/.agents/skills/ocr-delegate-review/review-rule.json"
[ -f "$RULE" ] || fail "review-rule.json is missing at $RULE"

LAB="$(fm_test_tmproot ocr-review-rule)"
REPO="$LAB/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q
fm_git_identity "$REPO" 2>/dev/null || {
  git -C "$REPO" config user.name 'Firstmate Tests'
  git -C "$REPO" config user.email 'tests@example.invalid'
}

# A base commit carrying one file of every class this guard reasons about.
printf 'fn main() {}\n'                     > "$REPO/src/main.rs"
printf '# Doc\n\nbase\n'                    > "$REPO/README.md"
printf 'FROM rust:1.80\n'                   > "$REPO/Dockerfile.runner"
printf 'services:\n  a:\n    image: x:1\n'  > "$REPO/docker-compose.yml"
printf 'key: value\n'                       > "$REPO/other.yaml"
printf 'FROM scratch\n'                     > "$REPO/Dockerfile"
printf 'FROM scratch\n'                     > "$REPO/prod.Dockerfile"
printf 'FROM scratch\n'                     > "$REPO/Containerfile"
printf 'FROM scratch\n'                     > "$REPO/Containerfile.dev"
printf 'MODEL=ollama\n'                     > "$REPO/env.example"
printf 'MODEL=ollama\n'                     > "$REPO/.env.example"
printf '# hdr\n2026-10-12 | area | text\n'  > "$REPO/CHANGELOG-features.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
git -C "$REPO" branch -q baseref

# The reproduction: a change whose ONLY file is a container build file.
printf 'FROM rust:1.81\nUSER root\n' > "$REPO/Dockerfile.runner"
git -C "$REPO" add -A
git -C "$REPO" commit -qm dockerfile-only

# jq is not assumed; python3 is already gated above.
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

# --- selection --------------------------------------------------------------

preview="$(ocr delegate preview --repo "$REPO" --from baseref --to HEAD --rule "$RULE" -f json)"
count="$(printf '%s' "$preview" | field reviewable_count)"
[ "$count" = 1 ] || fail "a Dockerfile-only diff previewed $count reviewable files, expected 1 (#113 regression: it previewed 0 and was approved unread)"
assert_contains "$preview" 'Dockerfile.runner' 'the Dockerfile-only diff names the changed container build file'
assert_not_contains "$preview" 'unsupported_ext' 'nothing in a Dockerfile-only diff is excluded as an unsupported extension'
pass 'a Dockerfile-only change previews as reviewable'

# Every include pattern must actually select, or a naming convention silently
# keeps its blind spot. Driven one file per pattern, not as one glob.
for f in Dockerfile Dockerfile.runner prod.Dockerfile Containerfile Containerfile.dev; do
  group="$(ocr delegate rule --repo "$REPO" --rule "$RULE" -f json "$f")"
  src="$(printf '%s' "$group" | python3 -c 'import json,sys; print(json.load(sys.stdin)["groups"][0]["source"])')"
  [ "$src" = custom ] || fail "$f resolved to the '$src' group, so its include pattern does not cover that spelling"
done
pass 'every container build file spelling resolves to the container rule'

# The maia#556 spellings, driven one file per pattern, dotfile included.
for f in env.example .env.example CHANGELOG-features.txt; do
  group="$(ocr delegate rule --repo "$REPO" --rule "$RULE" -f json "$f")"
  src="$(printf '%s' "$group" | python3 -c 'import json,sys; print(json.load(sys.stdin)["groups"][0]["source"])')"
  [ "$src" = custom ] || fail "$f resolved to the '$src' group, so its include pattern does not cover that spelling"
done
pass 'every example and changelog spelling resolves to its custom rule'

# The maia#556 reproduction: a change whose ONLY files are the example
# configuration and the changelog.
printf 'MODEL=openai\n'                            > "$REPO/env.example"
printf 'MODEL=openai\n'                            > "$REPO/.env.example"
printf '# hdr\n2026-10-13 | area | more text\n'    > "$REPO/CHANGELOG-features.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm example-and-changelog-only

preview="$(ocr delegate preview --repo "$REPO" --from HEAD^ --to HEAD --rule "$RULE" -f json)"
count="$(printf '%s' "$preview" | field reviewable_count)"
[ "$count" = 3 ] || fail "an example-and-changelog-only diff previewed $count reviewable files, expected 3 (maia#556 regression: both named files came back unsupported_ext and were reviewed unread)"
assert_not_contains "$preview" 'unsupported_ext' 'nothing in an example-and-changelog-only diff is excluded as an unsupported extension'
pass 'an example-and-changelog-only change previews as reviewable'

# --- displacement -----------------------------------------------------------
#
# Read each file's group with and without the rule file and compare. A file the
# rule file does not claim must be byte-identical across the two reads; that is
# the property, rather than a remembered rule length that a vendor edit rots.

group_rule() { # <path> [--rule]
  local path=$1
  shift
  ocr delegate rule --repo "$REPO" "$@" -f json "$path" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["groups"][0]["rule"])'
}

for f in src/main.rs other.yaml; do
  before="$(group_rule "$f")"
  after="$(group_rule "$f" --rule "$RULE")"
  [ -n "$before" ] || fail "$f had no system rule to compare against"
  [ "$before" = "$after" ] || fail "adding review-rule.json displaced $f's system group; first-match-wins means a custom pattern REPLACES a built-in one, so this rule file is now removing coverage it does not carry forward"
done
pass 'unclaimed files keep their system rule group unchanged'

# The compose pattern is the one deliberate displacement: it takes over the
# system yaml group, so that group's content must survive inside it.
compose_sys="$(group_rule docker-compose.yml)"
compose_new="$(group_rule docker-compose.yml --rule "$RULE")"
[ "$compose_sys" != "$compose_new" ] || fail 'the compose pattern did not take effect, so this displacement check is vacuous'
assert_contains "$compose_new" 'spelling errors in yaml-keys' \
  'the compose rule carries forward the system yaml-key spellcheck it displaces'
pass 'the one displaced system group survives inside the rule that replaced it'
