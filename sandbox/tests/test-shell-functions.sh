#!/bin/sh
# The sandbox shell functions and their installer: the installer adds one
# source line once; the functions refuse a folder without .sandbox/env and
# pass the right docker commands, in bash and, when installed, zsh; and a
# running proxy, at launch or after sandbox-trust, is reloaded only when its
# policy differs from the approved one, and restarted when it cannot reload;
# and a launch holds the running proxy and, with Docker, the daemon up; and
# an agent session ends by removing only the released images nothing uses;
# and at a Git repository's root without .sandbox/env, sandbox initializes
# and stages it before launching, but nowhere else.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install="$root_dir/bin/install-shell-functions"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# The installer appends one line, once, and picks the rc file from $SHELL.
rc=$test_dir/rc
printf '# existing\n' > "$rc"
"$install" "$rc" >/dev/null
"$install" "$rc" | grep -Fq 'already in'
[ "$(grep -c '^\. ".*/shell/sandbox.sh"$' "$rc")" -eq 1 ]
grep -Fxq '# existing' "$rc"
HOME=$test_dir SHELL=/bin/bash "$install" >/dev/null
grep -Fq shell/sandbox.sh "$test_dir/.bashrc"
mkdir -p "$test_dir/z"
HOME=$test_dir SHELL=/usr/bin/zsh ZDOTDIR=$test_dir/z "$install" >/dev/null
grep -Fq shell/sandbox.sh "$test_dir/z/.zshrc"
if HOME=$test_dir SHELL=/bin/fish "$install" 2>"$test_dir/err"; then exit 1; fi
grep -Fq 'unsupported shell' "$test_dir/err"

# A stub docker prints its arguments, one per line.
mkdir -p "$test_dir/bin" "$test_dir/project/.sandbox" "$test_dir/empty"
cat > "$test_dir/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
    'compose --env-file .sandbox/env config --services')
        [ "${SANDBOX_TEST_FAIL:-}" != config ] || exit 41
        printf 'claude\ncodex\n'
        [ "${SANDBOX_TEST_SSH:-}" != 1 ] || printf 'ssh-agent\nssh-unlock\n'
        [ "${SANDBOX_TEST_DOCKER:-}" != 1 ] || printf 'docker\n'
        exit 0
        ;;
    'compose --env-file .sandbox/env exec -T '*' touch /tmp/launch-hold')
        # Holds go to a log; a stopped service (SANDBOX_TEST_FAIL=hold) fails.
        printf '%s\n' "$6" >> "$SANDBOX_TEST_HOLDS"
        [ "${SANDBOX_TEST_FAIL:-}" != hold ] || exit 47
        exit 0
        ;;
    'compose --env-file .sandbox/env exec -T egress-proxy sandbox-proxy-config --reload')
        printf '%s\n' "$@"
        [ "${SANDBOX_TEST_FAIL:-}" != reload ] && [ "${SANDBOX_TEST_FAIL:-}" != restart ] || exit 46
        exit 0
        ;;
    'compose --env-file .sandbox/env exec -T egress-proxy '*)
        # SANDBOX_TEST_APPLIED, when set, is the running proxy's policy hash.
        [ -n "${SANDBOX_TEST_APPLIED+set}" ] || exit 1
        printf '%s\n' "$SANDBOX_TEST_APPLIED"
        exit 0
        ;;
    'compose --env-file .sandbox/env config --images')
        # SANDBOX_TEST_IMAGES, when set, is the project's image list.
        [ -z "${SANDBOX_TEST_IMAGES:-}" ] || printf '%s\n' $SANDBOX_TEST_IMAGES
        exit 0
        ;;
    'image inspect --format {{.Id}} '*)
        shift 3
        for ref in "$@"; do case "$ref" in *@*) printf '%s\n' "${ref#*@}" ;; esac; done
        exit 0
        ;;
    'ps -aq') printf 'c1\n'; exit 0 ;;
    'inspect --format {{.Image}} c1') printf 'sha256:bbb\n'; exit 0 ;;
    'image ls --no-trunc --digests '*' ghcr.io/bryanwieg/ai-coding-sandbox')
        printf '%s\n' 'sha256:aaa <none> sha256:aaa' 'sha256:bbb <none> sha256:bbb' \
            'sha256:ccc <none> sha256:ccc' 'sha256:ddd claude-latest sha256:ddd'
        exit 0
        ;;
    'run --rm --pull=always '*' sandbox-init-config')
        # SANDBOX_TEST_INIT=1 writes what sandbox-init-config would.
        printf '%s\n' "$@"
        [ "${SANDBOX_TEST_INIT:-}" = 1 ] || exit 0
        [ "${SANDBOX_TEST_FAIL:-}" != init ] || exit 49
        mkdir -p .sandbox
        printf 'env\nagent.env\n' > .sandbox/.gitignore
        : > .sandbox/env
        : > .sandbox/agent.env
        : > .sandbox/egress-policy.yaml
        exit 0
        ;;
    'image rm '*) printf '%s\n' "$3" >> "$SANDBOX_TEST_REMOVED"; exit 0 ;;
    *' --entrypoint sandbox-policy trust hash /etc/squid/project-policy.yaml')
        [ "${SANDBOX_TEST_FAIL:-}" != hash ] || exit 44
        printf '%s\n' "${SANDBOX_TEST_WANTED:-}"
        exit 0
        ;;
esac
for argument in "$@"; do printf '%s\n' "$argument"; done
case "$*" in
    *' trust --yes'|*' --rm trust') [ "${SANDBOX_TEST_FAIL:-}" != trust ] || exit 42 ;;
    *' ssh-unlock --if-needed') [ "${SANDBOX_TEST_FAIL:-}" != unlock ] || exit 43 ;;
    *' restart egress-proxy') [ "${SANDBOX_TEST_FAIL:-}" != restart ] || exit 45 ;;
    *' --rm claude') [ "${SANDBOX_TEST_FAIL:-}" != launch ] || exit 48 ;;
esac
STUB
chmod 0755 "$test_dir/bin/docker"
: > "$test_dir/project/.sandbox/env"

for shell in bash zsh; do
    command -v "$shell" >/dev/null || { echo "skipping $shell: not installed"; continue; }
    run() {
        (cd "$1" && PATH="$test_dir/bin:$PATH" "$shell" -c ". \"$rc\"; $2")
    }
    for option in -h --help; do
        output=$(run "$test_dir/empty" "sandbox $option")
        printf '%s\n' "$output" | grep -Fxq 'Usage: sandbox [SERVICE [ARGS...]]'
        printf '%s\n' "$output" | grep -Fq -- '--reference PATH'
        if printf '%s\n' "$output" | grep -Eq '^(compose|run)$'; then
            echo "sandbox help invoked Docker in $shell" >&2
            exit 1
        fi
    done
    if run "$test_dir/empty" sandbox 2>"$test_dir/err"; then exit 1; fi
    grep -Fq 'no .sandbox/env here' "$test_dir/err"
    holds=$test_dir/holds
    export SANDBOX_TEST_HOLDS="$holds"
    : > "$holds"
    run "$test_dir/project" 'sandbox claude bash' >/dev/null
    [ "$(tr '\n' ' ' < "$holds")" = 'egress-proxy ' ]
    : > "$holds"
    run "$test_dir/project" 'SANDBOX_TEST_DOCKER=1 sandbox' >/dev/null
    [ "$(tr '\n' ' ' < "$holds")" = 'egress-proxy docker ' ]
    : > "$holds"
    run "$test_dir/project" 'SANDBOX_TEST_DOCKER=1 SANDBOX_TEST_FAIL=hold sandbox' | grep -Fxq claude
    : > "$holds"
    run "$test_dir/project" 'sandbox trust' >/dev/null
    [ ! -s "$holds" ]
    trust='compose --env-file .sandbox/env run --rm -T trust --yes '
    unlock='compose --env-file .sandbox/env run --rm ssh-unlock --if-needed '
    launch='compose --env-file .sandbox/env run --rm '
    reload='compose --env-file .sandbox/env exec -T egress-proxy sandbox-proxy-config --reload '
    restart='compose --env-file .sandbox/env restart egress-proxy '
    [ "$(run "$test_dir/project" sandbox | tr '\n' ' ')" = "${trust}${launch}claude " ]
    [ "$(run "$test_dir/project" 'sandbox claude bash' | tr '\n' ' ')" = "${trust}${launch}claude bash " ]
    [ "$(run "$test_dir/project" 'sandbox codex --help' | tr '\n' ' ')" = "${trust}${launch}codex --help " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_SSH=1 sandbox codex' | tr '\n' ' ')" = "${trust}${unlock}${launch}codex " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=abc SANDBOX_TEST_WANTED=abc sandbox' | tr '\n' ' ')" = "${trust}${launch}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED= SANDBOX_TEST_WANTED= sandbox' | tr '\n' ' ')" = "${trust}${launch}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new sandbox codex' 2>"$test_dir/err" | tr '\n' ' ')" = "${trust}${reload}${launch}codex " ]
    grep -Fq 'reloading the running egress proxy' "$test_dir/err"
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=unknown SANDBOX_TEST_WANTED= sandbox' 2>/dev/null | tr '\n' ' ')" = "${trust}${reload}${launch}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new SANDBOX_TEST_FAIL=reload sandbox' 2>"$test_dir/err" | tr '\n' ' ')" = "${trust}${reload}${restart}${launch}claude " ]
    grep -Fq 'could not reload; restarting' "$test_dir/err"
    for failure in hash restart; do
        result=0
        run "$test_dir/project" "SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new SANDBOX_TEST_FAIL=$failure sandbox codex" > "$test_dir/output" 2>/dev/null || result=$?
        case "$failure:$result" in hash:44|restart:45) ;; *) exit 1 ;; esac
        if grep -Fxq codex "$test_dir/output"; then
            echo "sandbox launched after $failure failed in $shell" >&2
            exit 1
        fi
    done
    for failure in config trust unlock; do
        result=0
        run "$test_dir/project" "SANDBOX_TEST_SSH=1 SANDBOX_TEST_FAIL=$failure sandbox codex" > "$test_dir/output" || result=$?
        case "$failure:$result" in config:41|trust:42|unlock:43) ;; *) exit 1 ;; esac
        if grep -Fxq codex "$test_dir/output"; then
            echo "sandbox launched after $failure failed in $shell" >&2
            exit 1
        fi
    done
    [ "$(run "$test_dir/project" sandbox-trust | tr '\n' ' ')" = "${launch}trust " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=abc SANDBOX_TEST_WANTED=abc sandbox-trust' | tr '\n' ' ')" = "${launch}trust " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new sandbox-trust' 2>/dev/null | tr '\n' ' ')" = "${launch}trust ${reload}" ]
    if run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new SANDBOX_TEST_FAIL=trust sandbox-trust' > "$test_dir/output" 2>&1; then exit 1; fi
    if grep -Fxq -- --reload "$test_dir/output"; then
        echo "sandbox-trust reloaded the proxy after a failed approval in $shell" >&2
        exit 1
    fi
    if run "$test_dir/empty" sandbox-trust 2>"$test_dir/err"; then exit 1; fi
    grep -Fq 'no .sandbox/env here' "$test_dir/err"
    [ "$(run "$test_dir/project" sandbox-unlock | tr '\n' ' ')" = "${launch}ssh-unlock " ]
    # After an agent session, even a failed one, untagged released images
    # that neither the project nor a container uses go; tagged ones stay.
    removed=$test_dir/removed
    export SANDBOX_TEST_REMOVED="$removed"
    released='ghcr.io/bryanwieg/ai-coding-sandbox@sha256:aaa ghcr.io/bryanwieg/ai-coding-sandbox@sha256:eee'
    : > "$removed"
    run "$test_dir/project" "SANDBOX_TEST_IMAGES='$released' sandbox" >/dev/null 2>"$test_dir/err"
    [ "$(tr '\n' ' ' < "$removed")" = 'ghcr.io/bryanwieg/ai-coding-sandbox@sha256:ccc ' ]
    grep -Fq 'removed 1 superseded sandbox images' "$test_dir/err"
    : > "$removed"
    result=0
    run "$test_dir/project" "SANDBOX_TEST_IMAGES='$released' SANDBOX_TEST_FAIL=launch sandbox" >/dev/null 2>&1 || result=$?
    [ "$result" -eq 48 ] && [ -s "$removed" ]
    : > "$removed"
    run "$test_dir/project" "SANDBOX_TEST_IMAGES='$released' sandbox trust" >/dev/null
    run "$test_dir/project" "SANDBOX_TEST_IMAGES='$released ai-coding-sandbox-dev:claude' sandbox-prune" >/dev/null
    run "$test_dir/empty" "SANDBOX_TEST_IMAGES='$released' sandbox-prune" >/dev/null
    [ ! -s "$removed" ]
    # Only a Git repository's root without .sandbox/env is initialized and
    # staged; a failed init launches nothing.
    rm -rf "$test_dir/repo"
    mkdir -p "$test_dir/repo/sub"
    git init -q "$test_dir/repo"
    if run "$test_dir/repo/sub" 'SANDBOX_TEST_INIT=1 sandbox' > "$test_dir/output" 2>"$test_dir/err"; then exit 1; fi
    grep -Fq 'no .sandbox/env here' "$test_dir/err"
    [ ! -e "$test_dir/repo/.sandbox" ] && [ ! -e "$test_dir/repo/sub/.sandbox" ]
    result=0
    run "$test_dir/repo" 'SANDBOX_TEST_INIT=1 SANDBOX_TEST_FAIL=init sandbox' > "$test_dir/output" 2>/dev/null || result=$?
    [ "$result" -eq 49 ] && ! grep -Fxq claude "$test_dir/output"
    [ -z "$(git -C "$test_dir/repo" diff --cached --name-only)" ]
    run "$test_dir/repo" 'SANDBOX_TEST_INIT=1 sandbox' > "$test_dir/output" 2>"$test_dir/err"
    grep -Fxq sandbox-init-config "$test_dir/output"
    tail -n 1 "$test_dir/output" | grep -Fxq claude
    grep -Fq 'staged .sandbox/' "$test_dir/err"
    [ "$(git -C "$test_dir/repo" diff --cached --name-only | tr '\n' ' ')" = '.sandbox/.gitignore .sandbox/egress-policy.yaml ' ]
    if run "$test_dir/empty" 'SANDBOX_TEST_INIT=1 sandbox' 2>/dev/null; then exit 1; fi
    [ ! -e "$test_dir/empty/.sandbox" ]
    output=$(run "$test_dir/project" 'sandbox-init --reference /ref' | tr '\n' ' ')
    case "$output" in
        "run --rm --pull=always -it --network none --read-only "*" --cap-drop ALL "*" -v $test_dir/project:/project -e HOST_PWD=$test_dir/project ghcr.io/bryanwieg/ai-coding-sandbox:init-latest sandbox-init-config --reference /ref ") ;;
        *) echo "sandbox-init in $shell: $output" >&2; exit 1 ;;
    esac
    output=$(run "$test_dir/project" 'SANDBOX_INIT_IMAGE=local-init:test sandbox-init --force' | tr '\n' ' ')
    case "$output" in
        "run --rm --pull=always "*" local-init:test sandbox-init-config --force ") ;;
        *) echo "sandbox-init override in $shell: $output" >&2; exit 1 ;;
    esac
done

echo 'Shell function tests passed.'
