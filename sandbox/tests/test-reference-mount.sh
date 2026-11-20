#!/bin/sh
# Exercise the actual Compose bind mounts without agent state or sidecars.
# An unrelated reference has no project mountpoint beneath it: nesting the
# writable project inside that read-only mount reproduces the runc failure.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
compose_file=${1:-$sandbox_dir/compose.session.yaml}
test_dir=$(mktemp -d)
project_name=sandbox-reference-test-$$
cleanup() {
    docker compose -f "$test_dir/compose.json" -p "$project_name" down --remove-orphans >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM
image=busybox:1.37
docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
mkdir -p "$test_dir/project/.sandbox/ssh" "$test_dir/unrelated"
printf 'reference marker\n' > "$test_dir/unrelated/marker"
: > "$test_dir/project/.sandbox/env"
chmod 0600 "$test_dir/project/.sandbox/env"

for reference in "$test_dir/unrelated" "$test_dir" ''; do
    (
        cd "$test_dir/project"
        env SANDBOX_UID="$(id -u)" SANDBOX_GID="$(id -g)" SANDBOX_REFERENCE="$reference" \
            docker compose -f "$compose_file" -p sandbox-reference-test --profile '*' config --format json
    ) |
        jq --arg image "$image" '{services: {session: (.services.codex |
            {image: $image, user, read_only, cap_drop, security_opt, working_dir,
             network_mode: "none", environment: {SANDBOX_REFERENCE: .environment.SANDBOX_REFERENCE},
             volumes: [.volumes[] | select(.type == "bind")]})}}' > "$test_dir/compose.json"
    docker compose -f "$test_dir/compose.json" -p "$project_name" run --rm -T session sh -ceu '
        test "$PWD" = /workspace/sandbox-reference-test
        touch project-marker && rm project-marker
        ! touch .sandbox/env 2>/dev/null
        if [ -n "$SANDBOX_REFERENCE" ]; then
            grep -rq "reference marker" /reference
            ! touch /reference/new-file 2>/dev/null
        else
            test ! -d /reference
            test ! -s /reference
        fi
        '
done
echo 'Reference mount tests passed (no, unrelated and enclosing references).'
