#!/bin/sh
# Runtime test for the session-ssh-agent image with throwaway keys: unlock
# refuses keys with loose permissions and loads keys with or without a
# passphrase; a client with only the socket can use the keys but cannot see
# the key folder; the sidecar has no network and exits after its grace period
# or once its keys expire. It needs Docker and ssh-keygen on the host.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-session-ssh-agent:test
prefix=sandbox-ssh-agent-test-$$
uid=$(id -u)
gid=$(id -g)
test_dir=$(mktemp -d)
failures=0

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-ssh-agent --tag "$image" "$sandbox_dir" >/dev/null

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

# Starts a sidecar with the ssh profile's settings. Arguments: name, then
# extra docker run options.
start_agent() {
    name=$1
    shift
    docker volume create --label "$prefix" "$name-socket" >/dev/null
    docker run -d --name "$name" --label "$prefix" --network none \
        --user "$uid:$gid" --read-only --cap-drop ALL --security-opt no-new-privileges \
        -v "$keys:/keys:ro" -v "$name-socket:/run/ssh-agent" \
        "$@" "$image" >/dev/null
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

wait_exit() {
    tries=0
    while [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; do
        tries=$((tries + 1))
        [ "$tries" -lt "$2" ] || return 1
        sleep 1
    done
}

name=$prefix-main
start_agent "$name"
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

name=$prefix-grace
start_agent "$name" -e SANDBOX_SSH_CHECK_INTERVAL=1 -e SANDBOX_SSH_START_GRACE=3
if wait_exit "$name" 15 && docker logs "$name" 2>&1 | grep -q 'nothing unlocked within 3s'; then
    pass 'the sidecar exits when nothing is unlocked in its grace period'
else
    fail 'the sidecar did not exit after its grace period'
fi

name=$prefix-expiry
start_agent "$name" -e SANDBOX_SSH_CHECK_INTERVAL=1 -e SANDBOX_SSH_START_GRACE=60
unlock "$name" -e SANDBOX_SSH_KEY_LIFETIME=4 >/dev/null 2>&1 || fail 'expiry: unlock failed'
if wait_exit "$name" 20 && docker logs "$name" 2>&1 | grep -q 'no keys left'; then
    pass 'the sidecar exits once its keys expire'
else
    fail 'the sidecar kept running after its keys expired'
fi

name=$prefix-none
start_agent "$name"
chmod 0600 "$keys/loose"
rm "$keys/protected" "$keys/free" "$keys/loose" "$keys/corrupt"
if ! unlock "$name" >/dev/null 2>&1; then
    pass 'unlock fails when no key can be loaded'
else
    fail 'unlock succeeded without loading a key'
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session ssh-agent checks passed.'
