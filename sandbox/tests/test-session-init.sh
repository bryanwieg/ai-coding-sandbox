#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# Runtime test for the session startup hooks in the agent base image, with
# stubbed agent, GitHub and ssh-add commands: .sandbox/env and SSH key
# refusals; egress policy and SSH warnings; logins only when signed
# out, and only prompting with a terminal; the scratchpad and its cleanup.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-base:test
prefix=sandbox-init-test-$$
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

docker build --quiet --target base --tag "$image" "$sandbox_dir" >/dev/null
lifecycle_build
lifecycle_start "$held"
lifecycle_hold "$held" "$image"

reference=$test_dir/reference
project=$reference/src/demo
trust=$test_dir/trust
stubs=$test_dir/stubs
mkdir -p "$project/.sandbox" "$trust" "$stubs" "$test_dir/keys"
: > "$project/.sandbox/env"
chmod 0600 "$project/.sandbox/env"

stub() {
    printf '#!/bin/sh\n%s\n' "$2" > "$stubs/$1"
    chmod 0755 "$stubs/$1"
}
# The stub bodies run inside the container, so they must not expand here.
# shellcheck disable=SC2016
{
stub ssh-add 'exit "${STUB_SSH:-0}"'
stub gh 'case "$1 $2" in "auth status") exit "${STUB_GH:-0}" ;; "auth login") echo LOGIN-GITHUB ;; esac'
stub agent-auth 'case "$1" in status) exit "${STUB_AGENT:-0}" ;; login) echo LOGIN-AGENT ;; esac'
}

# Runs init hook $1 in a session container; the remaining arguments are extra
# docker run options. Prints the output and exits with the hook's status.
hook() {
    name=$1
    shift
    # shellcheck disable=SC2046
    docker run --rm --label "$prefix" --user "$uid:$gid" $(lifecycle_mount "$held" agents) \
        -v "$reference:/reference:ro" -v "$project:/workspace/demo" \
        -v "$project/.sandbox:/workspace/demo/.sandbox:ro" -w /workspace/demo \
        -v "$trust:/run/sandbox-trust:ro" -v "$stubs:/stubs:ro" \
        -v "$stubs/agent-auth:/usr/local/libexec/sandbox/codex/auth:ro" -e SANDBOX_AGENT=codex \
        -e PATH=/stubs:/usr/local/bin:/usr/bin:/bin \
        -e SANDBOX_SESSION=1 -e "SANDBOX_REFERENCE=$reference" \
        -e "HOST_PWD=$project" -e "SANDBOX_SSH_KEY_DIR=$test_dir/keys" \
        "$@" "$image" sh "/usr/local/libexec/sandbox/init.d/$name" 2>&1
}

# check DESCRIPTION EXPECTED_STATUS PATTERN HOOK [OPTIONS...]: the hook exits
# with EXPECTED_STATUS and its output matches PATTERN ('' = no output).
check() {
    description=$1 expected=$2 pattern=$3
    shift 3
    status=0
    output=$(hook "$@") || status=$?
    if [ "$status" != "$expected" ]; then
        fail "$description (status $status): $output"
    elif [ -z "$pattern" ] && [ -n "$output" ]; then
        fail "$description (unexpected output): $output"
    elif [ -n "$pattern" ] && ! printf '%s\n' "$output" | grep -q -- "$pattern"; then
        fail "$description (output): $output"
    else
        pass "$description"
    fi
}

check 'a correct session passes silently' 0 '' 00-session
check 'the image outside a session skips the checks' 0 '' 00-session -e SANDBOX_SESSION=
chmod 0644 "$project/.sandbox/env"
check 'a .sandbox/env readable by others is refused' 1 'chmod 600 .sandbox/env' 00-session
chmod 0600 "$project/.sandbox/env"
mv "$project/.sandbox/env" "$test_dir/env"
check 'a missing .sandbox/env is refused' 1 'missing or not a regular file' 00-session
mv "$test_dir/env" "$project/.sandbox/env"

: > "$project/.sandbox/agent.env"
chmod 0600 "$project/.sandbox/agent.env"
check 'a private agent.env is accepted' 0 '' 00-session
chmod 0644 "$project/.sandbox/agent.env"
check 'an agent.env readable by others is refused' 1 'chmod 600 .sandbox/agent.env' 00-session
rm "$project/.sandbox/agent.env"
ln -s env "$project/.sandbox/agent.env"
check 'an agent.env symlink is refused' 1 'not a regular file' 00-session
rm "$project/.sandbox/agent.env"

check 'an SSH key folder inside the reference root is refused' 1 'inside the project or reference root' 00-session \
    -e "SANDBOX_SSH_KEY_DIR=$reference/keys"
check 'an SSH key folder inside the project is refused without a reference' 1 'inside the project or reference root' 00-session \
    -e SANDBOX_REFERENCE= -e "SANDBOX_SSH_KEY_DIR=$project/keys"
check 'an unrelated reference is accepted' 0 '' 00-session -e SANDBOX_REFERENCE=/elsewhere
check 'no reference is accepted' 0 '' 00-session -e SANDBOX_REFERENCE=
mkdir "$reference/ssh-keys"
check 'an empty workspace ssh-keys folder is accepted' 0 '' 00-session
: > "$reference/ssh-keys/.gitkeep"
: > "$reference/ssh-keys/id_ed25519.pub"
check 'a .gitkeep and public keys in the workspace ssh-keys folder are accepted' 0 '' 00-session
: > "$reference/ssh-keys/id_ed25519"
check 'private keys in the workspace ssh-keys folder are refused' 1 'could read: id_ed25519 $' 00-session
rm -r "$reference/ssh-keys"

printf 'https:\n  - extra.example\n' > "$project/.sandbox/egress-policy.yaml"
check 'an unapproved egress policy warns' 0 'not approved' 00-session
"$sandbox_dir/image/sandbox-policy" hash "$project/.sandbox/egress-policy.yaml" \
    > "$trust/$("$sandbox_dir/image/sandbox-policy" trust-id "$project").sha256"
check 'an approved egress policy passes silently' 0 '' 00-session
printf 'unrestricted_out: true\n' > "$project/.sandbox/egress-policy.yaml"
check 'an unapproved unrestricted policy warns that it is not approved' 0 'not approved' 00-session
"$sandbox_dir/image/sandbox-policy" hash "$project/.sandbox/egress-policy.yaml" \
    > "$trust/$("$sandbox_dir/image/sandbox-policy" trust-id "$project").sha256"
check 'an approved unrestricted policy warns that every destination is allowed' 0 'is unrestricted' 00-session
printf 'bogus\n' >> "$project/.sandbox/egress-policy.yaml"
check 'an invalid egress policy warns' 0 'is invalid' 00-session
rm "$project/.sandbox/egress-policy.yaml"

check 'SSH enabled without unlocked keys warns' 0 'run --rm ssh-unlock' 00-session \
    -e SANDBOX_PROFILES=claude,ssh -e STUB_SSH=1
check 'SSH enabled with unlocked keys passes silently' 0 '' 00-session -e SANDBOX_PROFILES=claude,ssh

check 'signed-in agent and GitHub need no login' 0 '' 01-login
check 'without a terminal, logins are only named' 0 'sandbox-auth login' 01-login -e STUB_AGENT=1 -e STUB_GH=1
output=$(hook 01-login -t -e STUB_AGENT=1 -e STUB_GH=1 | tr -d '\r') || :
if printf '%s\n' "$output" | grep -q LOGIN-AGENT && printf '%s\n' "$output" | grep -q LOGIN-GITHUB; then
    pass 'with a terminal, signed-out agent and GitHub logins start'
else
    fail "logins did not start with a terminal: $output"
fi
output=$(hook 01-login -t -e STUB_GH=1 | tr -d '\r') || :
if ! printf '%s\n' "$output" | grep -q LOGIN-AGENT && printf '%s\n' "$output" | grep -q LOGIN-GITHUB; then
    pass 'only the signed-out login starts'
else
    fail "unexpected logins: $output"
fi

scratch=$project/.ai-scratchpad
check 'the scratchpad is created silently' 0 '' 07-scratchpad
if [ "$(cat "$scratch/.gitignore")" = '*' ] && [ "$(wc -l < "$scratch/.session-days")" -eq 1 ]; then
    pass 'the scratchpad ignores itself in Git and records the session day'
else
    fail 'the scratchpad lacks its .gitignore or session day'
fi
check 'a second session on the same day records no new day' 0 '' 07-scratchpad
if [ "$(wc -l < "$scratch/.session-days")" -eq 1 ]; then
    pass 'one line per session day'
else
    fail "session days: $(cat "$scratch/.session-days")"
fi
# A project left alone for years with few session days keeps its notes.
printf '2020-01-01\n2020-06-01\n' > "$scratch/.session-days"
: > "$scratch/ancient"
touch -d '2019-01-01' "$scratch/ancient"
check 'few session days keep old entries' 0 '' 07-scratchpad
if [ -e "$scratch/ancient" ]; then
    pass 'time away from the project does not age its notes'
else
    fail 'an entry was removed by calendar age alone'
fi
# Six earlier session days plus today: the oldest, 2020-01-01, is the cutoff.
: > "$scratch/.session-days"
for day in 01 02 03 04 05 06; do
    printf '2020-01-%s\n' "$day" >> "$scratch/.session-days"
done
mkdir -p "$scratch/old-dir"
: > "$scratch/old-dir/note"
: > "$scratch/recent"
touch -d '2019-12-01' "$scratch/ancient" "$scratch/old-dir/note" "$scratch/.gitignore"
touch -d '2020-01-05' "$scratch/recent"
check 'the image outside a session leaves the scratchpad alone' 0 '' 07-scratchpad -e SANDBOX_SESSION=
check 'cleanup off keeps old entries' 0 '' 07-scratchpad -e SANDBOX_SCRATCHPAD_DAYS=off
if [ -e "$scratch/ancient" ]; then pass 'old entries survive with cleanup off'; else fail 'cleanup off removed entries'; fi
sed -i '$d' "$scratch/.session-days"
check 'an invalid age warns and keeps old entries' 0 'must be a number of session days' 07-scratchpad \
    -e SANDBOX_SCRATCHPAD_DAYS=soon
if [ -e "$scratch/ancient" ]; then pass 'old entries survive an invalid age'; else fail 'an invalid age removed entries'; fi
sed -i '$d' "$scratch/.session-days"
check 'the scratchpad is cleaned silently' 0 '' 07-scratchpad
if [ ! -e "$scratch/ancient" ] && [ ! -e "$scratch/old-dir" ] && [ -e "$scratch/recent" ] &&
    [ -e "$scratch/.gitignore" ] && [ "$(wc -l < "$scratch/.session-days")" -eq 7 ]; then
    pass 'entries untouched for 7 session days go; newer entries and bookkeeping stay'
else
    fail "unexpected scratchpad contents: $(cd "$scratch" && find . | sort | tr '\n' ' ')"
fi
rm -r "$scratch"
mkdir "$test_dir/outside"
: > "$test_dir/outside/keep"
touch -d '2019-01-01' "$test_dir/outside/keep"
ln -s "$test_dir/outside" "$scratch"
check 'a linked scratchpad warns and is left alone' 0 'not a plain folder' 07-scratchpad
if [ -e "$test_dir/outside/keep" ] && [ ! -e "$test_dir/outside/.session-days" ]; then
    pass 'nothing behind a linked scratchpad is touched'
else
    fail 'cleanup followed the scratchpad link'
fi
rm "$scratch"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session startup checks passed.'
