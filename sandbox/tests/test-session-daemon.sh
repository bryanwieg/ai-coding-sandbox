#!/bin/sh
# Runtime test for the generic session-daemon image: supported and unsupported
# UIDs, the UID/GID notice, the startup grace period, the proxy hold while
# starting, the client lease, the launch hold, the data wipe, the short
# container stop timeout only for ephemeral data, the socket that containers
# bind-mount to manage the daemon, and that no anonymous volumes are left
# behind. It needs a Docker host that can run the rootless daemon, so it
# is run explicitly, not in CI.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-session-daemon:test
prefix=sandbox-daemon-test-$$
network=$prefix-net
test_dir=$(mktemp -d)
failures=0

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    docker network rm "$network" >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-daemon --tag "$image" "$sandbox_dir" >/dev/null
docker network create --internal --label "$prefix" "$network" >/dev/null
docker volume ls -q --filter dangling=true | sort > "$test_dir/dangling-before"

# Starts a daemon with the session daemon's runtime settings, reachable as
# "docker" like in a session (its certificate names that host); daemons run one
# at a time. Arguments: name,
# UID, GID, then extra docker run options.
start_daemon() {
    name=$1 uid=$2 gid=$3
    shift 3
    for volume in "$name-data" "$name-certs"; do
        docker volume inspect "$volume" >/dev/null 2>&1 ||
            docker volume create --label "$prefix" "$volume" >/dev/null
    done
    docker run -d --name "$name" --hostname docker --label "$prefix" \
        --network "$network" --network-alias docker \
        --user "$uid:$gid" --read-only \
        --cap-drop ALL --cap-add SETUID --cap-add SETGID \
        --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
        --security-opt label=disable --device /dev/net/tun \
        --tmpfs "/run:uid=$uid,gid=$gid,mode=0755" --tmpfs /tmp:mode=1777 \
        --tmpfs /var/lib/docker \
        -v "$name-data:/home/rootless/.local/share/docker" \
        -v "$name-certs:/certs" \
        -e "XDG_RUNTIME_DIR=/run/user/$uid" \
        "$@" "$image" >/dev/null
}

# Waits until the daemon answers on its socket and the client key exists.
wait_ready() {
    name=$1 uid=$2
    tries=0
    until docker exec "$name" sh -c "docker --host unix:///run/user/$uid/docker.sock info >/dev/null 2>&1 && test -s /certs/client/key.pem" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 60 ] || return 1
        sleep 1
    done
}

# Waits up to $2 seconds for the container to exit on its own.
wait_exit() {
    tries=0
    while [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; do
        tries=$((tries + 1))
        [ "$tries" -lt "$2" ] || return 1
        sleep 1
    done
}

# Runs the Docker CLI as a TLS client of daemon $1 with UID $2.
client() {
    name=$1 uid=$2
    shift 2
    docker run --rm -i --label "$prefix" --network "$network" --user "$uid:$uid" \
        -v "$name-certs:/certs:ro" -e DOCKER_HOST=tcp://docker:2376 \
        -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_CONFIG=/tmp/docker \
        --entrypoint docker "$image" "$@"
}

for uid in 501 1000 4242 65533; do
    name=$prefix-uid$uid
    start_daemon "$name" "$uid" "$uid"
    if ! wait_ready "$name" "$uid"; then
        fail "UID $uid: daemon did not become ready"
        docker logs "$name" 2>&1 | tail -5 >&2
        continue
    fi
    printf 'FROM scratch\nCOPY marker /marker\n' > "$test_dir/Dockerfile"
    echo marker > "$test_dir/marker"
    if client "$name" "$uid" info --format '{{.SecurityOptions}}' | grep -q rootless &&
        tar -C "$test_dir" -cf - Dockerfile marker |
            client "$name" "$uid" build --quiet --tag scratch-test - >/dev/null 2>&1; then
        pass "UID $uid: rootless daemon builds over TLS"
    else
        fail "UID $uid: rootless info or build failed"
    fi
    docker rm -f "$name" >/dev/null
done

# Containers that bind-mount /var/run/docker.sock manage this same daemon:
# they list containers, start nested ones, and those bind-mount the project
# at the same path with files owned by the user. Container root owns the
# socket, so the test image's non-root user needs group 0 and is refused
# without it. The test image, loaded into the daemon, supplies the CLI
# offline.
name=$prefix-socket
mkdir -m 0777 "$test_dir/project"
start_daemon "$name" 1000 1000 -v "$test_dir/project:/workspace"
if wait_ready "$name" 1000 && docker save "$image" | client "$name" 1000 load -q >/dev/null; then
    sock_run() {
        client "$name" 1000 run --rm -v /var/run/docker.sock:/var/run/docker.sock "$@"
    }
    if [ "$(sock_run --entrypoint stat "$image" -c %u:%g:%F /var/run/docker.sock)" = 0:0:socket ]; then
        pass 'the daemon socket is bind-mountable and owned by container root'
    else
        fail 'the daemon socket is missing or not owned by container root'
    fi
    if sock_run --group-add 0 --entrypoint docker "$image" ps --format '{{.Image}}' | grep -Fxq "$image" &&
        ! sock_run --entrypoint docker "$image" ps >/dev/null 2>&1; then
        pass 'a non-root container with group 0 lists the daemon its socket reaches'
    else
        fail 'the socket did not admit exactly the non-root container with group 0'
    fi
    if sock_run --user 0:0 -e DOCKER_HOST=unix:///var/run/docker.sock --entrypoint docker "$image" \
        run --rm --user 0:0 -v /workspace:/workspace --entrypoint sh "$image" -c 'echo nested-ok > /workspace/nested' &&
        [ "$(cat "$test_dir/project/nested" 2>/dev/null)" = nested-ok ] &&
        [ "$(stat -c %u "$test_dir/project/nested")" = 1000 ]; then
        pass 'a nested container bind-mounts the project and writes as the user'
    else
        fail 'a nested container could not write the project as the user'
    fi
else
    fail 'socket: daemon did not become ready or the test image did not load'
fi
docker rm -f "$name" >/dev/null

name=$prefix-gid
start_daemon "$name" 4242 4242 -e SANDBOX_GID=20
if wait_ready "$name" 4242 && docker logs "$name" 2>&1 | grep -q 'your group 20 differs'; then
    pass 'UID != GID: daemon runs as UID:UID with a notice'
else
    fail 'UID != GID: notice or start missing'
fi
docker rm -f "$name" >/dev/null

name=$prefix-badgid
start_daemon "$name" 4242 20
if wait_exit "$name" 20 && docker logs "$name" 2>&1 | grep -q 'run with group 4242'; then
    pass 'group other than the UID is refused'
else
    fail 'group other than the UID was not refused'
fi

name=$prefix-baduid
start_daemon "$name" 300 300
if wait_exit "$name" 20 && docker logs "$name" 2>&1 | grep -q 'UID 300 is not supported'; then
    pass 'unsupported UID is refused'
else
    fail 'unsupported UID was not refused'
fi

name=$prefix-grace
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_IDLE_INTERVAL=2 -e SANDBOX_DOCKER_START_GRACE=10
if wait_exit "$name" 40 && docker logs "$name" 2>&1 | grep -q 'within 10s'; then
    pass 'daemon stops after the grace period without a client'
else
    fail 'daemon did not stop after the grace period'
fi

# A launch hold, touched by the host just before a launch, keeps an otherwise
# idle daemon up until it expires.
name=$prefix-launch-hold
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_IDLE_INTERVAL=1 -e SANDBOX_DOCKER_START_GRACE=3 \
    -e SANDBOX_DOCKER_LAUNCH_HOLD=10
docker exec "$name" touch /tmp/launch-hold
sleep 6
if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
    pass 'a launch hold keeps an idle daemon up'
else
    fail 'the daemon stopped despite a fresh launch hold'
fi
if wait_exit "$name" 30; then
    pass 'the daemon stops once the launch hold expires'
else
    fail 'the daemon kept running after the launch hold expired'
fi
docker rm -f "$name" >/dev/null

# Until its first client connects, the daemon holds a connection to the proxy
# in HTTPS_PROXY, so a launch waiting for the daemon keeps the proxy alive;
# the agent's own lease replaces it. A listener stands in for the proxy and
# reports how many connections it holds.
proxy=$prefix-proxy
docker run -d --name "$proxy" --label "$prefix" --network "$network" --network-alias egress-proxy \
    --entrypoint sh "$image" -c 'nc -lk -p 3128 -e sh -c "cat >/dev/null"' >/dev/null
proxy_held() {
    docker exec "$proxy" sh -c 'netstat -tn | awk "\$4 ~ /:3128\$/ && \$6 == \"ESTABLISHED\"" | wc -l'
}
# Waits up to $2 seconds until the proxy holds $1 connections.
wait_held() {
    tries=0
    until [ "$(proxy_held)" -eq "$1" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt "$2" ] || return 1
        sleep 1
    done
}
name=$prefix-hold
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_IDLE_INTERVAL=2 -e HTTPS_PROXY=http://egress-proxy:3128
if wait_held 1 10; then
    pass 'a starting daemon holds a connection to the proxy'
else
    fail "a starting daemon held $(proxy_held) proxy connection(s), expected 1"
fi
wait_ready "$name" 1000 || fail 'hold: daemon did not become ready'
holder=$prefix-hold-client
docker run -d --name "$holder" --label "$prefix" --network "$network" --user 1000:1000 \
    -v "$name-certs:/certs:ro" -e DOCKER_HOST=tcp://docker:2376 \
    -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_CONFIG=/tmp/docker \
    --entrypoint docker "$image" events >/dev/null
if wait_held 0 15 && [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
    pass 'the proxy connection ends once a client connects'
else
    fail "the daemon still held $(proxy_held) proxy connection(s) with a client connected"
fi
docker rm -f -v "$holder" "$name" >/dev/null
docker rm -f -v "$proxy" >/dev/null

name=$prefix-lease
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_IDLE_INTERVAL=2 -e SANDBOX_DOCKER_START_GRACE=10
wait_ready "$name" 1000 || fail 'lease: daemon did not become ready'
printf 'FROM scratch\nCOPY marker /marker\n' > "$test_dir/Dockerfile"
tar -C "$test_dir" -cf - Dockerfile marker | client "$name" 1000 build --quiet --tag wipe-test - >/dev/null 2>&1 ||
    fail 'lease: build failed'
holder=$prefix-holder
docker run -d --name "$holder" --label "$prefix" --network "$network" --user 1000:1000 \
    -v "$name-certs:/certs:ro" -e DOCKER_HOST=tcp://docker:2376 \
    -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_CONFIG=/tmp/docker \
    --entrypoint docker "$image" events >/dev/null
sleep 20
if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
    pass 'daemon stays up past the grace period while a client holds the lease'
else
    fail 'daemon stopped although a client held the lease'
fi
# The client image declares volumes too; -v removes the holder's.
docker rm -f -v "$holder" >/dev/null
if wait_exit "$name" 30 && docker logs "$name" 2>&1 | grep -q 'no client connected;'; then
    pass 'daemon stops after the lease ends'
else
    fail 'daemon did not stop after the lease ended'
fi
docker rm -f "$name" >/dev/null
if [ -z "$(docker run --rm -v "$name-data:/data:ro" --entrypoint ls "$image" -A /data)" ]; then
    pass 'data root is wiped when the daemon stops'
else
    fail 'data root was left behind'
fi
start_daemon "$name" 1000 1000
if wait_ready "$name" 1000 && client "$name" 1000 info >/dev/null 2>&1 &&
    ! client "$name" 1000 image inspect wipe-test >/dev/null 2>&1; then
    pass 'a restarted daemon starts empty'
else
    fail 'a restarted daemon still had the previous image'
fi
# dockerd's arguments, one line per process.
daemon_args() { docker exec "$1" ps -o args | grep '^dockerd '; }
if daemon_args "$name" | grep -q -- '--shutdown-timeout=2'; then
    pass 'an ephemeral daemon gives its containers 2 seconds to stop'
else
    fail 'an ephemeral daemon kept the default container stop timeout'
fi
docker rm -f "$name" >/dev/null

name=$prefix-badretention
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_DATA=forever
if wait_exit "$name" 20 && docker logs "$name" 2>&1 | grep -q "SANDBOX_DOCKER_DATA must be ephemeral or persistent"; then
    pass 'unknown SANDBOX_DOCKER_DATA is refused'
else
    fail 'unknown SANDBOX_DOCKER_DATA was not refused'
fi
docker rm -f "$name" >/dev/null

# Persistent data survives the daemon stopping on its own and a restart, and
# switching back to ephemeral wipes it at the next start.
name=$prefix-keep
keep_env='-e SANDBOX_DOCKER_IDLE_INTERVAL=2 -e SANDBOX_DOCKER_START_GRACE=10'
# shellcheck disable=SC2086 # word-split options
start_daemon "$name" 1000 1000 $keep_env -e SANDBOX_DOCKER_DATA=persistent
wait_ready "$name" 1000 || fail 'persistent: daemon did not become ready'
tar -C "$test_dir" -cf - Dockerfile marker | client "$name" 1000 build --quiet --tag keep-test - >/dev/null 2>&1 ||
    fail 'persistent: build failed'
if wait_exit "$name" 40 && docker logs "$name" 2>&1 | grep -q 'no client connected;'; then
    pass 'a persistent daemon still stops once idle'
else
    fail 'a persistent daemon did not stop once idle'
fi
docker rm -f "$name" >/dev/null
# shellcheck disable=SC2086
start_daemon "$name" 1000 1000 $keep_env -e SANDBOX_DOCKER_DATA=persistent
if wait_ready "$name" 1000 && client "$name" 1000 image inspect keep-test >/dev/null 2>&1; then
    pass 'a restarted persistent daemon keeps its images'
else
    fail 'a restarted persistent daemon lost its images'
fi
if daemon_args "$name" | grep -q -- '--shutdown-timeout'; then
    fail 'a persistent daemon shortened the container stop timeout'
else
    pass 'a persistent daemon keeps the default container stop timeout'
fi
docker rm -f "$name" >/dev/null
# shellcheck disable=SC2086
start_daemon "$name" 1000 1000 $keep_env
if wait_ready "$name" 1000 && client "$name" 1000 info >/dev/null 2>&1 &&
    ! client "$name" 1000 image inspect keep-test >/dev/null 2>&1; then
    pass 'an ephemeral start wipes data kept before'
else
    fail 'an ephemeral start kept the earlier data'
fi
docker rm -f "$name" >/dev/null

docker volume ls -q --filter dangling=true | sort > "$test_dir/dangling-after"
docker volume ls -q --filter "label=$prefix" | sort > "$test_dir/own"
leaked=$(comm -13 "$test_dir/dangling-before" "$test_dir/dangling-after" | comm -23 - "$test_dir/own")
if [ -z "$leaked" ]; then
    pass 'no anonymous volumes are left behind'
else
    fail "anonymous volumes left behind: $(echo "$leaked" | tr '\n' ' ')"
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session daemon checks passed.'
