#!/bin/sh
# Both agent launchers, in the real agent image with stub CLIs that print
# their arguments: sessions (SANDBOX_SESSION=1) receive the sandbox guide and
# rules, and the image run on its own launches the agent without them.
# sandbox-start sets up both agents and runs the launcher SANDBOX_AGENT names;
# both agents share one plugin config folder, also when one runs the other. The real
# Codex CLI is also checked to send the rules to a mock model server.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
rules=/usr/local/share/sandbox/session-instructions.md
# Stubs must be executable, and bind-mountable by the session daemon (the
# project is its only shared folder): /tmp is noexec in sandbox sessions.
mkdir -p "$sandbox_dir/tests/.tmp"
test_dir=$(mktemp -d "$sandbox_dir/tests/.tmp/test.XXXXXX")
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
        -e PATH="/stubs:/usr/local/bin:/usr/bin:/bin" \
        "$@" --entrypoint "/usr/local/libexec/sandbox/$agent/agent" "$image"
}

image=ai-coding-sandbox-agent:test
docker build --quiet --target agent --tag "$image" "$sandbox_dir" >/dev/null

if docker run --rm --user "$(id -u):$(id -g)" --entrypoint test "$image" -r "$rules"; then
    pass "the image's runtime user can read the guide and rules"
else
    fail "the image's runtime user cannot read the guide and rules"
fi
# The loaded file is the guide followed by the rules, both whole.
if docker run --rm --entrypoint sh "$image" -c '
    cd /usr/local/share/sandbox
    { cat session-guide.md; echo; cat session-rules.md; } | cmp -s - session-instructions.md &&
        grep -q "^# Sandbox Session Guide" session-instructions.md &&
        grep -q "^# Sandbox Session Rules" session-instructions.md &&
        grep -q "^## The project.s .\.sandbox/. folder" session-instructions.md &&
        test -r base-policy.yaml'; then
    pass 'the image combines the guide and rules and carries the base policy'
else
    fail "the image's session instructions are not the guide and rules"
fi

# Both CLIs are installed and on PATH, so either agent can run the other.
for agent in claude codex; do
    if docker run --rm --network none --entrypoint sh "$image" -c "command -v $agent >/dev/null"; then
        pass "the $agent CLI is on PATH"
    else
        fail "the $agent CLI is missing"
    fi
done

# sandbox-start runs the shared init scripts and both agents', then the named
# agent's launcher. The other agent, signed out, syncs no plugins, and the
# Context7 key is checked once. Stubs record calls.
cat > "$test_dir/record" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> /tmp/calls
EOF
chmod 0755 "$test_dir/record"
for agent in claude codex; do
    # shellcheck disable=SC2016
    calls=$(docker run --rm --network none --read-only --tmpfs /tmp:mode=1777 --user "$(id -u):$(id -g)" \
        -v "$test_dir/record:/stubs/claude:ro" -v "$test_dir/record:/stubs/codex:ro" \
        -v "$test_dir/record:/stubs/sandbox-check-context7:ro" \
        -e PATH="/stubs:/usr/local/bin:/usr/bin:/bin" -e SANDBOX_AGENT="$agent" \
        -e CLAUDE_CONFIG_DIR=/tmp/claude -e CODEX_HOME=/tmp/codex \
        --entrypoint sh "$image" -c 'sandbox-start --probe >/dev/null 2>&1; cat /tmp/calls; ls /tmp')
    case "$agent" in claude) other=codex ;; codex) other=claude ;; esac
    if printf '%s\n' "$calls" | grep -Eq "^$agent( .*)? --probe\$" &&
        ! printf '%s\n' "$calls" | grep -q "^$other " &&
        [ "$(printf '%s\n' "$calls" | grep -c '^sandbox-check-context7')" -eq 1 ] &&
        printf '%s\n' "$calls" | grep -Fxq "$agent" && printf '%s\n' "$calls" | grep -Fxq "$other"; then
        pass "sandbox-start sets up both agents and launches $agent only"
    else
        fail "sandbox-start for $agent: $calls"
    fi
done
# AI_CODEX=off skips Codex's setup in a Claude session; Claude still launches.
# shellcheck disable=SC2016
calls=$(docker run --rm --network none --read-only --tmpfs /tmp:mode=1777 --user "$(id -u):$(id -g)" \
    -v "$test_dir/record:/stubs/claude:ro" -v "$test_dir/record:/stubs/codex:ro" \
    -v "$test_dir/record:/stubs/sandbox-check-context7:ro" \
    -e PATH="/stubs:/usr/local/bin:/usr/bin:/bin" -e SANDBOX_AGENT=claude -e AI_CODEX=off \
    -e CLAUDE_CONFIG_DIR=/tmp/claude -e CODEX_HOME=/tmp/codex \
    --entrypoint sh "$image" -c 'sandbox-start --probe >/dev/null 2>&1; cat /tmp/calls; ls /tmp')
if printf '%s\n' "$calls" | grep -Eq '^claude( .*)? --probe$' &&
    printf '%s\n' "$calls" | grep -Fxq claude && ! printf '%s\n' "$calls" | grep -Fxq codex; then
    pass 'AI_CODEX=off skips Codex setup in a Claude session'
else
    fail "sandbox-start for claude with AI_CODEX=off: $calls"
fi
# Through the entrypoint, both CLIs get the shared xdg folder in Claude's
# state, also when the other agent runs them; an explicit XDG_CONFIG_HOME is
# kept. Stub CLIs stand in for the real ones under /opt and print the folder.
for agent in claude codex; do
    mkdir -p "$test_dir/opt-$agent/node_modules/.bin"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "%%s\\n" "$XDG_CONFIG_HOME"\n' > "$test_dir/opt-$agent/node_modules/.bin/$agent"
    chmod 0755 "$test_dir/opt-$agent/node_modules/.bin/$agent"
done
# xdg STARTED CLI [docker run options...]: the folder CLI sees in a session of STARTED.
xdg() {
    started=$1 cli=$2
    shift 2
    docker run --rm --network none --user "$(id -u):$(id -g)" \
        -v "$test_dir/opt-claude:/opt/claude:ro" -v "$test_dir/opt-codex:/opt/codex:ro" \
        -e SANDBOX_AGENT="$started" -e CLAUDE_CONFIG_DIR=/s/claude -e CODEX_HOME=/s/codex \
        "$@" "$image" "$cli"
}
if [ "$(xdg claude claude)" = /s/claude/xdg ] && [ "$(xdg claude codex)" = /s/claude/xdg ] &&
    [ "$(xdg codex codex)" = /s/claude/xdg ] && [ "$(xdg codex claude)" = /s/claude/xdg ]; then
    pass 'both agents share one plugin config folder, also when one runs the other'
else
    fail "plugin config folders: $(xdg claude codex) $(xdg codex claude)"
fi
if [ "$(xdg claude codex -e XDG_CONFIG_HOME=/tmp/mine)" = /tmp/mine ]; then
    pass 'an explicit XDG_CONFIG_HOME reaches the other agent unchanged'
else
    fail 'an explicit XDG_CONFIG_HOME was replaced'
fi

if docker run --rm --network none "$image" >/dev/null 2>&1; then
    fail 'sandbox-start ran without SANDBOX_AGENT'
else
    pass 'sandbox-start refuses to run without SANDBOX_AGENT'
fi

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

docker run --rm --entrypoint cat "$image" "$rules" > "$test_dir/rules.md"
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
        -e CODEX_HOME=/tmp/codex-home -e MOCK_KEY=unused "$@" --entrypoint sh "$image" -c '
        mkdir -p /tmp/codex-home
        cp /test/hooks.json /test/hook.sh /tmp/codex-home/
        python3 /test/mock.py &
        sleep 1
        timeout 60 /usr/local/libexec/sandbox/codex/agent exec --skip-git-repo-check \
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

# Codex's bubblewrap sandbox cannot start in the container, so the image
# makes danger-full-access the default for every Codex run, through the
# builder variable and the system config, which the user's config and flags
# still override. codex exec reports its sandbox before calling the model,
# so this runs offline. The system config is an undocumented layer: this
# fails if a Codex update stops reading it.
if [ "$(docker run --rm --entrypoint printenv "$image" CODEX_BUILD_SANDBOX)" = danger-full-access ]; then
    pass 'the image sets CODEX_BUILD_SANDBOX=danger-full-access'
else
    fail 'CODEX_BUILD_SANDBOX is not danger-full-access'
fi
if [ "$(docker run --rm --entrypoint printenv "$image" CLAUDE_BUILD_PERMISSIONS)" = bypassPermissions ]; then
    pass 'the image sets CLAUDE_BUILD_PERMISSIONS=bypassPermissions'
else
    fail 'CLAUDE_BUILD_PERMISSIONS is not bypassPermissions'
fi
mkdir -p "$test_dir/codex-user"
printf 'sandbox_mode = "read-only"\n' > "$test_dir/codex-user/config.toml"
# codex_sandbox USER_CONFIG [codex exec options...]: the sandbox codex exec reports.
codex_sandbox() {
    user_config=$1
    shift
    # shellcheck disable=SC2016
    docker run --rm --network none --read-only --tmpfs /tmp:mode=1777 --user "$(id -u):$(id -g)" -w /tmp \
        -v "$test_dir/codex-user:/seed:ro" -e USER_CONFIG="$user_config" --entrypoint sh "$image" -c '
            mkdir -p /tmp/codex
            [ "$USER_CONFIG" = no ] || cp /seed/config.toml /tmp/codex/
            CODEX_HOME=/tmp/codex timeout 30 codex exec --skip-git-repo-check "$@" hello </dev/null 2>&1 |
                sed -n "s/^sandbox: \([a-z-]*\).*/\1/p" | head -n 1' sh "$@"
}
if [ "$(codex_sandbox no)" = danger-full-access ]; then
    pass 'plain codex exec defaults to danger-full-access'
else
    fail "plain codex exec sandbox: $(codex_sandbox no)"
fi
if [ "$(codex_sandbox yes)" = read-only ] && [ "$(codex_sandbox no --sandbox workspace-write)" = workspace-write ]; then
    pass "the user's Codex config and --sandbox still override the default"
else
    fail "Codex overrides: config=$(codex_sandbox yes) flag=$(codex_sandbox no --sandbox workspace-write)"
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session agent launch checks passed.'
