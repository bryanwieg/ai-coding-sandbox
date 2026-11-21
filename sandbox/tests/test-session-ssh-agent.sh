#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# Runtime test for the session-ssh-agent image with throwaway keys: unlock
# refuses keys with loose permissions and loads keys with or without a
# passphrase; a client with only the socket can use the keys but cannot see
# the key folder. The sidecar has no network, serves through key expiry and
# stops with its broker. It needs Docker and ssh-keygen on the host.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-session-ssh-agent:test
prefix=sandbox-ssh-agent-test-$$
broker=$prefix-broker
uid=$(id -u)
gid=$(id -g)
test_dir=$(mktemp -d)
failures=0
# shellcheck source=lifecycle-helper.sh
. "$sandbox_dir/tests/lifecycle-helper.sh"

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-ssh-agent --tag "$image" "$sandbox_dir" >/dev/null
lifecycle_build
lifecycle_start "$broker"
lifecycle_hold "$broker" "$image"

keys=$test_dir/keys
mkdir -m 0700 "$keys"
ssh-keygen -q -t ed25519 -N 'test-passphrase' -C protected -f "$keys/protected"
ssh-keygen -q -t ed25519 -N '' -C free -f "$keys/free"
ssh-keygen -q -t ed25519 -N 'test-passphrase' -C loose -f "$keys/loose"
chmod 0644 "$keys/loose"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-key\n-----END OPENSSH PRIVATE KEY-----\n' > "$keys/corrupt"
chmod 0600 "$keys/corrupt"
mkdir "$test_dir/askpass"
printf '#!/bin/sh\necho test-passphrase\n' > "$test_dir/askpass/pass"
chmod 0755 "$test_dir/askpass/pass"

# Starts a sidecar with the ssh profile's settings on the given broker.
start_agent() {
    name=$1
    docker volume create --label "$prefix" "$name-socket" >/dev/null
    # shellcheck disable=SC2046 # lifecycle_mount prints the two mount arguments.
    docker run -d --name "$name" --label "$prefix" --network none \
        --user "$uid:$gid" --read-only --cap-drop ALL --security-opt no-new-privileges \
        -v "$keys:/keys:ro" -v "$name-socket:/run/ssh-agent" \
        $(lifecycle_mount "$2" services) "$image" >/dev/null
}

# Runs sandbox-ssh-unlock against sidecar $1 with the scripted passphrase.
unlock() {
    name=$1
    shift
    unlock_mode=
    if [ "${1:-}" = --if-needed ]; then
        unlock_mode=$1
        shift
    fi
    docker run --rm --label "$prefix" --network none \
        --user "$uid:$gid" --read-only --cap-drop ALL --security-opt no-new-privileges \
        -v "$keys:/keys:ro" -v "$name-socket:/run/ssh-agent:ro" -v "$test_dir/askpass:/askpass:ro" \
        -e SSH_ASKPASS=/askpass/pass -e SSH_ASKPASS_REQUIRE=force \
        "$@" --entrypoint sandbox-ssh-unlock "$image" ${unlock_mode:+"$unlock_mode"}
}

# Runs a command as an agent-side client that has only the socket.
client() {
    name=$1
    shift
    docker run --rm --label "$prefix" --network none --user "$uid:$gid" \
        -v "$name-socket:/run/ssh-agent:ro" -e SSH_AUTH_SOCK=/run/ssh-agent/agent.sock \
        --entrypoint sh "$image" -c "$*"
}

name=$prefix-main
start_agent "$name" "$broker"
output=$(unlock "$name" --if-needed 2>&1) || fail "unlock failed: $output"
if printf '%s\n' "$output" | grep -q 'Refusing loose: readable by group or others'; then
    pass 'a key readable by others is refused'
else
    fail 'a key readable by others was not refused'
fi
if printf '%s\n' "$output" | grep -q 'Error loading key "/keys/corrupt"'; then
    pass 'a corrupt key is rejected by ssh-add'
else
    fail 'a corrupt key was not rejected'
fi
output=$(unlock "$name" --if-needed 2>&1) || fail "conditional unlock failed: $output"
if [ "$output" = 'SSH keys are already unlocked.' ]; then
    pass 'conditional unlock reuses loaded keys without another passphrase prompt'
else
    fail "conditional unlock reloaded keys: $output"
fi
listed=$(client "$name" ssh-add -l 2>&1 || :)
if printf '%s\n' "$listed" | grep -q ' protected ' &&
    printf '%s\n' "$listed" | grep -q ' free ' &&
    ! printf '%s\n' "$listed" | grep -q -e ' loose ' -e ' corrupt '; then
    pass 'keys with and without passphrases are loaded through the socket'
else
    fail "unexpected agent keys: $listed"
fi
if client "$name" 'test ! -e /keys'; then
    pass 'a socket-only client cannot see the key folder'
else
    fail 'a socket-only client can see the key folder'
fi
if [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")" = none ] &&
    [ "$(docker exec "$name" sh -c 'ls /sys/class/net | tr "\n" " "')" = 'lo ' ]; then
    pass 'the sidecar has no network'
else
    fail 'the sidecar has a network'
fi

name=$prefix-expiry
start_agent "$name" "$broker"
unlock "$name" -e SANDBOX_SSH_KEY_LIFETIME=3s >/dev/null 2>&1 || fail 'expiry: unlock failed'
sleep 5
if client "$name" 'ssh-add -l; test "$?" -eq 1' &&
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
    pass 'keys expire while the sidecar keeps serving the socket'
else
    fail 'expected a running sidecar with no keys after expiry'
fi

name=$prefix-drain
drain_broker=$prefix-drain-broker
lifecycle_start "$drain_broker"
start_agent "$name" "$drain_broker"
docker exec "$name" timeout 10 sh -c 'until test -S /run/ssh-agent/agent.sock; do sleep 0.1; done'
lifecycle_drain "$drain_broker" &
drain_pid=$!
if [ "$(timeout 10 docker wait "$name")" = 0 ] && client "$name" 'test ! -e /run/ssh-agent/agent.sock'; then
    pass 'the sidecar exits 0 within 10 seconds of drain and removes its socket'
else
    fail 'the sidecar failed to drain cleanly or left its socket behind'
fi
wait "$drain_pid" || fail 'the broker failed to drain'

bare_agent=$(docker run -d --label "$prefix" --network none --user "$uid:$gid" \
    --read-only --cap-drop ALL --security-opt no-new-privileges "$image")
if [ "$(timeout 15 docker wait "$bare_agent")" = 1 ] &&
    docker logs "$bare_agent" 2>&1 | grep -Fq 'cannot reach the lifecycle broker'; then
    pass 'without a broker the sidecar exits 1 within 15 seconds'
else
    fail 'expected an unreachable broker error and exit 1'
fi

name=$prefix-none
start_agent "$name" "$broker"
chmod 0600 "$keys/loose"
rm "$keys/protected" "$keys/free" "$keys/loose" "$keys/corrupt"
if ! unlock "$name" >/dev/null 2>&1; then
    pass 'unlock fails when no key can be loaded'
else
    fail 'unlock succeeded without loading a key'
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session ssh-agent checks passed.'
