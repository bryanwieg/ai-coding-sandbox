#!/bin/sh
# The default shell is bash, zsh is not installed, and interactive history
# lands in /tmp with the session's read-only home, including for the runtime
# UID supplied by the entrypoint.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
hostname=$(env SANDBOX_UID=1000 SANDBOX_GID=1000 SANDBOX_REFERENCE=/tmp \
    docker compose -f "$sandbox_dir/compose.session.yaml" --profile '*' config --format json |
    jq -er '.services | [.claude.hostname, .codex.hostname] | unique |
        if . == ["sandbox"] then .[0] else error("agent hostnames must be sandbox") end')

if [ "$#" -eq 0 ]; then
    set -- ai-coding-sandbox-dev:claude ai-coding-sandbox-dev:codex
fi

for image do
    for user in 1000:1000 7777:7777; do
        docker run --rm -i --network none --read-only --user "$user" --hostname "$hostname" \
            --cap-drop ALL --security-opt no-new-privileges:true \
            --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
            "$image" sh -s <<'EOF'
set -eu
test ! -w "$HOME"
test "$(hostname)" = sandbox
test "$SHELL" = /bin/bash
test "$(getent passwd "$(id -u)" | cut -d: -f7)" = /bin/bash
test "$(awk -F: -v user="$SANDBOX_USER" '$1 == user { print $7; exit }' /etc/passwd)" = /bin/bash
if command -v zsh >/dev/null; then echo 'zsh is still installed' >&2; exit 1; fi
test ! -e /usr/local/share/oh-my-zsh
echo 'ok   default shell is bash, zsh is absent and hostname is sandbox'
test "$HISTFILE" = /tmp/.bash_history
bash -c 'set -o history; history -s probe; history -w' </dev/null
grep -qx probe /tmp/.bash_history
echo 'ok   interactive bash keeps its history in /tmp'
EOF
    done
done
