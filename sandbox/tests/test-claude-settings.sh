#!/bin/sh
# Host test for Claude's settings startup hook: it accepts bypass mode, sets the
# usage-capturing status line when there is none or the earlier hand-set one,
# keeps any other status line and setting, and changes nothing on a rerun. The
# status line it writes saves usage JSON atomically and shows ponytail's status
# line from the config folder or ponytail's marketplace clone, when present.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
hook=$sandbox_dir/claude/init.d/20-settings
test_dir=$(mktemp -d)
failures=0
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# The earlier hand-set status line, kept here independently of the hook.
hand_set=$(cat <<'EOF'
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; t="$d/claude-usage.json.$$"; find "$d" -maxdepth 1 -name 'claude-usage.json.*' -mmin +1 -delete 2>/dev/null; cat > "$t"; bash "$d/ponytail-statusline.sh" < "$t"; if grep -q '"rate_limits"' "$t"; then mv "$t" "$d/claude-usage.json"; else rm -f "$t"; fi
EOF
)

# run NAME: runs the hook with the config folder test_dir/NAME and prints its output.
run() {
    mkdir -p "$test_dir/$1"
    CLAUDE_CONFIG_DIR=$test_dir/$1 sh "$hook" 2>&1
}

output=$(run fresh)
settings=$test_dir/fresh/settings.json
capture=$(jq -r '.statusLine.command' "$settings")
if [ -z "$output" ] && [ "$(jq -c '.skipDangerousModePermissionPrompt, .statusLine.type' "$settings")" = 'true
"command"' ] && grep -q claude-usage.json "$settings" && [ "$capture" != "$hand_set" ]; then
    pass 'a new config folder gets bypass mode and the capture status line, quietly'
else
    fail "a new config folder was not set up: $output"
fi

before=$(cat "$settings")
run fresh >/dev/null
if [ "$(cat "$settings")" = "$before" ]; then
    pass 'a second start changes nothing'
else
    fail 'a second start changed the settings'
fi

mkdir -p "$test_dir/kept"
printf '{"model": "opus", "env": {"A": "1"}}\n' > "$test_dir/kept/settings.json"
run kept >/dev/null
if [ "$(jq -c '[.model, .env, .statusLine.command == $c]' --arg c "$capture" "$test_dir/kept/settings.json")" = '["opus",{"A":"1"},true]' ]; then
    pass 'other settings are kept'
else
    fail 'other settings were lost'
fi

mkdir -p "$test_dir/hand-set"
jq -n --arg c "$hand_set" '{statusLine: {type: "command", command: $c}}' > "$test_dir/hand-set/settings.json"
run hand-set >/dev/null
if [ "$(jq -r '.statusLine.command' "$test_dir/hand-set/settings.json")" = "$capture" ]; then
    pass 'the earlier hand-set status line is replaced'
else
    fail 'the earlier hand-set status line was not replaced'
fi

mkdir -p "$test_dir/own"
printf '{"statusLine": {"type": "command", "command": "echo mine", "padding": 1}}\n' > "$test_dir/own/settings.json"
run own >/dev/null
if [ "$(jq -c '.statusLine' "$test_dir/own/settings.json")" = '{"type":"command","command":"echo mine","padding":1}' ]; then
    pass 'another status line is kept'
else
    fail 'another status line was changed'
fi

mkdir -p "$test_dir/odd"
printf '{"statusLine": "not an object"}\n' > "$test_dir/odd/settings.json"
run odd >/dev/null
if [ "$(jq -c '[.statusLine, .skipDangerousModePermissionPrompt]' "$test_dir/odd/settings.json")" = '["not an object",true]' ]; then
    pass 'a status line that is not an object is kept and bypass mode is still set'
else
    fail 'a status line that is not an object broke the settings update'
fi

# status NAME INPUT: runs the written status line in test_dir/NAME with INPUT on stdin.
status() {
    mkdir -p "$test_dir/$1"
    printf '%s\n' "$2" | CLAUDE_CONFIG_DIR=$test_dir/$1 sh -c "$capture"
}

with_limits='{"rate_limits": {"five_hour": {"used_percentage": 5}}}'
code=0
output=$(status none "$with_limits") || code=$?
leftover=$(find "$test_dir/none" -name 'claude-usage.json.*')
if [ "$code" -eq 0 ] && [ -z "$output" ] && [ "$(cat "$test_dir/none/claude-usage.json")" = "$with_limits" ] && [ -z "$leftover" ]; then
    pass 'the status line saves usage with rate limits, prints nothing without ponytail, leaves no temporary file'
else
    fail "the status line did not save usage cleanly: $code $output $leftover"
fi

output=$(status none '{"model": {}}')
leftover=$(find "$test_dir/none" -name 'claude-usage.json.*')
if [ "$(cat "$test_dir/none/claude-usage.json")" = "$with_limits" ] && [ -z "$leftover" ]; then
    pass 'input without rate limits leaves the saved usage unchanged'
else
    fail 'input without rate limits changed the saved usage or left a temporary file'
fi

mkdir -p "$test_dir/copy"
printf 'echo pt\n' > "$test_dir/copy/ponytail-statusline.sh"
if [ "$(status copy "$with_limits")" = pt ]; then
    pass "the status line shows ponytail's copy in the config folder"
else
    fail "the status line did not show ponytail's copy in the config folder"
fi

marketplace=$test_dir/clone/plugins/marketplaces/ponytail/hooks
mkdir -p "$marketplace"
printf 'echo clone\n' > "$marketplace/ponytail-statusline.sh"
if [ "$(status clone "$with_limits")" = clone ]; then
    pass "the status line falls back to ponytail's marketplace clone"
else
    fail "the status line did not fall back to ponytail's marketplace clone"
fi

[ "$failures" -eq 0 ] || exit 1
echo 'Claude settings checks passed.'
