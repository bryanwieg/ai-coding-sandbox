#!/bin/sh
# The launch-time GitHub token check reports every outcome without failing,
# and never puts the token on a command line.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
check="$root_dir/image/sandbox-check-github"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# The stub records its arguments and stdin, then answers with the configured
# HTTP status; 000 imitates an unreachable proxy or host.
cat > "$test_dir/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$GITHUB_TEST_LOG.args"
cat > "$GITHUB_TEST_LOG.stdin"
printf '%s' "$GITHUB_TEST_STATUS"
[ "$GITHUB_TEST_STATUS" != 000 ] || exit 7
STUB
chmod 0755 "$test_dir/curl"
PATH="$test_dir:$PATH"
GITHUB_TEST_LOG="$test_dir/log"
export GITHUB_TEST_LOG

run_check() {
    GITHUB_TEST_STATUS=$1 "$check" 2> "$test_dir/output"
}

# Without a token, unset or empty, the variable is named and nothing is requested.
unset GITHUB_PERSONAL_ACCESS_TOKEN
run_check 200
grep -Fxq "WARNING: GITHUB_PERSONAL_ACCESS_TOKEN is not set; Claude's GitHub MCP tools will not connect. Add it to .sandbox/agent.env." "$test_dir/output"
GITHUB_PERSONAL_ACCESS_TOKEN='' run_check 200
grep -Fq 'WARNING: GITHUB_PERSONAL_ACCESS_TOKEN is not set' "$test_dir/output"
[ ! -e "$test_dir/log.args" ]

GITHUB_PERSONAL_ACCESS_TOKEN=ghp_test-secret
export GITHUB_PERSONAL_ACCESS_TOKEN
run_check 200
grep -Fxq 'GitHub: token accepted.' "$test_dir/output"
grep -Fxq 'Authorization: Bearer ghp_test-secret' "$test_dir/log.stdin"
if grep -Fq ghp_test-secret "$test_dir/log.args"; then
    echo 'The token appeared in curl arguments.' >&2
    exit 1
fi
grep -Eq '(^| )https://api\.github\.com/user$' "$test_dir/log.args"
grep -Fq -- '--max-time 5' "$test_dir/log.args"

run_check 401
grep -Fxq 'WARNING: GitHub rejected GITHUB_PERSONAL_ACCESS_TOKEN; GitHub MCP tools will fail until the token is fixed or replaced.' "$test_dir/output"
run_check 403
grep -Fxq 'WARNING: GitHub refused the token check (HTTP 403); the token may lack access or be rate limited.' "$test_dir/output"
run_check 429
grep -Fxq 'WARNING: GitHub refused the token check (HTTP 429); the token may lack access or be rate limited.' "$test_dir/output"
run_check 000
grep -Fxq 'WARNING: GitHub is unreachable through the egress proxy; the token was not checked.' "$test_dir/output"
run_check 502
grep -Fxq 'WARNING: GitHub token check returned HTTP 502; GitHub MCP tools may fail.' "$test_dir/output"

echo 'GitHub check tests passed.'
