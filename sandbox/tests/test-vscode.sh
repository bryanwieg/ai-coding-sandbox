#!/bin/sh
# Run against both agent images built with compose.dev.yaml, or image tags
# supplied as arguments. VS Code's Dev Containers attach installs its server
# under ~/.vscode-server and its helpers under ~/.vscode-remote-containers;
# both must land, executable, in the project's cache volume while the home
# stays read-only. /tmp is noexec as in a session; a tmpfs with exec stands in
# for the cache volume at /cache.
set -eu

if [ "$#" -eq 0 ]; then
    set -- ai-coding-sandbox-dev:claude ai-coding-sandbox-dev:codex
fi

for image do
    docker run --rm -i --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges:true \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        --tmpfs /cache:rw,exec,nosuid,nodev,mode=1777 \
        "$image" sh -s <<'EOF'
set -eu
test "$(id -u)" -ne 0
test ! -w "$HOME"
test "$(readlink "$HOME/.vscode-server")" = /cache/vscode/server
test "$(readlink "$HOME/.vscode-remote-containers")" = /cache/vscode/remote-containers
/usr/local/libexec/sandbox/init.d/06-vscode
# Attach creates nested folders through the links and runs the server there.
mkdir -p "$HOME/.vscode-server/bin/commit" "$HOME/.vscode-remote-containers/dist"
cp /bin/true "$HOME/.vscode-server/bin/commit/server"
"$HOME/.vscode-server/bin/commit/server"
test -x /cache/vscode/server/bin/commit/server
test -d /cache/vscode/remote-containers/dist
printf 'ok   VS Code attach folders resolve into /cache and run as %s\n' "$(id -u)"
EOF
    # Outside a session there is no cache volume, and the hook does nothing.
    docker run --rm --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        "$image" /usr/local/libexec/sandbox/init.d/06-vscode
    agent=$(docker image inspect --format '{{index .Config.Labels "sandbox.agent"}}' "$image")
    # docker exec, as attach uses, skips the entrypoint and its NSS records.
    docker run --rm -i --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true --user 7777:7777 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        --entrypoint sh -e AGENT="$agent" "$image" -s <<'EOF'
set -eu
test "$(getent passwd 7777 | cut -d: -f1,6)" = "$AGENT:/home/$AGENT"
test "$(getent group 7777 | cut -d: -f1)" = "$AGENT"
test "$(id -un)" = "$AGENT"
ssh -G example.com </dev/null >/dev/null
test ! -w /etc/passwd
printf 'ok   UID 7777 resolves to /home/%s without the entrypoint\n' "$AGENT"
EOF
    # Sessions keep the entrypoint's single record for the runtime UID.
    test "$(docker run --rm --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true --user 7777:7777 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        "$image" sh -c "getent passwd $agent | wc -l; getent passwd $agent | cut -d: -f3")" = "1
7777"
done
