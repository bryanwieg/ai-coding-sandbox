#!/bin/sh
# Host test for the plugin synchronization startup hooks of both agents, with
# a stubbed agent CLI: marketplaces are added and plugins installed in manifest
# order, the checksum is recorded only after every entry succeeds, an unchanged
# manifest updates Claude's plugins and does no Codex work, and Codex waits
# until it is signed in.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
failures=0
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

manifest=$test_dir/plugins.txt
calls=$test_dir/calls
mkdir -p "$test_dir/stubs"
cat > "$manifest" <<'EOF'
# comment

marketplace owner/market
one@market
two@market
EOF

# The stub records each call and fails any call naming "two" when told to.
for agent in claude codex; do
    cat > "$test_dir/stubs/$agent" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$calls'
case "\$*" in *two*) [ -z "\${FAIL_TWO:-}" ] ;; esac
EOF
    chmod 0755 "$test_dir/stubs/$agent"
done

# run AGENT: runs the agent's sync hook against the test manifest and state.
run() {
    agent=$1
    case "$agent" in
        claude) hook=$sandbox_dir/claude/init.d/30-plugins; var=CLAUDE_CONFIG_DIR ;;
        codex) hook=$sandbox_dir/codex/init.d/20-plugins; var=CODEX_HOME ;;
    esac
    sed "s|/usr/local/share/$agent/plugins.txt|$manifest|" "$hook" > "$test_dir/hook"
    : > "$calls"
    env "$var=$test_dir/state-$agent" PATH="$test_dir/stubs:$PATH" sh "$test_dir/hook" >/dev/null 2>&1
}

for agent in claude codex; do
    state=$test_dir/state-$agent
    mkdir -p "$state"
    case "$agent" in
        claude) expected='plugin marketplace add owner/market
plugin install one@market
plugin install two@market' ;;
        codex) expected='plugin marketplace add owner/market
plugin add one@market
plugin add two@market' ;;
    esac

    if [ "$agent" = codex ]; then
        run codex
        if [ ! -s "$calls" ] && [ ! -e "$state/plugins.manifest.sha256" ]; then
            pass 'codex waits for sign-in before synchronizing'
        else
            fail 'codex synchronized while signed out'
        fi
        : > "$state/auth.json"
    fi

    FAIL_TWO=1 run "$agent"
    if [ "$(cat "$calls")" = "$expected" ] && [ ! -e "$state/plugins.manifest.sha256" ]; then
        pass "$agent continues past a failed entry and records no checksum"
    else
        fail "$agent mishandled a failed entry"
    fi

    run "$agent"
    if [ "$(cat "$calls")" = "$expected" ] && [ -s "$state/plugins.manifest.sha256" ]; then
        pass "$agent adds marketplaces and installs plugins in order"
    else
        fail "$agent did not synchronize the manifest in order"
    fi

    if [ "$agent" = claude ]; then
        updates='plugin marketplace update
plugin update one@market
plugin update two@market'
        if FAIL_TWO=1 run claude && [ "$(cat "$calls")" = "$updates" ]; then
            pass 'claude updates an unchanged manifest and survives a failed update'
        else
            fail 'claude did not update an unchanged manifest'
        fi
    else
        run "$agent"
        if [ ! -s "$calls" ]; then
            pass "$agent skips an unchanged manifest"
        else
            fail "$agent synchronized an unchanged manifest"
        fi
    fi
done

# In the other agent's session, each agent syncs only once it is signed in,
# and says nothing while it waits.
for agent in claude codex; do
    case "$agent" in
        claude) other=codex; credentials=.credentials.json ;;
        codex) other=claude; credentials=auth.json ;;
    esac
    state=$test_dir/other-$agent
    mkdir -p "$state"
    case "$agent" in
        claude) hook=$sandbox_dir/claude/init.d/30-plugins; var=CLAUDE_CONFIG_DIR ;;
        codex) hook=$sandbox_dir/codex/init.d/20-plugins; var=CODEX_HOME ;;
    esac
    sed "s|/usr/local/share/$agent/plugins.txt|$manifest|" "$hook" > "$test_dir/hook"
    : > "$calls"
    output=$(env "$var=$state" SANDBOX_AGENT="$other" PATH="$test_dir/stubs:$PATH" sh "$test_dir/hook" 2>&1)
    if [ ! -s "$calls" ] && [ -z "$output" ]; then
        pass "$agent waits quietly for sign-in in a $other session"
    else
        fail "$agent synchronized or spoke while signed out in a $other session: $output"
    fi
    : > "$state/$credentials"
    env "$var=$state" SANDBOX_AGENT="$other" PATH="$test_dir/stubs:$PATH" sh "$test_dir/hook" >/dev/null 2>&1
    if [ -s "$calls" ] && [ -s "$state/plugins.manifest.sha256" ]; then
        pass "$agent synchronizes in a $other session once signed in"
    else
        fail "$agent did not synchronize in a $other session once signed in"
    fi
done

# The shipped Claude manifest enables the language server plugins, and the
# sync installs them.
manifest=$sandbox_dir/claude/plugins.txt
mkdir -p "$test_dir/state-shipped"
: > "$calls"
sed "s|/usr/local/share/claude/plugins.txt|$manifest|" "$sandbox_dir/claude/init.d/30-plugins" > "$test_dir/hook"
if env CLAUDE_CONFIG_DIR="$test_dir/state-shipped" PATH="$test_dir/stubs:$PATH" sh "$test_dir/hook" >/dev/null 2>&1 \
    && grep -qx 'plugin install gopls-lsp@claude-plugins-official' "$calls" \
    && grep -qx 'plugin install pyright-lsp@claude-plugins-official' "$calls" \
    && [ -s "$test_dir/state-shipped/plugins.manifest.sha256" ]; then
    pass 'the shipped claude manifest enables gopls-lsp and pyright-lsp'
else
    fail 'the shipped claude manifest does not enable gopls-lsp and pyright-lsp'
fi

[ "$failures" -eq 0 ] || exit 1
echo 'Plugin synchronization checks passed.'
