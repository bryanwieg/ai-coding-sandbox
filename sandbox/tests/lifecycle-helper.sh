#!/bin/sh
# shellcheck disable=SC2154 # sandbox_dir and prefix come from the caller.
# Sourced by image tests. The caller sets sandbox_dir and prefix, and removes
# containers and volumes with that label on exit.
lifecycle_image=ai-coding-sandbox-session-lifecycle:test

lifecycle_build() {
    docker build --quiet --target session-lifecycle --tag "$lifecycle_image" "$sandbox_dir" >/dev/null
}

lifecycle_start() (
    docker volume create --label "$prefix" "$1-lifecycle" >/dev/null || return 1
    docker run -d --name "$1" --label "$prefix" --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges --user 13:13 \
        --tmpfs /tmp:uid=13,gid=13,mode=0700 -v "$1-lifecycle:/run/sandbox-lifecycle" \
        "$lifecycle_image" >/dev/null || return 1
    tries=0
    until docker exec "$1" /usr/local/bin/sandbox-lifecycle ready 2>/dev/null; do
        [ "$tries" -lt 10 ] || return 1
        sleep 1
        tries=$((tries + 1))
    done
)

lifecycle_mount() {
    printf '%s\n' "--mount type=volume,src=$1-lifecycle,dst=/run/sandbox-lifecycle,readonly,volume-subpath=$2"
}

lifecycle_status() {
    docker exec "$1" /usr/local/bin/sandbox-lifecycle status
}

lifecycle_field() (
    status=$(lifecycle_status "$1") || return 1
    printf '%s\n' "$status" | sed -n "s/^$2=//p"
)

lifecycle_hold() (
    # shellcheck disable=SC2046 # lifecycle_mount prints the two mount arguments.
    docker run -d --name "$1-hold" --label "$prefix" --network none --read-only \
        --user 1000:1000 $(lifecycle_mount "$1" agents) --entrypoint /usr/local/bin/sandbox-lifecycle \
        "$2" run claude -- sleep 86400 >/dev/null || return 1
    tries=0
    until [ "$(lifecycle_field "$1" state)" = active ]; do
        [ "$tries" -lt 5 ] || return 1
        sleep 1
        tries=$((tries + 1))
    done
)

lifecycle_release() {
    docker rm -f "$1-hold" >/dev/null
}

lifecycle_drain() {
    docker exec "$1" /usr/local/bin/sandbox-lifecycle stop && timeout 30 docker wait "$1" >/dev/null
}
