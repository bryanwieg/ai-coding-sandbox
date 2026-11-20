#!/bin/sh
# Both agent launchers, in their real images with stub CLIs that print their
# arguments: sessions (SANDBOX_SESSION=1) receive the sandbox guide and rules,
# and the image run on its own launches the agent without them. The real
# Codex CLI is also checked to send the rules to a mock model server.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
rules=/usr/local/share/sandbox/session-instructions.md
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

cat > "$test_dir/print-args" <<'EOF'
#!/bin/sh
for argument in "$@"; do printf '%s\n' "$argument"; done
EOF
chmod 0755 "$test_dir/print-args"

# launch AGENT [docker run options...]: prints the stub CLI's arguments.
launch() {
    agent=$1
    shift
    docker run --rm --user "$(id -u):$(id -g)" -v "$test_dir/print-args:/stubs/$agent:ro" \
        -e PATH="/stubs:/opt/agent/node_modules/.bin:/usr/local/bin:/usr/bin:/bin" \
        "$@" --entrypoint /usr/local/libexec/sandbox/agent "ai-coding-sandbox-$agent:test"
}

for agent in claude codex; do
    docker build --quiet --target "$agent" --tag "ai-coding-sandbox-$agent:test" "$sandbox_dir" >/dev/null
done

for agent in claude codex; do
    if docker run --rm --user "$(id -u):$(id -g)" --entrypoint test "ai-coding-sandbox-$agent:test" -r "$rules"; then
        pass "the $agent image's runtime user can read the guide and rules"
    else
        fail "the $agent image's runtime user cannot read the guide and rules"
    fi
    # The loaded file is the guide followed by the rules, both whole.
    if docker run --rm --entrypoint sh "ai-coding-sandbox-$agent:test" -c '
        cd /usr/local/share/sandbox
        { cat session-guide.md; echo; cat session-rules.md; } | cmp -s - session-instructions.md &&
            grep -q "^# Sandbox Session Guide" session-instructions.md &&
            grep -q "^# Sandbox Session Rules" session-instructions.md &&
            grep -q "^## The project.s .\.sandbox/. folder" session-instructions.md &&
            test -r base-policy.yaml'; then
        pass "the $agent image combines the guide and rules and carries the base policy"
    else
        fail "the $agent image's session instructions are not the guide and rules"
    fi
done

output=$(launch claude -e SANDBOX_SESSION=1)
if printf '%s\n' "$output" | grep -Fxq -- --append-system-prompt-file &&
    printf '%s\n' "$output" | grep -Fxq -- "$rules"; then
    pass 'Claude sessions get the guide and rules file'
else
    fail "Claude session arguments: $output"
fi
if [ "$(launch claude)" = --dangerously-skip-permissions ]; then
    pass 'Claude outside a session launches without the rules'
else
    fail 'Claude outside a session got changed arguments'
fi

docker run --rm --entrypoint cat ai-coding-sandbox-codex:test "$rules" > "$test_dir/rules.md"
launch codex -e SANDBOX_SESSION=1 > "$test_dir/codex-args"
# The value is the whole file as one TOML basic string, which jq writes as a
# single-line JSON string.
sed -n 's/^developer_instructions=//p' "$test_dir/codex-args" > "$test_dir/value"
if [ "$(sed -n '1p' "$test_dir/codex-args")" = -a ] && grep -Fxq -- -c "$test_dir/codex-args" &&
    [ "$(wc -l < "$test_dir/value")" -eq 1 ]; then
    pass 'Codex sessions get the guide and rules as developer instructions'
else
    fail "Codex session arguments: $(head -c 300 "$test_dir/codex-args")"
fi
if jq -j . "$test_dir/value" > "$test_dir/decoded" 2>/dev/null && cmp -s "$test_dir/decoded" "$test_dir/rules.md"; then
    pass 'the Codex value carries the whole file intact'
else
    fail 'the Codex value does not decode to the rules file'
fi
if [ "$(launch codex | tr '\n' ' ')" = '-a never --sandbox danger-full-access --dangerously-bypass-hook-trust ' ]; then
    pass 'Codex outside a session launches without the rules'
else
    fail 'Codex outside a session got changed arguments'
fi

# The real Codex CLI sends the rules to the model. Unknown config keys are
# ignored silently, so a renamed key would drop them without an error. A local
# mock model server, without network or sign-in, records the first request.
cat > "$test_dir/mock.py" <<'PYEOF'
import http.server, json
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        with open("/tmp/requests.jsonl", "ab") as requests:
            requests.write(body.replace(b"\n", b" ") + b"\n")
        self.send_response(400)
        self.end_headers()
    def log_message(self, *arguments):
        pass
http.server.HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
PYEOF
cat > "$test_dir/developer-has-rules.py" <<'PYEOF'
import json, sys
body = json.loads(open("/tmp/requests.jsonl").readline())
rules = open(sys.argv[1]).read().strip()
texts = ["".join(part.get("text", "") for part in item.get("content", []))
         for item in body.get("input", []) if item.get("role") == "developer"]
sys.exit(0 if any(rules in text for text in texts) else 1)
PYEOF
# A SessionStart hook in the Codex home that nobody has trusted. The launcher
# skips hook trust review, so its context must reach the model.
cat > "$test_dir/hook.sh" <<'SHEOF'
echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"SANDBOX-HOOK-RAN"}}'
SHEOF
cat > "$test_dir/hooks.json" <<'JSONEOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"sh /tmp/codex-home/hook.sh"}]}]}}
JSONEOF
# codex_request [docker run options...]: runs one exec turn against the mock
# and exits 0 when its first request carries the rules as developer input, 1
# when it does not, 2 when no request arrived, and 3 when the untrusted hook
# did not run.
codex_request() {
    # shellcheck disable=SC2016
    docker run --rm --network none --read-only --tmpfs /tmp:mode=1777 --user "$(id -u):$(id -g)" \
        -v "$test_dir/mock.py:/test/mock.py:ro" -v "$test_dir/developer-has-rules.py:/test/check.py:ro" \
        -v "$test_dir/hooks.json:/test/hooks.json:ro" -v "$test_dir/hook.sh:/test/hook.sh:ro" \
        -e CODEX_HOME=/tmp/codex-home -e MOCK_KEY=unused "$@" --entrypoint sh ai-coding-sandbox-codex:test -c '
        mkdir -p /tmp/codex-home
        cp /test/hooks.json /test/hook.sh /tmp/codex-home/
        python3 /test/mock.py &
        sleep 1
        timeout 60 /usr/local/libexec/sandbox/agent exec --skip-git-repo-check \
            -c model_provider=mock -c model=gpt-mock \
            -c "model_providers.mock={name=\"mock\",base_url=\"http://127.0.0.1:8765/v1\",wire_api=\"responses\",env_key=\"MOCK_KEY\",request_max_retries=0,stream_max_retries=0}" \
            hello >/dev/null 2>&1
        test -s /tmp/requests.jsonl || exit 2
        grep -q SANDBOX-HOOK-RAN /tmp/requests.jsonl || exit 3
        python3 /test/check.py '"$rules"
}
status=0
codex_request -e SANDBOX_SESSION=1 || status=$?
if [ "$status" -eq 0 ]; then
    pass 'Codex sends the guide and rules to the model as developer input'
    pass 'Codex runs untrusted hooks without review'
elif [ "$status" -eq 3 ]; then
    fail 'Codex did not run an untrusted hook'
else
    fail "Codex did not send the guide and rules to the model (status $status)"
fi
status=0
codex_request || status=$?
if [ "$status" -eq 1 ]; then
    pass 'Codex outside a session sends no session rules'
else
    fail "a Codex request outside a session was wrong (status $status)"
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session agent launch checks passed.'
