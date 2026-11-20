#!/bin/sh
# Build the actual initializer image and exercise it without either agent.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-init:test
uid=$(id -u)
gid=$(id -g)
# Even a root test runner must exercise non-root initialization.
if [ "$uid" -eq 0 ]; then uid=7777; gid=7777; fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
chmod 0755 "$test_dir"
mkdir "$test_dir/project"
# A root runner uses UID 7777 and can clean up its files afterward.
if [ "$(id -u)" -eq 0 ]; then chmod 0777 "$test_dir/project"; fi

docker build --quiet --target session-init --tag "$image" "$sandbox_dir" >/dev/null
[ "$(docker run --rm --network none "$image" id -u)" = 65534 ]
docker run --rm --network none --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges --user "$uid:$gid" \
    -v "$test_dir/project:/project" -e HOST_PWD=/example/project \
    "$image" sandbox-init-config --reference /example </dev/null
[ -f "$test_dir/project/.sandbox/env" ]
[ "$(stat -c '%u:%g:%a' "$test_dir/project/.sandbox/env")" = "$uid:$gid:600" ]
[ "$(stat -c '%u:%g:%a' "$test_dir/project/.sandbox/agent.env")" = "$uid:$gid:600" ]
grep -Fxq agent.env "$test_dir/project/.sandbox/.gitignore"
grep -Fxq COMPOSE_PROJECT_NAME=project "$test_dir/project/.sandbox/env"
grep -Fxq SANDBOX_REFERENCE=/example "$test_dir/project/.sandbox/env"
grep -Fxq "SANDBOX_UID=$uid" "$test_dir/project/.sandbox/env"
grep -Fxq "SANDBOX_GID=$gid" "$test_dir/project/.sandbox/env"
docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges "$image" sh -ceu '
        if command -v claude || command -v codex; then
            echo "Init image unexpectedly contains an agent" >&2
            exit 1
        fi
    '
# Only explicit targets build; the final stage refuses an untargeted build.
if docker build --quiet "$sandbox_dir" >"$test_dir/untargeted.log" 2>&1; then
    echo 'An untargeted build unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq 'Name an image with --target' "$test_dir/untargeted.log"
echo 'Init image tests passed.'
