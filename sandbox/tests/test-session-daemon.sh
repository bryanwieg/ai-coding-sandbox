#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# Runtime test for the rootless session daemon. Covers UID and group checks,
# broker admission and drain, ephemeral and persistent data, container stop
# timeouts, the bind-mountable daemon socket and anonymous-volume cleanup.
# Run locally on a Docker host that supports the rootless daemon.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-session-daemon:test
prefix=sandbox-daemon-test-$$
broker=$prefix-broker
network=$prefix-net
test_dir=$(mktemp -d)
failures=0

# shellcheck source=lifecycle-helper.sh
. "$sandbox_dir/tests/lifecycle-helper.sh"

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    docker network rm "$network" >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-daemon --tag "$image" "$sandbox_dir" >/dev/null
lifecycle_build
lifecycle_start "$broker"
lifecycle_hold "$broker" "$image"
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
    # shellcheck disable=SC2046 # lifecycle_mount prints the two mount arguments.
    docker run -d --name "$name" --hostname docker --label "$prefix" \
        $(lifecycle_mount "$broker" daemon) --network "$network" --network-alias docker \
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

# Admission is checked before the daemon script starts.
# shellcheck disable=SC2046 # lifecycle_mount prints the two mount arguments.
refused=$(docker run -d --label "$prefix" --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges $(lifecycle_mount "$broker" services) "$image")
if [ "$(timeout 5 docker wait "$refused")" = 75 ]; then
    pass 'the services socket refuses the daemon'
else
    fail 'expected immediate refusal on the services socket with exit 75'
fi
bare=$(docker run -d --label "$prefix" --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges "$image")
if [ "$(timeout 15 docker wait "$bare")" = 1 ] &&
    docker logs "$bare" 2>&1 | grep -Fq 'cannot reach the lifecycle broker'; then
    pass 'without a broker the daemon exits 1 within 15 seconds'
else
    fail 'expected an unreachable broker error and exit 1'
fi

# Hold rm after its first deletion so even a fast volume is mid-wipe at drain.
name=$prefix-startup-wipe
startup_broker=$name-broker
wipe_test=$test_dir/startup-wipe
mkdir -m 0755 "$wipe_test"
cat > "$wipe_test/rm" <<'EOF'
#!/bin/sh
set -eu
/bin/rm -f "$2/first"
while [ ! -e /wipe-test/resume ]; do sleep 0.05; done
exec /bin/rm "$@"
EOF
printf '#!/bin/sh\necho daemon-entrypoint-started\nexit 99\n' > "$wipe_test/dockerd-entrypoint.sh"
chmod 755 "$wipe_test/rm" "$wipe_test/dockerd-entrypoint.sh"
docker volume create --label "$prefix" "$name-data" >/dev/null
docker run --rm -v "$name-data:/home/rootless/.local/share/docker" --entrypoint sh "$image" -ec '
    mkdir "$XDG_DATA_HOME/docker"
    cd "$XDG_DATA_HOME/docker"
    touch first
    seq 1 8192 | xargs touch
'
lifecycle_start "$startup_broker"
broker=$startup_broker start_daemon "$name" 1000 1000 -v "$wipe_test:/wipe-test:ro" \
    -e PATH=/wipe-test:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
docker exec "$name" timeout 10 sh -c 'while [ -e "$XDG_DATA_HOME/docker/first" ]; do sleep 0.05; done'
docker exec "$startup_broker" /usr/local/bin/sandbox-lifecycle stop
touch "$wipe_test/resume"
if [ "$(timeout 30 docker wait "$name")" = 0 ] &&
    ! docker logs "$name" 2>&1 | grep -Fxq daemon-entrypoint-started &&
    docker run --rm -v "$name-data:/data:ro" --entrypoint sh "$image" -c 'test ! -e /data/docker'; then
    pass 'a drain during the startup wipe finishes it and exits 0 without starting the daemon'
else
    fail 'the startup wipe was incomplete, the daemon started, or the drain failed'
fi

name=$prefix-wipe
drain_broker=$prefix-wipe-broker
lifecycle_start "$drain_broker"
broker=$drain_broker start_daemon "$name" 1000 1000
wait_ready "$name" 1000 || fail 'ephemeral: daemon did not become ready'
tar -C "$test_dir" -cf - Dockerfile marker | client "$name" 1000 build --quiet --tag wipe-test - >/dev/null 2>&1 ||
    fail 'ephemeral: build failed'

lifecycle_drain "$drain_broker" &
drain_pid=$!
if [ "$(timeout 30 docker wait "$name")" = 0 ]; then
    pass 'the daemon exits 0 within 30 seconds of drain'
else
    fail 'the daemon failed to drain cleanly within 30 seconds'
fi
wait "$drain_pid" || fail 'the ephemeral daemon broker failed to drain'
docker rm -f "$name" >/dev/null
if docker run --rm -v "$name-data:/data:ro" --entrypoint sh "$image" -c 'test ! -e /data/docker'; then
    pass 'the drain wipes the ephemeral data root'
else
    fail 'the drain left the ephemeral data root behind'
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

# Persistent data survives a broker drain and a restart, and
# switching back to ephemeral wipes it at the next start.
name=$prefix-keep
keep_broker=$prefix-keep-broker
lifecycle_start "$keep_broker"
broker=$keep_broker start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_DATA=persistent
wait_ready "$name" 1000 || fail 'persistent: daemon did not become ready'
tar -C "$test_dir" -cf - Dockerfile marker | client "$name" 1000 build --quiet --tag keep-test - >/dev/null 2>&1 ||
    fail 'persistent: build failed'
lifecycle_drain "$keep_broker"
if [ "$(timeout 5 docker wait "$name")" = 0 ]; then
    pass 'a persistent daemon exits cleanly on drain'
else
    fail 'the persistent daemon failed to drain cleanly'
fi
docker rm -f "$name" >/dev/null
start_daemon "$name" 1000 1000 -e SANDBOX_DOCKER_DATA=persistent
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
start_daemon "$name" 1000 1000
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
