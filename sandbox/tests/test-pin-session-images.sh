#!/bin/sh
# pin-session-images: every image pinned, partial or invalid input refused,
# and the pinned file still loads with all profiles.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
pin="$root_dir/bin/pin-session-images"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

digest() { printf 'sha256:%064d' "$1"; }
set -- agent="$(digest 1)" docker-daemon="$(digest 3)" \
    proxy="$(digest 4)" forwarder="$(digest 5)" ssh-agent="$(digest 6)" lifecycle="$(digest 7)"

"$pin" "$@" > "$test_dir/compose.yaml"
[ "$(grep -c 'image: ghcr.io/bryanwieg/ai-coding-sandbox@sha256:' "$test_dir/compose.yaml")" -eq \
    "$(grep -c '^[[:space:]]*image:' "$root_dir/compose.session.yaml")" ]
grep -Fq "ai-coding-sandbox@$(digest 1)" "$test_dir/compose.yaml"
grep -Fq "ai-coding-sandbox@$(digest 6)" "$test_dir/compose.yaml"
(cd "$test_dir" && env SANDBOX_UID=1000 SANDBOX_GID=1000 SANDBOX_REFERENCE=/tmp \
    docker compose -f compose.yaml --profile claude --profile codex --profile docker \
    --profile publish --profile ssh --profile tools config --quiet)

if "$pin" agent="$(digest 1)" > /dev/null 2>"$test_dir/err"; then exit 1; fi
grep -Fq 'are not pinned' "$test_dir/err"
if "$pin" agent=sha256:short 2>"$test_dir/err"; then exit 1; fi
grep -Fq 'invalid digest' "$test_dir/err"
if "$pin" claude="$(digest 1)" 2>"$test_dir/err"; then exit 1; fi
grep -Fq 'unknown image' "$test_dir/err"

echo 'pin-session-images tests passed.'
