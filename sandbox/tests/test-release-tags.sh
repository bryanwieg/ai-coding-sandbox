#!/bin/sh
# release-tags: next and last version tags, and fingerprints that ignore the
# build time and commit label but nothing else.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tags="$root_dir/bin/release-tags"
failures=0

check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: got [%s], expected [%s]\n' "$1" "$2" "$3" >&2
        failures=$((failures + 1))
    fi
}

list='claude-latest
claude-sha-0123abc
claude-2.1.99
claude-2.1.327
claude-2.1.327_1
claude-2.1.327_9
claude-2.1.327_10
claude-2.1.327_x
codex-latest
codex-0.170.0
proxy-latest
proxy-2026.11.19
proxy-2026.11.19_1
proxy-2026.12.01'

check 'a new version gets no suffix' "$(printf '%s\n' "$list" | "$tags" next claude-2.1.328)" claude-2.1.328
check 'a rebuilt version gets the next suffix' "$(printf '%s\n' "$list" | "$tags" next claude-2.1.327)" claude-2.1.327_11
check 'the first rebuild is _1' "$(printf '%s\n' "$list" | "$tags" next codex-0.170.0)" codex-0.170.0_1
check 'a longer version is not a rebuild' "$(printf 'codex-0.170.00\n' | "$tags" next codex-0.170.0)" codex-0.170.0
check 'a first release ID is the date' "$(printf '' | "$tags" next 2026.11.19)" 2026.11.19
check 'a second release that day is _1' "$(printf '2026.11.19\n2026.11.18_3\n' | "$tags" next 2026.11.19)" 2026.11.19_1
check 'the newest agent version tag' "$(printf '%s\n' "$list" | "$tags" last claude)" claude-2.1.327_10
check 'the newest dated tag' "$(printf '%s\n' "$list" | "$tags" last proxy)" proxy-2026.12.01
check 'moving and commit tags are not versions' "$(printf 'forwarder-latest\nforwarder-sha-1\n' | "$tags" last forwarder)" ''
check 'one image does not match another' "$(printf 'docker-daemon-2026.11.19\n' | "$tags" last docker)" ''

config='{"created":"2026-11-19T00:00:00Z","architecture":"amd64","os":"linux",
  "config":{"Env":["A=1"],"Labels":{"org.opencontainers.image.revision":"aaa","sandbox.agent":"claude"}},
  "rootfs":{"type":"layers","diff_ids":["sha256:1","sha256:2"]},"history":[{"created":"2026-11-19T00:00:00Z"}]}'
base=$(printf '%s' "$config" | "$tags" fingerprint)
rebuilt=$(printf '%s' "$config" | jq -c '.created = "2026-11-20T00:00:00Z" | .history[0].created = .created
    | .config.Labels["org.opencontainers.image.revision"] = "bbb"' | "$tags" fingerprint)
check 'a rebuild with the same content keeps its fingerprint' "$rebuilt" "$base"
platforms=$(printf '%s' "$config" | jq -c '{"linux/amd64": .}' | "$tags" fingerprint)
check 'a per-platform listing has the same fingerprint' "$platforms" "$base"
for change in '.rootfs.diff_ids[1] = "sha256:3"' '.config.Env = ["A=2"]' \
    '.config.Labels["sandbox.agent"] = "codex"'; do
    changed=$(printf '%s' "$config" | jq -c "$change" | "$tags" fingerprint)
    if [ "$changed" != "$base" ]; then
        printf 'ok   %s changes the fingerprint\n' "$change"
    else
        printf 'FAIL %s keeps the fingerprint\n' "$change" >&2
        failures=$((failures + 1))
    fi
done

[ "$failures" -eq 0 ] || exit 1
echo 'Release tag checks passed.'
