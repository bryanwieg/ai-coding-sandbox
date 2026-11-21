#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# Session exit in the real agent image: sandbox-start passes the terminal and
# default Ctrl-C handling to the agent, forwards a stop, returns the agent's
# status and runs the exit hooks after a normal exit only; the merged-branch
# cleanup deletes exactly the branches whose work landed in the default
# branch; and the scratchpad tidy-up runs the agent only when the
# scratchpad changed, at a terminal, unless turned off.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-agent:test
prefix=sandbox-exit-test-$$
held=$prefix-held
uid=$(id -u)
gid=$(id -g)
test_dir=$(mktemp -d)
failures=0
# shellcheck source=lifecycle-helper.sh
. "$sandbox_dir/tests/lifecycle-helper.sh"

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume ls -q --filter "label=$prefix" | xargs -r docker volume rm >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target agent --tag "$image" "$sandbox_dir" >/dev/null
lifecycle_build
lifecycle_start "$held"
lifecycle_hold "$held" "$image"

# sandbox-start, with no init hooks, a stub launcher and a recording exit hook.
mkdir -p "$test_dir/empty" "$test_dir/exit.d" "$test_dir/out"
chmod 0777 "$test_dir/out"
cat > "$test_dir/agent" <<'EOF'
#!/bin/sh
sed -n 's/^SigIgn:\t*//p' /proc/self/status > /out/sigign
case "${1:-}" in
    read) read -r line; printf '%s\n' "$line" > /out/stdin ;;
    wait) trap 'echo stopped > /out/agent; exit 0' TERM; : > /out/ready; while :; do sleep 1; done ;;
esac
exit "${STUB_STATUS:-0}"
EOF
cat > "$test_dir/exit.d/10-record" <<'EOF'
#!/bin/sh
[ -e "$SANDBOX_SESSION_STARTED" ] && echo "$SANDBOX_EXIT_REASON" > /out/hook
exit 1
EOF
chmod 0755 "$test_dir/agent" "$test_dir/exit.d/10-record"
start() {
    docker run --init --rm --label "$prefix" --user "$uid:$gid" --read-only --tmpfs /tmp:mode=1777 \
        -v "$test_dir/empty:/usr/local/libexec/sandbox/init.d:ro" \
        -v "$test_dir/empty:/usr/local/libexec/sandbox/claude/init.d:ro" \
        -v "$test_dir/empty:/usr/local/libexec/sandbox/codex/init.d:ro" \
        -v "$test_dir/agent:/usr/local/libexec/sandbox/claude/agent:ro" \
        -v "$test_dir/out:/out" -e SANDBOX_AGENT=claude "$@"
}

record_hooks=$test_dir/exit.d:/usr/local/libexec/sandbox/exit.d:ro
status=0
echo hello | start -v "$record_hooks" -i -e STUB_STATUS=3 "$image" sandbox-start read || status=$?
if [ "$status" = 3 ]; then pass "the agent's exit status is the session's"; else fail "session status $status"; fi
if [ "$(cat "$test_dir/out/stdin" 2>/dev/null)" = hello ]; then
    pass 'the agent reads the terminal'
else
    fail 'the agent did not get its input'
fi
# SigIgn bits 2 and 3 (from 1) are SIGINT and SIGQUIT.
if [ $((0x$(cat "$test_dir/out/sigign") & 6)) -eq 0 ]; then
    pass 'the agent handles Ctrl-C and Ctrl-\ by default'
else
    fail "the agent ignores signals: $(cat "$test_dir/out/sigign")"
fi
if [ "$(cat "$test_dir/out/hook" 2>/dev/null)" = normal ]; then
    pass 'exit hooks run after a normal exit, and their failure is ignored'
else
    fail 'the exit hook did not run after a normal exit'
fi

rm -f "$test_dir/out/"*
container=$(start -v "$record_hooks" -d "$image" sandbox-start wait)
tries=0
while [ ! -e "$test_dir/out/ready" ] && [ "$tries" -lt 50 ]; do sleep 0.2; tries=$((tries + 1)); done
docker stop --time 10 "$container" >/dev/null
if [ "$(cat "$test_dir/out/agent" 2>/dev/null)" = stopped ] && [ ! -e "$test_dir/out/hook" ]; then
    pass 'a stop reaches the agent and skips the exit hooks'
else
    fail "stop: agent=$(cat "$test_dir/out/agent" 2>/dev/null) hook=$(cat "$test_dir/out/hook" 2>/dev/null)"
fi

# Merged-branch cleanup, against a local origin mounted at the same path.
repo=$test_dir/repo
origin=$test_dir/origin.git
g() { git -C "$repo" -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
commit() { printf '%s\n' "$2" > "$repo/$1"; g add "$1"; g commit --quiet -m "$1 $2"; }
git -c init.defaultBranch=main init --quiet --bare "$origin"
git -c init.defaultBranch=main init --quiet "$repo"
commit base 1
g remote add origin "$origin"
g push --quiet -u origin main
g remote set-head origin main
# merged: fast-forwarded into main.
g switch --quiet -c merged; commit merged 1
# squashed: two commits, squashed into one on main.
g switch --quiet -c squashed main; commit squashed 1; commit squashed 2
# rebased: two commits, applied one by one onto a moved main.
g switch --quiet -c rebased main; commit rebased 1; commit rebased-2 1
# open: work that is not in main.
g switch --quiet -c open main; commit open 1
# kept-worktree: merged, but checked out in a worktree.
g switch --quiet -c kept-worktree main; commit worktree 1
# current: merged, and the checked-out branch.
g switch --quiet -c current main; commit current 1
g switch --quiet main
g merge --quiet --ff-only merged
g merge --quiet --no-edit kept-worktree >/dev/null
g merge --quiet --no-edit current
commit other 1
g merge --quiet --squash squashed >/dev/null && g commit --quiet -m 'squashed'
g cherry-pick rebased~1 rebased >/dev/null
g push --quiet origin main
# fresh: just created at main's tip.
g branch fresh
g worktree add --quiet "$test_dir/wt" kept-worktree
g switch --quiet current

# A normal agent exit runs the image's branch hook through the lifecycle wrapper.
# shellcheck disable=SC2046 # lifecycle_mount prints the two mount arguments.
if output=$(start --network none $(lifecycle_mount "$held" agents) -v "$test_dir:$test_dir" -w "$repo" \
    -e SANDBOX_SESSION=1 "$image" sandbox-start 2>&1); then
    pass 'the broker-wrapped session exits normally'
else
    fail "broker-wrapped session exited $?: $output"
fi
left=$(g for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ')
if [ "$left" = 'current fresh kept-worktree main open ' ]; then
    pass 'merged, squashed and rebased branches go; current, fresh, worktree, open and default stay'
else
    fail "branches left: $left ($output)"
fi
if printf '%s\n' "$output" | grep -q '^Deleted merged branch squashed (was .*; restore: git branch squashed '; then
    pass 'each deletion prints how to restore the branch'
else
    fail "deletion report: $output"
fi
g branch merged-again main~1
docker run --rm --user "$uid:$gid" --network none -v "$test_dir:$test_dir" -w "$repo" \
    -e SANDBOX_SESSION=1 -e SANDBOX_EXIT_CLEANUP=off --entrypoint sh "$image" \
    /usr/local/libexec/sandbox/exit.d/10-git-branches
if g show-ref --verify --quiet refs/heads/merged-again; then
    pass 'SANDBOX_EXIT_CLEANUP=off keeps merged branches'
else
    fail 'SANDBOX_EXIT_CLEANUP=off deleted a branch'
fi

# Scratchpad tidy-up with a stub claude that records its call.
project=$test_dir/project
mkdir -p "$project/.ai-scratchpad" "$test_dir/stubs"
printf '#!/bin/sh\necho called > /out/curate\n' > "$test_dir/stubs/claude"
chmod 0755 "$test_dir/stubs/claude"
: > "$test_dir/started"
touch -d '1 hour ago' "$test_dir/started"
: > "$project/.ai-scratchpad/.session-days"
touch -d '2 hours ago' "$project/.ai-scratchpad/.session-days"
: > "$project/.ai-scratchpad/old-note"
touch -d '2 hours ago' "$project/.ai-scratchpad/old-note"
curated() { [ -e "$test_dir/out/curate" ]; }
# check_curate yes|no DESCRIPTION [docker run options...]
check_curate() {
    expected=$1 description=$2
    shift 2
    rm -f "$test_dir/out/curate"
    docker run --rm --user "$uid:$gid" --network none -v "$project:/workspace/p" -w /workspace/p \
        -v "$test_dir/started:/started:ro" -v "$test_dir/stubs:/stubs:ro" -v "$test_dir/out:/out" \
        -e PATH=/stubs:/usr/local/bin:/usr/bin:/bin -e SANDBOX_SESSION=1 -e SANDBOX_AGENT=claude \
        -e SANDBOX_SESSION_STARTED=/started "$@" --entrypoint sh "$image" \
        /usr/local/libexec/sandbox/exit.d/20-scratchpad >/dev/null 2>&1 || :
    if { [ "$expected" = yes ] && curated; } || { [ "$expected" = no ] && ! curated; }; then
        pass "$description"
    else
        fail "$description"
    fi
}
check_curate no 'an unchanged scratchpad is not tidied' -t
: > "$project/.ai-scratchpad/new-note"
check_curate yes 'a scratchpad changed this session is tidied at a terminal' -t
check_curate no 'without a terminal, nothing is tidied'
check_curate no 'SANDBOX_EXIT_CURATE=off skips the tidy-up' -t -e SANDBOX_EXIT_CURATE=off
check_curate no 'SANDBOX_EXIT_CLEANUP=off skips the tidy-up' -t -e SANDBOX_EXIT_CLEANUP=off
check_curate no 'after a hangup, nothing is tidied' -t -e SANDBOX_EXIT_REASON=hangup

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session exit checks passed.'
