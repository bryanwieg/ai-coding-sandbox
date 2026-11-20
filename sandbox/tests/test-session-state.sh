#!/bin/sh
# Runtime test, in the agent base image, for the session state services and
# entrypoint: sandbox-initialize-state's if-needed ownership,
# sandbox-migrate-state copying old state only into empty volumes, and the
# entrypoint's proxy and Docker leases, or cleared Docker variables without a
# daemon.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-base:test
failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target base --tag "$image" "$sandbox_dir" >/dev/null

# as_root SCRIPT: runs SCRIPT with the capabilities the Compose services add,
# on tmpfs paths, and prints its output.
as_root() {
    docker run --rm --user 0:0 --read-only --cap-drop ALL \
        --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE \
        --security-opt no-new-privileges:true --network none \
        --tmpfs /state --tmpfs /from --tmpfs /to --tmpfs /certs:mode=0755 --tmpfs /cache \
        --entrypoint sh "$image" -c "$1" 2>&1
}

# A volume root that already has the owner is left alone with if-needed.
output=$(as_root 'touch /state/inner && chown 4321:4321 /state/inner && chown 7777:7777 /state &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_STATE_CHOWN=if-needed sandbox-initialize-state >/dev/null &&
    stat -c %u /state/inner')
if [ "$output" = 4321 ]; then pass 'if-needed skips an owned volume'; else fail "if-needed owned: $output"; fi

output=$(as_root 'touch /state/inner && chown 4321:4321 /state/inner && chown 0:0 /state &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_STATE_CHOWN=if-needed sandbox-initialize-state >/dev/null &&
    stat -c %u:%g /state /state/inner | tr "\n" " "')
if [ "$output" = '7777:7777 7777:7777 ' ]; then pass 'if-needed fixes a root-owned volume'; else fail "if-needed root: $output"; fi

output=$(as_root 'touch /state/inner && chown 4321:4321 /state/inner && chown 7777:7777 /state &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 sandbox-initialize-state >/dev/null &&
    stat -c %u /state/inner')
if [ "$output" = 7777 ]; then pass 'the default still normalizes everything'; else fail "always: $output"; fi

# Agents mount the daemon's client/ certificate folder, so it must exist
# before the daemon ever runs, writable by the daemon; existing certificates
# are kept.
output=$(as_root 'touch /state/inner && chown 7777:7777 /state &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_STATE_CHOWN=if-needed \
        SANDBOX_DOCKER_CERTS_DIR=/certs sandbox-initialize-state >/dev/null &&
    stat -c %a /certs /certs/client | tr "\n" " " && touch /certs/client/cert.pem &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_DOCKER_CERTS_DIR=/certs sandbox-initialize-state >/dev/null &&
    test -f /certs/client/cert.pem && echo kept')
if [ "$output" = '1777 1777 kept' ]; then
    pass 'the init creates the client certificate folder and keeps certificates'
else
    fail "client certificate folder: $output"
fi

# The cache volume gets the same owner, with the same if-needed rule.
output=$(as_root 'chown 7777:7777 /state && mkdir /cache/go && chown 0:0 /cache /cache/go &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_STATE_CHOWN=if-needed \
        SANDBOX_OWNED_DIRS=/cache sandbox-initialize-state >/dev/null &&
    stat -c %u:%g /cache /cache/go | tr "\n" " " && chown 4321:4321 /cache/go &&
    SANDBOX_STATE_DIR=/state SANDBOX_STATE_OWNER=7777:7777 SANDBOX_STATE_CHOWN=if-needed \
        SANDBOX_OWNED_DIRS=/cache sandbox-initialize-state >/dev/null &&
    stat -c %u /cache/go')
if [ "$output" = '7777:7777 7777:7777 4321' ]; then
    pass 'the init gives the cache volume to the owner, skipping an owned one'
else
    fail "cache volume ownership: $output"
fi

if as_root 'SANDBOX_STATE_DIR=/state SANDBOX_STATE_CHOWN=sometimes sandbox-initialize-state' | grep -Fq 'Unsupported SANDBOX_STATE_CHOWN'; then
    pass 'an unknown chown mode is refused'
else
    fail 'an unknown chown mode was accepted'
fi

# Old state is copied, given to the owner, and never copied over new state.
output=$(as_root 'mkdir -p /from/claude/projects/-workspace-src-demo /from/codex /to/claude /to/codex &&
    echo memory > /from/claude/projects/-workspace-src-demo/MEMORY.md && chmod 600 /from/claude/projects/-workspace-src-demo/MEMORY.md &&
    chown -R 1000:1000 /from/claude &&
    SANDBOX_STATE_OWNER=7777:7777 sandbox-migrate-state &&
    stat -c "%u:%g %a" /to/claude/projects/-workspace-src-demo/MEMORY.md && cat /to/claude/projects/-workspace-src-demo/MEMORY.md')
if printf '%s\n' "$output" | grep -Fxq 'Migrated the claude state.' &&
    printf '%s\n' "$output" | grep -Fxq 'No old codex state to migrate.' &&
    printf '%s\n' "$output" | grep -Fxq '7777:7777 600' && printf '%s\n' "$output" | grep -Fxq memory; then
    pass 'migration copies old state with its paths and modes'
else
    fail "migration: $output"
fi

output=$(as_root 'mkdir -p /from/claude /to/claude /to/codex && echo old > /from/claude/a && echo new > /to/claude/a &&
    SANDBOX_STATE_OWNER=7777:7777 sandbox-migrate-state && cat /to/claude/a')
if printf '%s\n' "$output" | grep -Fq 'already has state' && [ "$(printf '%s\n' "$output" | tail -n 1)" = new ]; then
    pass 'migration leaves a volume with state unchanged'
else
    fail "migration over state: $output"
fi

output=$(as_root 'mkdir -p /to/codex && SANDBOX_STATE_OWNER=7777:7777 sandbox-migrate-state')
if [ "$output" = "$(printf 'No old codex state to migrate.\nMigration finished: 0 volume(s) changed.')" ]; then
    pass 'migration handles only the mounted agent'
else
    fail "migration of one agent: $output"
fi
# A merge adds missing conversations, memory and history, never overwrites a
# file, keeps the current settings, and names what it leaves out.
output=$(as_root 'mkdir -p /from/claude/projects/-workspace-a/memory /from/claude/skills/old-skill /to/claude/projects/-workspace-a /to/codex &&
    echo old-session > /from/claude/projects/-workspace-a/s1.jsonl && echo old-memory > /from/claude/projects/-workspace-a/memory/MEMORY.md &&
    echo old-copy > /from/claude/projects/-workspace-a/s2.jsonl && echo current > /to/claude/projects/-workspace-a/s2.jsonl &&
    echo old-settings > /from/claude/settings.json && echo current-settings > /to/claude/settings.json &&
    printf "{\"display\":\"b\",\"timestamp\":2}\n{\"display\":\"a\",\"timestamp\":1}\n" > /from/claude/history.jsonl &&
    printf "{\"display\":\"c\",\"timestamp\":3}\n{\"display\":\"a\",\"timestamp\":1}\n" > /to/claude/history.jsonl &&
    chown -R 1000:1000 /from/claude &&
    SANDBOX_STATE_OWNER=7777:7777 SANDBOX_MIGRATE_MODE=merge sandbox-migrate-state &&
    cat /to/claude/projects/-workspace-a/s1.jsonl /to/claude/projects/-workspace-a/memory/MEMORY.md \
        /to/claude/projects/-workspace-a/s2.jsonl /to/claude/settings.json &&
    jq -r .display /to/claude/history.jsonl | tr -d "\n" && echo &&
    stat -c %u:%g /to/claude/projects/-workspace-a/memory/MEMORY.md')
if printf '%s\n' "$output" | grep -Fxq 'projects: added 2 file(s), kept 1 existing.' &&
    printf '%s\n' "$output" | grep -Fxq 'History: 3 prompt(s).' &&
    printf '%s\n' "$output" | grep -Fq 'Not merged: skills/ (old-skill' &&
    printf '%s\n' "$output" | grep -Fxq old-session && printf '%s\n' "$output" | grep -Fxq old-memory &&
    printf '%s\n' "$output" | grep -Fxq current && printf '%s\n' "$output" | grep -Fxq current-settings &&
    ! printf '%s\n' "$output" | grep -Fxq old-copy && printf '%s\n' "$output" | grep -Fxq abc &&
    printf '%s\n' "$output" | grep -Fxq 7777:7777; then
    pass 'a merge adds missing conversations, memory and history without overwriting'
else
    fail "merge: $output"
fi
if as_root 'mkdir -p /from/claude /to/claude && echo x > /from/claude/a && SANDBOX_STATE_OWNER=1:1 SANDBOX_MIGRATE_MODE=merge sandbox-migrate-state' |
    grep -Fq 'copy the current state first'; then
    pass 'a merge into an empty volume is refused'
else
    fail 'a merge into an empty volume was accepted'
fi
if as_root 'mkdir -p /from/claude /to/claude && echo x > /from/claude/a && echo y > /to/claude/a && printf "not json\n{\"display\":\"x\"}\n" > /from/claude/history.jsonl &&
    printf "{\"display\":\"y\"}\n" > /to/claude/history.jsonl && SANDBOX_STATE_OWNER=1:1 SANDBOX_MIGRATE_MODE=merge sandbox-migrate-state; cat /to/claude/history.jsonl' |
    grep -Fxq '{"display":"y"}' && [ "$(as_root 'mkdir -p /from/claude /to/claude && echo x > /from/claude/a && echo y > /to/claude/a &&
    printf "not json\n" > /from/claude/history.jsonl && SANDBOX_STATE_OWNER=1:1 SANDBOX_MIGRATE_MODE=merge sandbox-migrate-state >/dev/null 2>&1; echo $?')" != 0 ]; then
    pass 'an unreadable history leaves the current history unchanged'
else
    fail 'an unreadable history replaced the current history'
fi
if as_root 'SANDBOX_STATE_OWNER=7777:7777 sandbox-migrate-state' | grep -Fq 'No state volume is mounted'; then
    pass 'migration without a target volume fails'
else
    fail 'migration without a target volume succeeded'
fi

# The entrypoint, for any command: no daemon clears the Docker variables, and
# a daemon gets a lease that reconnects when its connection drops. The stub
# docker command records each connection.
entrypoint() {
    docker run --rm --user "$(id -u):$(id -g)" --network none \
        -e SANDBOX_SESSION=1 -e DOCKER_HOST=tcp://docker:2376 -e DOCKER_TLS_VERIFY=1 -e DOCKER_CERT_PATH=/run/docker-certs \
        -e PATH=/stubs:/usr/local/bin:/usr/bin:/bin "$@"
}
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT HUP INT TERM
printf '#!/bin/sh\necho call >> /tmp/docker-calls\nsleep 1\nexit 1\n' > "$stubs/docker"
chmod 0755 "$stubs/docker"
# shellcheck disable=SC2016
output=$(entrypoint -v "$stubs:/stubs:ro" "$image" sh -c 'sleep 2; env | grep ^DOCKER_; cat /tmp/docker-calls 2>/dev/null; :')
if [ -z "$output" ]; then
    pass 'sessions without a daemon run without DOCKER_HOST or a Docker lease'
else
    fail "without a daemon: $output"
fi
# shellcheck disable=SC2016
output=$(entrypoint -v "$stubs:/stubs:ro" --add-host docker:127.0.0.1 "$image" sh -c 'sleep 6; env | grep -c ^DOCKER_; wc -l < /tmp/docker-calls')
if [ "$(printf '%s\n' "$output" | sed -n 1p)" = 3 ] && [ "$(printf '%s\n' "$output" | sed -n 2p)" -ge 2 ]; then
    pass 'sessions with a daemon keep DOCKER_HOST, and the lease reconnects'
else
    fail "with a daemon: $output"
fi
if [ "$(entrypoint "$image" sh -c 'sleep 1; ps -eo args | grep -c "[s]andbox-proxy-lease"')" = 1 ]; then
    pass 'sessions hold a proxy lease'
else
    fail 'sessions hold no proxy lease'
fi
# shellcheck disable=SC2016
if [ -z "$(docker run --rm --network none -v "$stubs:/stubs:ro" -e PATH=/stubs:/usr/local/bin:/usr/bin:/bin \
    -e DOCKER_HOST=tcp://docker:2376 --add-host docker:127.0.0.1 "$image" \
    sh -c 'sleep 2; cat /tmp/docker-calls 2>/dev/null; ps -eo args | grep "[s]andbox-proxy-lease"; :')" ]; then
    pass 'the image outside a session starts no leases'
else
    fail 'the image outside a session started a lease'
fi

# Plugins such as Ponytail write below XDG_CONFIG_HOME even when HOME is
# read-only. Exercise both agents and command overrides through the entrypoint.
for agent in claude codex; do
    # shellcheck disable=SC2016
    if docker run --rm --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true --user "$(id -u):$(id -g)" \
        --tmpfs /tmp:mode=1777 --tmpfs "/state:uid=$(id -u),gid=$(id -g)" \
        -e SANDBOX_USER="$agent" -e HOME="/home/$agent" \
        -e CLAUDE_CONFIG_DIR=/state/claude -e CODEX_HOME=/state/codex \
        "$image" sh -ceu '
            test "$XDG_CONFIG_HOME" = "/state/$SANDBOX_USER/xdg"
            mkdir -p "$XDG_CONFIG_HOME/ponytail/band"
            printf "key,name\ntest,task\n" > "$XDG_CONFIG_HOME/ponytail/band/test.csv"
            test -s "$XDG_CONFIG_HOME/ponytail/band/test.csv"
            ! touch "$HOME/xdg-test" 2>/dev/null
        '; then
        pass "$agent plugins can write their ledger with a read-only home"
    else
        fail "$agent plugins cannot write their ledger with a read-only home"
    fi
    # shellcheck disable=SC2016
    if [ "$(docker run --rm --network none --read-only --tmpfs /tmp:mode=1777 \
        --user "$(id -u):$(id -g)" -e SANDBOX_USER="$agent" \
        -e XDG_CONFIG_HOME=/tmp/custom-xdg "$image" sh -c 'printf "%s" "$XDG_CONFIG_HOME"')" = /tmp/custom-xdg ]; then
        pass "$agent preserves an explicit XDG_CONFIG_HOME"
    else
        fail "$agent replaced an explicit XDG_CONFIG_HOME"
    fi
done

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session state checks passed.'
