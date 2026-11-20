#!/bin/sh
# Runtime test for the session-forwarder image against a real session daemon:
# a single port and a range reach containers in the daemon from the host,
# extra TCP slots and UDP slots do too, idle UDP clients expire without
# stopping the relay, unset ports exit cleanly, invalid values and more than
# 100 ports in all are refused, the forwarder exits
# with the daemon, and its publish network has no Internet egress. It needs a
# Docker host that can run the rootless daemon, so it is run explicitly.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
daemon_image=ai-coding-sandbox-session-daemon:test
forwarder_image=ai-coding-sandbox-session-forwarder:test
prefix=sandbox-forwarder-test-$$
internal=$prefix-internal
publish=$prefix-publish
control=$prefix-control
daemon=$prefix-daemon
base=$((20000 + $$ % 10000))
udp_base=$((base + 10))
failures=0

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    for network in "$internal" "$publish" "$control"; do
        docker network rm "$network" >/dev/null 2>&1 || :
    done
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-daemon --tag "$daemon_image" "$sandbox_dir" >/dev/null
docker build --quiet --target session-forwarder --tag "$forwarder_image" "$sandbox_dir" >/dev/null
docker network create --internal --label "$prefix" "$internal" >/dev/null
docker network create --label "$prefix" \
    -o com.docker.network.bridge.enable_ip_masquerade=false "$publish" >/dev/null

for volume in "$daemon-data" "$daemon-certs"; do
    docker volume create --label "$prefix" "$volume" >/dev/null
done
docker run -d --name "$daemon" --label "$prefix" \
    --network "$internal" --network-alias docker --user 1000:1000 --read-only \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID \
    --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
    --security-opt label=disable --device /dev/net/tun \
    --tmpfs /run:uid=1000,gid=1000,mode=0755 --tmpfs /tmp:mode=1777 --tmpfs /var/lib/docker \
    -v "$daemon-data:/home/rootless/.local/share/docker" -v "$daemon-certs:/certs" \
    -e XDG_RUNTIME_DIR=/run/user/1000 -e SANDBOX_DOCKER_START_GRACE=600 \
    "$daemon_image" >/dev/null

client() {
    docker run --rm -i --label "$prefix" --network "$internal" --user 1000:1000 \
        -v "$daemon-certs:/certs:ro" -e DOCKER_HOST=tcp://docker:2376 \
        -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_CONFIG=/tmp/docker \
        --entrypoint docker "$daemon_image" "$@"
}

tries=0
until client info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || { echo 'The session daemon did not become ready.' >&2; exit 1; }
    sleep 1
done
# Hold a client lease, as a session does, so the daemon stays up between checks.
docker run -d --name "$prefix-lease" --label "$prefix" --network "$internal" --user 1000:1000 \
    -v "$daemon-certs:/certs:ro" -e DOCKER_HOST=tcp://docker:2376 \
    -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_CONFIG=/tmp/docker \
    --entrypoint docker "$daemon_image" events >/dev/null
docker save busybox:1.37 | client load >/dev/null
for port in "$base" $((base + 1)) $((base + 2)); do
    client run -d -p "$port:8080" busybox:1.37 \
        sh -c "mkdir /w && echo reply-$port > /w/index.html && httpd -f -p 8080 -h /w" >/dev/null
done
# UDP echo services, using the forwarder image's socat.
docker save "$forwarder_image" | client load >/dev/null
for port in "$udp_base" $((udp_base + 1)); do
    client run -d -p "$port:9000/udp" --entrypoint socat "$forwarder_image" \
        UDP-LISTEN:9000,fork,reuseaddr "SYSTEM:echo udp-reply-$port" >/dev/null
done

# Starts a forwarder with the published-port settings. Arguments: name, the
# SANDBOX_PUBLISH_PORTS value, then extra docker create options.
start_forwarder() {
    name=$1 ports=$2
    shift 2
    docker create --name "$name" --label "$prefix" --network "$publish" \
        --user 65534:65534 --read-only --cap-drop ALL --security-opt no-new-privileges \
        -e "SANDBOX_PUBLISH_PORTS=$ports" -e SANDBOX_FORWARD_INTERVAL=1 \
        "$@" "$forwarder_image" >/dev/null
    docker network connect "$internal" "$name"
    docker start "$name" >/dev/null
}

wait_exit() {
    tries=0
    while [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; do
        tries=$((tries + 1))
        [ "$tries" -lt "$2" ] || return 1
        sleep 1
    done
}

fetch() {
    curl --silent --max-time 5 "http://127.0.0.1:$1/"
}

# Sends a UDP datagram to 127.0.0.1:$1 and prints the reply.
udp_fetch() {
    python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(5)
s.sendto(b"ping\n", ("127.0.0.1", int(sys.argv[1])))
try:
    print(s.recv(512).decode().strip())
except OSError:
    pass
' "$1"
}

start_forwarder "$prefix-single" "$base" -p "127.0.0.1:$base:$base"
sleep 2
if [ "$(fetch "$base")" = "reply-$base" ]; then
    pass 'a single port reaches its container in the daemon'
else
    fail 'a single port did not reach its container'
fi
docker rm -f -v "$prefix-single" >/dev/null

range="$((base + 1))-$((base + 2))"
start_forwarder "$prefix-range" "$range" -p "127.0.0.1:$range:$range"
sleep 2
if [ "$(fetch $((base + 1)))" = "reply-$((base + 1))" ] && [ "$(fetch $((base + 2)))" = "reply-$((base + 2))" ]; then
    pass 'every port of a range reaches its container'
else
    fail 'a port of the range did not reach its container'
fi

# Extra TCP and UDP slots in one forwarder; UDP children expire after 2 idle
# seconds while the listener keeps serving.
udp_range="$udp_base-$((udp_base + 1))"
start_forwarder "$prefix-slots" '' -e "SANDBOX_PUBLISH_PORTS_2=$base" -e "SANDBOX_PUBLISH_UDP_PORTS_3=$udp_range" \
    -e SANDBOX_FORWARD_UDP_IDLE=2 -p "127.0.0.1:$base:$base" -p "127.0.0.1:$udp_range:$udp_range/udp"
sleep 2
if [ "$(fetch "$base")" = "reply-$base" ]; then
    pass 'an extra TCP slot reaches its container'
else
    fail 'an extra TCP slot did not reach its container'
fi
if [ "$(udp_fetch "$udp_base")" = "udp-reply-$udp_base" ] &&
    [ "$(udp_fetch $((udp_base + 1)))" = "udp-reply-$((udp_base + 1))" ]; then
    pass 'every port of a UDP range reaches its container'
else
    fail 'a UDP port did not reach its container'
fi
sleep 5
if [ "$(docker inspect -f '{{.State.Running}}' "$prefix-slots")" = true ] &&
    [ "$(udp_fetch "$udp_base")" = "udp-reply-$udp_base" ]; then
    pass 'UDP relays keep serving after idle clients expire'
else
    fail 'the UDP relay stopped after an idle client expired'
    docker logs "$prefix-slots" 2>&1 | tail -5 >&2
fi
docker rm -f -v "$prefix-slots" >/dev/null

name=$prefix-unset
start_forwarder "$name" ''
if wait_exit "$name" 10 && [ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0 ]; then
    pass 'unset ports exit cleanly'
else
    fail 'unset ports did not exit cleanly'
fi

for value in 70000 9-5 0 08080 abc 8000-8100; do
    name=$prefix-invalid-$(printf '%s' "$value" | tr -c 'a-z0-9' '_')
    start_forwarder "$name" "$value"
    if wait_exit "$name" 10 && [ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 1 ]; then
        pass "invalid value refused: $value"
    else
        fail "invalid value accepted: $value"
    fi
done
for slot in SANDBOX_PUBLISH_PORTS_3 SANDBOX_PUBLISH_UDP_PORTS SANDBOX_PUBLISH_UDP_PORTS_2; do
    name=$prefix-invalid-$(printf '%s' "$slot" | tr 'A-Z_' 'a-z-')
    start_forwarder "$name" "$base" -e "$slot=9-5"
    if wait_exit "$name" 10 && [ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 1 ]; then
        pass "an invalid $slot is refused before any relay starts"
    else
        fail "an invalid $slot was accepted"
    fi
done
name=$prefix-over
start_forwarder "$name" 30000-30060 -e SANDBOX_PUBLISH_UDP_PORTS=30000-30039
if wait_exit "$name" 10 && [ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 1 ] &&
    docker logs "$name" 2>&1 | grep -q 'at most 100 ports'; then
    pass 'more than 100 ports across slots are refused'
else
    fail 'more than 100 ports across slots were accepted'
fi

name=$prefix-hundred
start_forwarder "$name" 30000-30099
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; then
    pass 'a 100-port range is accepted'
else
    fail 'a 100-port range was refused'
fi
docker rm -f -v "$name" >/dev/null

docker network create --label "$prefix" "$control" >/dev/null
if docker run --rm --label "$prefix" --network "$control" busybox:1.37 nc -w 3 8.8.8.8 53 </dev/null >/dev/null 2>&1; then
    if docker run --rm --label "$prefix" --network "$publish" busybox:1.37 nc -w 3 8.8.8.8 53 </dev/null >/dev/null 2>&1; then
        fail 'the publish network reaches the Internet'
    else
        pass 'the publish network has no Internet egress'
    fi
else
    echo 'skip egress check: this host cannot reach 8.8.8.8:53 on a normal bridge'
fi

docker rm -f -v "$daemon" >/dev/null
if wait_exit "$prefix-range" 20 && docker logs "$prefix-range" 2>&1 | grep -q 'session daemon is gone'; then
    pass 'the forwarder exits after the daemon is gone'
else
    fail 'the forwarder kept running without the daemon'
    docker logs "$prefix-range" 2>&1 | tail -5 >&2
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session forwarder checks passed.'
