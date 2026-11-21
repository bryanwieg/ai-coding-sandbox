#!/bin/sh
# The sandbox shell functions and their installer: the installer adds one
# source line once; the functions refuse a folder without .sandbox/env and
# pass the right docker commands, in bash and, when installed, zsh; and a
# running proxy, at launch or after sandbox-trust, is reloaded only when its
# policy differs from the approved one, and restarted when it cannot reload;
# and launches wait for stopping groups and clean up orphaned sessions;
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
log=$SANDBOX_TEST_LOG
printf '%s\n' "$*" >> "$log"
# Hold Compose during startup, or its first stop during cleanup, so the
# test can kill the launcher at that point. The watcher releases the stub.
case "${SANDBOX_TEST_INTERRUPT:-}:$*" in
    startup:*' --label '*|cleanup:'stop -t 15 c7')
        if [ "$(grep -Fxc "$*" "$log")" = 1 ]; then
            for _ in $(seq 100); do
                grep -Fxq 'rm -f c7' "$log" && exit 0
                sleep 0.1
            done
            exit 52
        fi
        ;;
esac
case "$*" in
    *' pull --quiet --policy missing --include-deps --ignore-buildable '*|*' build --quiet --with-dependencies '*)
        echo "preparing image on stdout"
        echo "preparing image on stderr" >&2
        [ "${SANDBOX_TEST_FAIL:-}" != "$4" ] || exit 50
        exit 0
        ;;
    *' exec -T lifecycle sandbox-lifecycle status')
        # One scripted state per status call, then the default state.
        state=$(sed -n "$(grep -Fxc "$*" "$log")p" "$SANDBOX_TEST_STATES")
        case "${state:-${SANDBOX_TEST_STATE:-absent}}" in
            active) printf 'state=active\njoinable=yes\nremaining=0\nagents=claude\nservices=docker\n' ;;
            idle) printf 'state=idle\njoinable=no\nremaining=2\nagents=\nservices=docker\n' ;;
            absent) exit 1 ;;
        esac
        exit 0
        ;;
    *' exec -T lifecycle sandbox-lifecycle stop') [ "${SANDBOX_TEST_STATE:-absent}" != absent ]; exit $? ;;
    *' ps -q --status running lifecycle egress-proxy docker publish ssh-agent')
        if [ "$(grep -Fxc "$*" "$log")" -le "${SANDBOX_TEST_RUNNING:-0}" ]; then printf 'c1\nc2\n'; fi
        exit 0
        ;;
    *" ps --format {{.Service}} --status running lifecycle egress-proxy docker publish ssh-agent")
        printf 'lifecycle\ndocker\n'; exit 0 ;;
    *' --profile * ps -a -q') printf 'one-off\nexited\n'; exit 0 ;;
    *' --profile * down --remove-orphans') [ "${SANDBOX_TEST_FAIL:-}" != down ]; exit $? ;;
    'ps -aq --filter label=ai-coding-sandbox.client='*)
        # The first orphan lookup during Compose startup sees no container.
        if [ "${SANDBOX_TEST_INTERRUPT:-}" = startup ] && [ "$(grep -Fxc "$*" "$log")" = 1 ]; then exit 0; fi
        printf '%s\n' "${SANDBOX_TEST_LEFT:-}"
        exit 0 ;;
    'stop -t 15 '*|'rm -f '*) [ "${SANDBOX_TEST_FAIL:-}" != remove ]; exit $? ;;
    'compose --env-file .sandbox/env config --services')
        [ "${SANDBOX_TEST_FAIL:-}" != config ] || exit 41
        printf 'claude\ncodex\n'
        [ "${SANDBOX_TEST_SSH:-}" != 1 ] || printf 'ssh-agent\nssh-unlock\n'
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
            'sha256:ccc <none> sha256:ccc' 'sha256:ddd agent-latest sha256:ddd'
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
if [ "${SANDBOX_TEST_HERDR:-}" = 1 ] && [ "${HERDR_AGENT+x}" = x ]; then
    printf 'HERDR_AGENT=%s\n' "$HERDR_AGENT"
fi
for argument in "$@"; do
    case "$argument" in
        ai-coding-sandbox.client=*)
            [ -f "$TMPDIR/ai-coding-sandbox-watch.${argument#*=}" ] || exit 51
            argument=ai-coding-sandbox.client=ID
            ;;
    esac
    printf '%s\n' "$argument"
done
case "$*" in
    *' trust --yes'|*' --rm trust') [ "${SANDBOX_TEST_FAIL:-}" != trust ] || exit 42 ;;
    *' ssh-unlock --if-needed') [ "${SANDBOX_TEST_FAIL:-}" != unlock ] || exit 43 ;;
    *' restart egress-proxy') [ "${SANDBOX_TEST_FAIL:-}" != restart ] || exit 45 ;;
    *' --rm --pull never --label '*' claude') [ "${SANDBOX_TEST_FAIL:-}" != launch ] || exit 48 ;;
esac
STUB
# Skip the one-second group poll delay. Keep the detached watcher's own delay.
cat > "$test_dir/bin/sleep" <<'STUB'
#!/bin/sh
[ "$1" = 1 ] || exec "$SANDBOX_TEST_SLEEP" "$@"
echo sleep >> "$SANDBOX_TEST_LOG"
STUB
SANDBOX_TEST_SLEEP=$(command -v sleep)
log=$test_dir/commands
states=$test_dir/states
mkdir "$test_dir/tmp"
export SANDBOX_TEST_SLEEP SANDBOX_TEST_LOG="$log" SANDBOX_TEST_STATES="$states" TMPDIR="$test_dir/tmp"
: > "$states"
chmod 0755 "$test_dir/bin/docker" "$test_dir/bin/sleep"
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
    trust='compose --env-file .sandbox/env run --rm -T trust --yes '
    unlock='compose --env-file .sandbox/env run --rm ssh-unlock --if-needed '
    launch='compose --env-file .sandbox/env run --rm '
    agent='--pull never --label ai-coding-sandbox.client=ID '
    reload='compose --env-file .sandbox/env exec -T egress-proxy sandbox-proxy-config --reload '
    restart='compose --env-file .sandbox/env restart egress-proxy '
    compose='compose --env-file .sandbox/env'
    status="$compose exec -T lifecycle sandbox-lifecycle status"
    stop="$compose exec -T lifecycle sandbox-lifecycle stop"
    poll="$compose ps -q --status running lifecycle egress-proxy docker publish ssh-agent"
    all="$compose --profile *"
    waiting="sandbox: waiting for this project's previous session group to stop, so this launch starts with the current settings."
    forcing="sandbox: forcing the previous session group's stuck containers to stop: lifecycle docker"

    # A launch prepares images silently, checks the group on both sides of
    # trust/unlock, and cleans up by the same label before pruning.
    for service in claude codex; do
        : > "$log"
        run "$test_dir/project" "SANDBOX_TEST_SSH=1 SANDBOX_TEST_STATE=active sandbox $service" > "$test_dir/output" 2>"$test_dir/err"
        [ ! -s "$test_dir/err" ]
        if grep -Fq 'preparing image' "$test_dir/output"; then exit 1; fi
        client=$(sed -n "s/^.* run --rm --pull never --label ai-coding-sandbox.client=\([0-9.]*\) $service\$/\1/p" "$log")
        printf '%s\n' "$client" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
        diff - "$log" <<EOF
$compose pull --quiet --policy missing --include-deps --ignore-buildable $service
$compose build --quiet --with-dependencies $service
$status
$compose config --services
${trust% }
$compose exec -T egress-proxy sh -c cat /tmp/applied-policy 2>/dev/null || echo unknown
${unlock% }
$status
${launch}--pull never --label ai-coding-sandbox.client=$client $service
ps -aq --filter label=ai-coding-sandbox.client=$client
$compose config --images
EOF
    done
    : > "$log"
    run "$test_dir/project" 'sandbox trust' >/dev/null
    [ "$(cat "$log")" = "${launch}trust" ]

    for failure in pull build; do
        : > "$log"
        result=0
        run "$test_dir/project" "SANDBOX_TEST_FAIL=$failure sandbox" > "$test_dir/output" 2>"$test_dir/err" || result=$?
        [ "$result" = 50 ]
        [ ! -s "$test_dir/output" ]
        grep -Fxq 'preparing image on stdout' "$test_dir/err"
        grep -Fxq 'preparing image on stderr' "$test_dir/err"
        [ "$(tail -n 1 "$log" | cut -d ' ' -f 4)" = "$failure" ]
    done

    # With no broker neither wait polls. The second short session sees
    # the first group's idle state and launches once its containers exit.
    : > "$log"
    printf '%s\n' absent absent idle idle > "$states"
    run "$test_dir/project" 'SANDBOX_TEST_RUNNING=1; export SANDBOX_TEST_RUNNING; sandbox claude && sandbox codex' > "$test_dir/output" 2>"$test_dir/err"
    [ "$(cat "$test_dir/err")" = "$waiting" ]
    grep -Fxq claude "$test_dir/output"
    grep -Fxq codex "$test_dir/output"
    [ "$(grep -Fxc "$poll" "$log")" = 2 ]
    [ "$(grep -Fxc sleep "$log")" = 1 ]
    [ "$(grep -nF "$poll" "$log" | head -n 1 | cut -d: -f1)" -gt "$(grep -n ' run --rm --pull never --label .* claude$' "$log" | cut -d: -f1)" ]

    # A wait during SSH preparation unlocks again in the new group.
    : > "$log"
    printf '%s\n' active idle > "$states"
    run "$test_dir/project" 'SANDBOX_TEST_SSH=1 sandbox' >/dev/null 2>"$test_dir/err"
    [ "$(cat "$test_dir/err")" = "$waiting" ]
    [ "$(grep -Fxc "${unlock% }" "$log")" = 2 ]
    [ "$(grep -A1 -Fx "$poll" "$log")" = "$poll
${unlock% }" ]

    # The unlocked group can also be gone before the second status check.
    : > "$log"
    printf '%s\n' active absent > "$states"
    run "$test_dir/project" 'SANDBOX_TEST_SSH=1 sandbox' >/dev/null
    [ "$(grep -E 'sandbox-lifecycle status$|ssh-unlock --if-needed$| --label ' "$log" |
        sed 's/ --label .*$/ --label/')" = "$status
${unlock% }
$status
${unlock% }
${launch}--pull never --label" ]

    # Another launch can make the group joinable while this one waits.
    : > "$log"
    printf '%s\n' idle active active > "$states"
    run "$test_dir/project" 'SANDBOX_TEST_RUNNING=40 sandbox' >/dev/null 2>"$test_dir/err"
    [ "$(cat "$test_dir/err")" = "$waiting" ]
    [ "$(grep -Fxc "$poll" "$log")" = 1 ]
    if grep -Eq '^(sleep|rm -f )' "$log"; then exit 1; fi

    # Bound the wait even when the broker disappears before its services.
    for failure in none remove; do
        : > "$log"
        printf '%s\n' idle > "$states"
        result=0
        run "$test_dir/project" "SANDBOX_TEST_RUNNING=40 SANDBOX_TEST_FAIL=$failure sandbox" > "$test_dir/output" 2>"$test_dir/err" || result=$?
        [ "$(cat "$test_dir/err")" = "$waiting
$forcing" ]
        [ "$(grep -Fxc "$poll" "$log")" = 40 ]
        [ "$(grep -Fxc sleep "$log")" = 39 ]
        [ "$(grep '^rm -f ' "$log")" = 'rm -f c1
rm -f c2' ]
        if [ "$failure" = none ]; then
            [ "$result" = 0 ]
            grep -Fxq claude "$test_dir/output"
        else
            [ "$result" = 1 ]
            [ ! -s "$test_dir/output" ]
        fi
    done
    : > "$states"

    : > "$log"
    run "$test_dir/project" 'SANDBOX_TEST_LEFT=c9 sandbox' >/dev/null 2>"$test_dir/err"
    grep -Fq 'client left behind' "$test_dir/err"
    [ "$(tail -n 3 "$log")" = "stop -t 15 c9
rm -f c9
$compose config --images" ]
    [ -z "$(ls -A "$TMPDIR")" ]

    # Kill only the launching subshell. Its parent stays alive until the
    # watcher has stopped and removed the late or partially cleaned-up client.
    for point in startup cleanup; do
        orphan_log=$test_dir/$shell-$point
        : > "$orphan_log"
        case "$point" in startup) ready=' --label ' ;; cleanup) ready='stop -t 15 c7' ;; esac
        # shellcheck disable=SC2016 # The Bash or Zsh test process expands these.
        SANDBOX_TEST_LOG=$orphan_log SANDBOX_TEST_INTERRUPT=$point SANDBOX_TEST_READY=$ready SANDBOX_TEST_LEFT=c7 \
            run "$test_dir/project" '
                sandbox >/dev/null 2>&1 & launcher=$!
                for _ in $(seq 50); do
                    grep -Fq "$SANDBOX_TEST_READY" "$SANDBOX_TEST_LOG" && break
                    sleep 0.1
                done
                kill -KILL "$launcher" || exit 1
                wait "$launcher" 2>/dev/null || :
                for _ in $(seq 80); do
                    grep -Fxq "rm -f c7" "$SANDBOX_TEST_LOG" && [ -z "$(ls -A "$TMPDIR")" ] && exit 0
                    sleep 0.1
                done
                exit 1'
        label=$(sed -n 's/^.* --label \(ai-coding-sandbox.client=[0-9.]*\) claude$/\1/p' "$orphan_log")
        [ "$(grep -Fxc "ps -aq --filter label=$label" "$orphan_log")" -ge 2 ]
        if [ "$point" = cleanup ]; then [ "$(grep -Fxc 'stop -t 15 c7' "$orphan_log")" = 2 ]; fi
        [ "$(tail -n 2 "$orphan_log")" = 'stop -t 15 c7
rm -f c7' ]
    done

    for state in active absent; do
        : > "$log"
        run "$test_dir/project" "SANDBOX_TEST_RUNNING=1 SANDBOX_TEST_STATE=$state sandbox-stop"
        {
            echo "$stop"
            if [ "$state" = active ]; then printf '%s\n' "$poll" sleep "$poll"; fi
            printf '%s\n' "$all ps -a -q" 'rm -f one-off' 'rm -f exited' "$all down --remove-orphans"
        } > "$test_dir/expected"
        diff "$test_dir/expected" "$log"
    done
    if run "$test_dir/project" 'SANDBOX_TEST_FAIL=down sandbox-stop'; then exit 1; fi
    for command in sandbox-status sandbox-stop; do
        if run "$test_dir/empty" "$command" 2>"$test_dir/err"; then exit 1; fi
        grep -Fq "$command: no .sandbox/env here" "$test_dir/err"
    done
    [ "$(run "$test_dir/project" sandbox-status)" = 'sandbox-status: no session group is running for this project.' ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_STATE=active sandbox-status')" = 'state=active
joinable=yes
remaining=0
agents=claude
services=docker' ]
    [ "$(run "$test_dir/project" sandbox | tr '\n' ' ')" = "${trust}${launch}${agent}claude " ]
    [ "$(run "$test_dir/project" 'sandbox claude bash' | tr '\n' ' ')" = "${trust}${launch}${agent}claude bash " ]
    [ "$(run "$test_dir/project" 'sandbox codex --help' | tr '\n' ' ')" = "${trust}${launch}${agent}codex --help " ]
    [ "$(run "$test_dir/project" 'unset HERDR_AGENT; SANDBOX_TEST_HERDR=1 sandbox' | tr '\n' ' ')" = "${trust}HERDR_AGENT=claude ${launch}${agent}claude " ]
    [ "$(run "$test_dir/project" 'unset HERDR_AGENT; SANDBOX_TEST_HERDR=1 sandbox codex' | tr '\n' ' ')" = "${trust}HERDR_AGENT=codex ${launch}${agent}codex " ]
    [ "$(run "$test_dir/project" 'HERDR_AGENT=claude SANDBOX_TEST_HERDR=1 sandbox codex' | tr '\n' ' ')" = "HERDR_AGENT=claude ${trust}HERDR_AGENT=claude ${launch}${agent}codex " ]
    [ "$(run "$test_dir/project" 'unset HERDR_AGENT; SANDBOX_TEST_HERDR=1 sandbox claude bash' | tr '\n' ' ')" = "${trust}${launch}${agent}claude bash " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_SSH=1 SANDBOX_TEST_STATE=active sandbox codex' | tr '\n' ' ')" = "${trust}${unlock}${launch}${agent}codex " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=abc SANDBOX_TEST_WANTED=abc sandbox' | tr '\n' ' ')" = "${trust}${launch}${agent}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED= SANDBOX_TEST_WANTED= sandbox' | tr '\n' ' ')" = "${trust}${launch}${agent}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new sandbox codex' 2>"$test_dir/err" | tr '\n' ' ')" = "${trust}${reload}${launch}${agent}codex " ]
    grep -Fq 'reloading the running egress proxy' "$test_dir/err"
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=unknown SANDBOX_TEST_WANTED= sandbox' 2>/dev/null | tr '\n' ' ')" = "${trust}${reload}${launch}${agent}claude " ]
    [ "$(run "$test_dir/project" 'SANDBOX_TEST_APPLIED=old SANDBOX_TEST_WANTED=new SANDBOX_TEST_FAIL=reload sandbox' 2>"$test_dir/err" | tr '\n' ' ')" = "${trust}${reload}${restart}${launch}${agent}claude " ]
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
    run "$test_dir/project" "SANDBOX_TEST_IMAGES='$released ai-coding-sandbox-dev:agent' sandbox-prune" >/dev/null
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
