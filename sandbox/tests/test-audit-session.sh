#!/bin/sh
# The audit builds images explicitly. Its session helper must reuse those
# images even when the development overlay requests a build on every run.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
COMPOSE_FILE=$test_dir/compose.yaml
COMPOSE_PROJECT_NAME=sandbox-audit-session-test-$$
COMPOSE_PROFILES=
export COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES
cleanup() {
    docker compose --env-file "$test_dir/.sandbox/env" down --volumes --remove-orphans >/dev/null 2>&1 || :
    docker image rm "$COMPOSE_PROJECT_NAME:prebuilt" >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

image=$(sed -n 's/^busybox=//p' "$sandbox_dir/bin/audit-sandbox")
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
docker image tag "$image" "$COMPOSE_PROJECT_NAME:prebuilt"
mkdir "$test_dir/.sandbox"
: > "$test_dir/.sandbox/env"
cat > "$COMPOSE_FILE" <<EOF
services:
  claude:
    image: $COMPOSE_PROJECT_NAME:prebuilt
    pull_policy: build
    build: {context: .}
    network_mode: none
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
EOF

# Exercise the actual helper without running the full, network-dependent
# audit. A missing Dockerfile makes any unintended rebuild fail immediately.
eval "$(sed -n '/^session() {$/,/^}/p' "$sandbox_dir/bin/audit-sandbox")"
cd "$test_dir"
output=$(session claude 'echo audit-image-reused')
printf '%s\n' "$output" | grep -Fxq audit-image-reused
echo 'Audit session reuses its prebuilt image despite pull_policy: build.'
