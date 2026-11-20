#!/bin/sh
# The launch-time Context7 key check reports every outcome without failing,
# and never puts the key on a command line.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
check="$root_dir/image/sandbox-check-context7"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# The stub records its arguments and stdin, then answers with the configured
# HTTP status; 000 imitates an unreachable proxy or host.
cat > "$test_dir/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CONTEXT7_TEST_LOG.args"
cat > "$CONTEXT7_TEST_LOG.stdin"
printf '%s' "$CONTEXT7_TEST_STATUS"
[ "$CONTEXT7_TEST_STATUS" != 000 ] || exit 7
EOF
chmod 0755 "$test_dir/curl"
PATH="$test_dir:$PATH"
CONTEXT7_TEST_LOG="$test_dir/log"
export CONTEXT7_TEST_LOG

run_check() {
    CONTEXT7_TEST_STATUS=$1 "$check" 2> "$test_dir/output"
}

# Without a key nothing is requested.
unset CONTEXT7_API_KEY
run_check 200
grep -Fxq 'Context7: no API key; using anonymous rate limits.' "$test_dir/output"
[ ! -e "$test_dir/log.args" ]

CONTEXT7_API_KEY=ctx7sk-test-secret
export CONTEXT7_API_KEY
run_check 200
grep -Fxq 'Context7: API key accepted.' "$test_dir/output"
grep -Fxq 'Authorization: Bearer ctx7sk-test-secret' "$test_dir/log.stdin"
if grep -Fq ctx7sk-test-secret "$test_dir/log.args"; then
    echo 'The API key appeared in curl arguments.' >&2
    exit 1
fi
grep -Fq 'https://context7.com/api/v2/libs/search?' "$test_dir/log.args"
grep -Fq -- '--max-time 5' "$test_dir/log.args"

run_check 401
grep -Fq 'WARNING: Context7 rejected CONTEXT7_API_KEY' "$test_dir/output"
run_check 429
grep -Fq 'WARNING: Context7 reports the API key is rate limited' "$test_dir/output"
run_check 000
grep -Fq 'WARNING: Context7 is unreachable through the egress proxy' "$test_dir/output"
run_check 502
grep -Fq 'WARNING: Context7 API key check returned HTTP 502' "$test_dir/output"

echo 'Context7 check tests passed.'
