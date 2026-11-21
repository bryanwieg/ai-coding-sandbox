# shellcheck shell=bash
# Shell functions for the sandbox, for bash and zsh. Add them to your shell
# with the repository's install.sh, which downloads this file, or from a
# checkout with bin/install-shell-functions, then work from a project root:
#
#   sandbox-init [--reference PATH]   create .sandbox/ for this project
#   sandbox [SERVICE [ARGS...]]       start a session (default: claude); at a
#                                     Git repository's root without .sandbox/,
#                                     runs sandbox-init and stages it first
#   sandbox codex                     ... or Codex
#   sandbox claude bash               ... or a shell in a Claude session
#   sandbox-trust                     review and approve the egress policy
#   sandbox-unlock                    unlock SSH keys for SSH sessions
#   sandbox-stop                      stop this project's sessions and services
#   sandbox-status                    show this project's session group status
#   sandbox-prune                     remove sandbox images a release replaced
#
# Variables set in the shell override .sandbox/env for one launch, for
# example: SANDBOX_PUBLISH_PORTS=3000 sandbox

sandbox() {
    case "${1:-}" in
        -h|--help)
            cat <<'HELP'
Usage: sandbox [SERVICE [ARGS...]]

Run from the project root. The default service is claude. At the root of a
Git repository without .sandbox/env, sandbox runs sandbox-init first and stages
the new .sandbox/ folder (env and agent.env stay ignored).

Commands:
  sandbox                         Approve egress, unlock SSH if enabled, start Claude
  sandbox codex                   Approve egress, unlock SSH if enabled, start Codex
  sandbox claude bash             Open a shell in a Claude session
  sandbox-init [--reference PATH] [--force]
                                  Create this project's .sandbox/ configuration
    --reference PATH              Optional host folder, read-only at /reference;
                                  omitted by default (project only)
    --force                       Replace .sandbox/env; keep other config files
  sandbox-trust                   Review and approve the project's egress policy;
                                  a running session picks it up at once
  sandbox-unlock                  Unlock SSH keys for this project's running session group, or for one started within two minutes
  sandbox-stop                    Stop this project's sessions and services
  sandbox-status                  Show this project's session group status
  sandbox-prune                   Remove sandbox images a newer release replaced;
                                  runs after every Claude or Codex session
  sandbox -h, --help              Show this help without starting Docker

Example (run on your machine):
  cd ~/projects/my-repo
  sandbox-init --reference ~/projects
  sandbox codex

Settings are stored in .sandbox/env. Shell variables override them for one launch:
  SANDBOX_PUBLISH_PORTS=3000 sandbox codex

Arguments after SERVICE are passed to that service, e.g. sandbox codex --help.
For Docker Compose run options: docker compose run --help
HELP
            return 0
            ;;
    esac
    if [ ! -f .sandbox/env ]; then
        # At the root of a Git work tree, create the configuration and stage
        # it; .sandbox/.gitignore keeps env and agent.env out of the index.
        if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != true ] ||
            [ -n "$(git rev-parse --show-prefix 2>/dev/null)" ]; then
            echo 'sandbox: no .sandbox/env here; start from the project root, or run sandbox-init first.' >&2
            return 1
        fi
        echo 'sandbox: no .sandbox/env in this repository; creating it with sandbox-init.' >&2
        # Default settings, no reference folder; sandbox's arguments are for
        # the service.
        # shellcheck disable=SC2119
        sandbox-init || return
        if [ ! -f .sandbox/env ]; then
            echo 'sandbox: sandbox-init did not create .sandbox/env.' >&2
            return 1
        fi
        git add -- .sandbox || return
        echo 'sandbox: staged .sandbox/ in Git; commit it to share the egress policy and SSH settings.' >&2
    fi
    if [ "$#" -eq 0 ]; then
        set -- claude
    fi
    local sandbox_status=0
    case "$1" in
        claude|codex)
            local sandbox_services sandbox_ssh=0 sandbox_group_needs_unlock
            _sandbox_prepare_images "$1" || return
            _sandbox_wait_for_group || return
            sandbox_services=$(docker compose --env-file .sandbox/env config --services) || return
            docker compose --env-file .sandbox/env run --rm -T trust --yes || return
            _sandbox_update_proxy || return
            if printf '%s\n' "$sandbox_services" | grep -Fxq ssh-agent; then
                sandbox_ssh=1
                docker compose --env-file .sandbox/env run --rm ssh-unlock --if-needed || return
            fi
            _sandbox_wait_for_group || return
            if [ "$sandbox_group_needs_unlock" = 1 ] && [ "$sandbox_ssh" = 1 ]; then
                docker compose --env-file .sandbox/env run --rm ssh-unlock --if-needed || return
            fi

            local sandbox_shell sandbox_client sandbox_marker
            if [ -n "${ZSH_VERSION:-}" ]; then
                zmodload zsh/system || return
                # shellcheck disable=SC2154 # zsh/system provides sysparams.
                sandbox_shell=${sysparams[pid]}
            else
                sandbox_shell=$BASHPID
            fi
            sandbox_client=$sandbox_shell.$(date +%s).${RANDOM}
            sandbox_marker=${TMPDIR:-/tmp}/ai-coding-sandbox-watch.$sandbox_client
            (set -C; : > "$sandbox_marker") || return 1
            (
                # exec gives Compose this foreground subshell's PID and terminal.
                local sandbox_compose_pid
                if [ -n "${ZSH_VERSION:-}" ]; then
                    sandbox_compose_pid=${sysparams[pid]}
                else
                    sandbox_compose_pid=$BASHPID
                fi
                _sandbox_watch "$sandbox_shell" "$sandbox_compose_pid" "$sandbox_marker" "$sandbox_client" || exit 1
                if [ "$#" -eq 1 ]; then export HERDR_AGENT="${HERDR_AGENT-$1}"; fi
                exec docker compose --env-file .sandbox/env run --rm --pull never \
                    --label "ai-coding-sandbox.client=$sandbox_client" "$@"
            ) || sandbox_status=$?
            _sandbox_stop_client "$sandbox_client"
            rm -f "$sandbox_marker"
            sandbox-prune
            ;;
        *)
            docker compose --env-file .sandbox/env run --rm "$@" || sandbox_status=$?
            ;;
    esac
    return "$sandbox_status"
}

# Pull and build before anything starts the broker's startup window.
_sandbox_prepare_images() {
    local sandbox_output sandbox_result
    if sandbox_output=$(docker compose --env-file .sandbox/env pull --quiet --policy missing --include-deps --ignore-buildable "$1" 2>&1) &&
        sandbox_output=$(docker compose --env-file .sandbox/env build --quiet --with-dependencies "$1" 2>&1); then
        return 0
    else
        sandbox_result=$?
        printf '%s\n' "$sandbox_output" >&2
        return "$sandbox_result"
    fi
}

# On launch, wait only for a group that is winding down. An explicit stop
# has already asked the broker to drain, so it waits for the whole group.
_sandbox_wait_for_group() {
    local sandbox_reason=${1:-launch} sandbox_reply sandbox_ids sandbox_names sandbox_poll=1
    if [ "$sandbox_reason" = launch ]; then
        # Only a group that is still joinable can reuse the first unlock.
        sandbox_group_needs_unlock=1
        sandbox_reply=$(docker compose --env-file .sandbox/env exec -T lifecycle sandbox-lifecycle status 2>/dev/null) || return 0
        if grep -Fxq 'joinable=yes' <<< "$sandbox_reply"; then
            sandbox_group_needs_unlock=0
            return 0
        fi
        echo "sandbox: waiting for this project's previous session group to stop, so this launch starts with the current settings." >&2
    fi
    set -- lifecycle egress-proxy docker publish ssh-agent
    while :; do
        sandbox_ids=$(docker compose --env-file .sandbox/env ps -q --status running "$@") || return 1
        [ -n "$sandbox_ids" ] || return 0
        if [ "$sandbox_reason" = launch ] &&
            sandbox_reply=$(docker compose --env-file .sandbox/env exec -T lifecycle sandbox-lifecycle status 2>/dev/null) &&
            grep -Fxq 'joinable=yes' <<< "$sandbox_reply"; then
            return 0
        fi
        [ "$sandbox_poll" -lt 40 ] || break
        sleep 1 || return 1
        sandbox_poll=$((sandbox_poll + 1))
    done
    sandbox_names=$(docker compose --env-file .sandbox/env ps --format '{{.Service}}' --status running "$@") || return 1
    printf "sandbox: forcing the previous session group's stuck containers to stop: %s\n" "${sandbox_names//$'\n'/ }" >&2
    xargs -n 1 docker rm -f <<< "$sandbox_ids" >/dev/null || return 1
}

# Stops and removes the session containers a launch labeled with CLIENT, such
# as one whose docker compose client was killed. --rm leaves none otherwise.
_sandbox_stop_client() {
    local sandbox_containers sandbox_id
    sandbox_containers=$(docker ps -aq --filter "label=ai-coding-sandbox.client=$1" 2>/dev/null) || return 0
    [ -n "$sandbox_containers" ] || return 0
    echo 'sandbox: stopping the session container its client left behind.' >&2
    while IFS= read -r sandbox_id; do
        docker stop -t 15 "$sandbox_id" >/dev/null 2>&1 || :
        docker rm -f "$sandbox_id" >/dev/null 2>&1 || :
    done <<< "$sandbox_containers"
}

# Watches this shell from a detached process while a launch runs. If the
# shell exits without ending the launch, as when its terminal or SSH
# connection closes, the watcher stops and removes the launch's containers.
# The launch ends the watcher by removing its marker file.
_sandbox_watch() {
    # A subshell keeps the watcher out of the shell's job table, and nohup
    # keeps it running when the terminal hangs up.
    # shellcheck disable=SC2016 # the watcher expands its own arguments
    (nohup sh -c '
        shell=$1 client=$2 marker=$3 label=$4
        while [ -e "$marker" ]; do
            if ! kill -0 "$shell" 2>/dev/null; then
                # Check before listing so a client exiting during the lookup
                # gets a final lookup after it can no longer create a container.
                starting=false
                if kill -0 "$client" 2>/dev/null; then starting=true; fi
                containers=$(docker ps -aq --filter "label=$label") || containers=
                if [ -n "$containers" ]; then
                    docker stop -t 15 $containers >/dev/null 2>&1
                    docker rm -f $containers >/dev/null 2>&1
                elif "$starting"; then
                    sleep 2
                    continue
                fi
                rm -f "$marker"
                exit 0
            fi
            sleep 2
        done
    ' sandbox-watch "$1" "$2" "$3" "ai-coding-sandbox.client=$4" \
        </dev/null >/dev/null 2>&1 &)
}

# Drain the group, then remove the project's remaining containers, including
# one-off runs. Compose down keeps the volumes.
sandbox-stop() {
    if [ ! -f .sandbox/env ]; then
        echo 'sandbox-stop: no .sandbox/env here; start from the project root, or run sandbox-init first.' >&2
        return 1
    fi
    local sandbox_ids
    if docker compose --env-file .sandbox/env exec -T lifecycle sandbox-lifecycle stop >/dev/null 2>&1; then
        _sandbox_wait_for_group stop || :
    fi
    if sandbox_ids=$(docker compose --env-file .sandbox/env --profile '*' ps -a -q) && [ -n "$sandbox_ids" ]; then
        xargs -n 1 docker rm -f <<< "$sandbox_ids" >/dev/null || :
    fi
    docker compose --env-file .sandbox/env --profile '*' down --remove-orphans
}

sandbox-status() {
    if [ ! -f .sandbox/env ]; then
        echo 'sandbox-status: no .sandbox/env here; start from the project root, or run sandbox-init first.' >&2
        return 1
    fi
    docker compose --env-file .sandbox/env exec -T lifecycle sandbox-lifecycle status 2>/dev/null ||
        echo 'sandbox-status: no session group is running for this project.'
}

# Runs sandbox-init-config from the dedicated init image, offline, writing into the
# current folder. SANDBOX_INIT_IMAGE selects another image.
# shellcheck disable=SC2120 # users pass the arguments
sandbox-init() {
    docker run --rm --pull=always -it --network none --read-only --tmpfs /tmp \
        --cap-drop ALL --security-opt no-new-privileges \
        --user "$(id -u):$(id -g)" -v "$PWD:/project" -e HOST_PWD="$PWD" \
        "${SANDBOX_INIT_IMAGE:-ghcr.io/bryanwieg/ai-coding-sandbox:init-latest}" \
        sandbox-init-config "$@"
}

# Approves the policy and applies it to this project's running proxy, so a
# session in progress gets the change without restarting.
sandbox-trust() {
    if [ ! -f .sandbox/env ]; then
        echo 'sandbox-trust: no .sandbox/env here; start from the project root, or run sandbox-init first.' >&2
        return 1
    fi
    docker compose --env-file .sandbox/env run --rm trust || return
    _sandbox_update_proxy
}

# A running proxy keeps the policy it loaded; when that differs from the
# approved one, reload it in place, keeping its connections. A proxy that
# cannot reload or does not report its policy (an older image) is restarted.
_sandbox_update_proxy() {
    local sandbox_applied sandbox_wanted
    sandbox_applied=$(docker compose --env-file .sandbox/env exec -T egress-proxy \
        sh -c 'cat /tmp/applied-policy 2>/dev/null || echo unknown' 2>/dev/null) || return 0
    # --pull never: the trust run just before obtained the image. Captured
    # output has no terminal, and a dev overlay's rebuild here would fail
    # trying to draw build progress ("failed to get console").
    sandbox_wanted=$(docker compose --env-file .sandbox/env run --pull never --rm -T \
        --entrypoint sandbox-policy trust hash /etc/squid/project-policy.yaml) || return
    [ "$sandbox_applied" != "$sandbox_wanted" ] || return 0
    echo 'sandbox: reloading the running egress proxy with the approved policy.' >&2
    docker compose --env-file .sandbox/env exec -T egress-proxy sandbox-proxy-config --reload && return 0
    echo 'sandbox: the egress proxy could not reload; restarting it. Other sessions of this project briefly lose their connections.' >&2
    docker compose --env-file .sandbox/env restart egress-proxy
}

sandbox-unlock() {
    sandbox ssh-unlock
}

# Each release pins its images by digest, so an update leaves the previous
# ones behind untagged. Removes the released repository's untagged images
# that neither this project's Compose file nor any container, running or
# stopped, uses; a stopped container's image goes once Compose replaces it.
# Projects on other images, such as a development checkout, are skipped, so
# released images in use elsewhere stay. Never fails the caller.
sandbox-prune() {
    local sandbox_repository=ghcr.io/bryanwieg/ai-coding-sandbox
    local sandbox_wanted sandbox_keep sandbox_containers sandbox_candidates
    local sandbox_id sandbox_tag sandbox_digest sandbox_removed=0
    [ -f .sandbox/env ] || return 0
    sandbox_wanted=$(docker compose --env-file .sandbox/env config --images 2>/dev/null) || return 0
    [ -n "$sandbox_wanted" ] || return 0
    if printf '%s\n' "$sandbox_wanted" | grep -Fvq "$sandbox_repository@sha256:"; then
        return 0
    fi
    sandbox_keep=$(printf '%s\n' "$sandbox_wanted" |
        xargs docker image inspect --format '{{.Id}}' 2>/dev/null) || :
    sandbox_containers=$(docker ps -aq 2>/dev/null) || return 0
    if [ -n "$sandbox_containers" ]; then
        sandbox_keep=$sandbox_keep$(printf '\n'; printf '%s\n' "$sandbox_containers" |
            xargs docker inspect --format '{{.Image}}' 2>/dev/null) || return 0
    fi
    sandbox_candidates=$(docker image ls --no-trunc --digests \
        --format '{{.ID}} {{.Tag}} {{.Digest}}' "$sandbox_repository" 2>/dev/null) || return 0
    while read -r sandbox_id sandbox_tag sandbox_digest; do
        [ -n "$sandbox_id" ] && [ "$sandbox_tag" = '<none>' ] || continue
        case "$sandbox_digest" in sha256:*) ;; *) continue ;; esac
        ! printf '%s\n' "$sandbox_keep" | grep -Fxq "$sandbox_id" || continue
        docker image rm "$sandbox_repository@$sandbox_digest" >/dev/null 2>&1 &&
            sandbox_removed=$((sandbox_removed + 1))
    done <<EOF
$sandbox_candidates
EOF
    if [ "$sandbox_removed" -gt 0 ]; then
        echo "sandbox: removed $sandbox_removed superseded sandbox images." >&2
    fi
    return 0
}
