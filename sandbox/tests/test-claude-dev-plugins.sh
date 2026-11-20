#!/bin/sh
# Claude's development plugin repository: synchronized at launch without ever
# discarding local work, and loaded by the agent launcher from its clone.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
init_script="$root_dir/claude/init.d/40-dev-plugins"
agent_script="$root_dir/claude/agent"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# GitHub URLs resolve to local bare repositories; no network is used.
GIT_CONFIG_GLOBAL="$test_dir/gitconfig"
GIT_CONFIG_NOSYSTEM=1
CLAUDE_CONFIG_DIR="$test_dir/state"
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM CLAUDE_CONFIG_DIR
git config --global url."$test_dir/remote/".insteadOf https://github.com/
git config --global user.name 'Test'
git config --global user.email 'test@example.invalid'
git config --global init.defaultBranch main

mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/claude" <<'EOF'
#!/bin/sh
for argument in "$@"; do printf '%s\n' "$argument"; done
EOF
chmod 0755 "$test_dir/bin/claude"
PATH="$test_dir/bin:$PATH"

remote="$test_dir/remote/owner/plugins.git"
work="$test_dir/work"
clone="$CLAUDE_CONFIG_DIR/dev-plugins/owner/plugins"
git init --quiet --bare "$remote"
git clone --quiet "$remote" "$work" 2>/dev/null
mkdir -p "$work/.claude-plugin" "$work/plugins/one" "$work/plugins/two"
cat > "$work/.claude-plugin/marketplace.json" <<'EOF'
{"name": "plugins", "plugins": [
  {"name": "one", "source": "./plugins/one"},
  {"name": "two", "source": "./plugins/two"},
  {"name": "outside", "source": "./plugins/../../escape"},
  {"name": "remote", "source": {"source": "github", "repo": "other/repo"}},
  {"name": "missing", "source": "./plugins/missing"}
]}
EOF
touch "$work/plugins/one/.keep" "$work/plugins/two/.keep"
git -C "$work" add -A
git -C "$work" commit --quiet -m initial
git -C "$work" push --quiet origin main 2>/dev/null

advance_remote() {
    printf '%s\n' "$1" > "$work/plugins/one/version"
    git -C "$work" add -A
    git -C "$work" commit --quiet -m "$1"
    git -C "$work" push --quiet origin main 2>/dev/null
}

# Stores a repository name the way sandbox-dev-plugins does, unvalidated.
use_repo() {
    mkdir -p "$CLAUDE_CONFIG_DIR/sandbox"
    printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/sandbox/dev-plugin-repo"
}

# Without a repository, launch does nothing and loads no plugins.
"$init_script"
[ ! -e "$CLAUDE_CONFIG_DIR/dev-plugins" ]
[ "$("$agent_script" --resume)" = "$(printf '%s\n' --dangerously-skip-permissions --resume)" ]

# A malformed value is reported and ignored without failing the launch.
use_repo '../owner/plugins'
"$init_script" 2> "$test_dir/err"
grep -Fq 'use owner/repository' "$test_dir/err"
[ ! -e "$CLAUDE_CONFIG_DIR/dev-plugins" ]
[ "$("$agent_script")" = --dangerously-skip-permissions ]

# The first launch clones; the agent loads only local, existing plugins.
use_repo owner/plugins
"$init_script" 2>/dev/null
[ -f "$clone/plugins/one/.keep" ]
"$agent_script" --resume > "$test_dir/args" 2> "$test_dir/err"
[ "$(cat "$test_dir/args")" = "$(printf '%s\n' --dangerously-skip-permissions \
    --plugin-dir "$clone/plugins/two" --plugin-dir "$clone/plugins/one" --resume)" ]
grep -Fq 'Skipping unsupported plugin source: ./plugins/../../escape' "$test_dir/err"
grep -Fq 'Skipping missing plugin directory: ./plugins/missing' "$test_dir/err"

# A clean clone fast-forwards to the remote.
advance_remote second
"$init_script"
[ "$(cat "$clone/plugins/one/version")" = second ]

# Uncommitted edits, including new files, block the update and are preserved.
advance_remote third
printf 'local edit\n' > "$clone/plugins/two/draft"
"$init_script" 2> "$test_dir/err"
grep -Fq 'local changes' "$test_dir/err"
[ "$(cat "$clone/plugins/one/version")" = second ]
[ -f "$clone/plugins/two/draft" ]

# Unpushed commits are reported and kept; diverged history is never merged.
git -C "$clone" add -A
git -C "$clone" commit --quiet -m 'local work'
"$init_script" 2> "$test_dir/err"
grep -Fq 'diverged' "$test_dir/err"
git -C "$clone" log --format=%s -1 | grep -Fxq 'local work'
git -C "$clone" rebase --quiet '@{upstream}'
"$init_script" 2> "$test_dir/err"
grep -Fq 'unpushed commits' "$test_dir/err"
[ "$(cat "$clone/plugins/one/version")" = third ]

# An unreachable remote keeps the existing clone and still starts the agent.
mv "$remote" "$remote.offline"
"$init_script" 2> "$test_dir/err"
grep -Fq 'Unable to fetch' "$test_dir/err"
"$agent_script" 2>/dev/null | grep -Fxq -- "$clone/plugins/one"

# A failed first clone leaves nothing behind, so the next launch retries.
use_repo owner/absent
"$init_script" 2> "$test_dir/err"
grep -Fq 'Unable to clone' "$test_dir/err"
[ ! -e "$CLAUDE_CONFIG_DIR/dev-plugins/owner/absent" ]
[ "$("$agent_script")" = --dangerously-skip-permissions ]

# sandbox-dev-plugins validates, stores, shows and removes the repository.
dev_plugins="$root_dir/claude/sandbox-dev-plugins"
"$dev_plugins" unset >/dev/null
"$dev_plugins" show | grep -Fq 'No development plugin repository'
if "$dev_plugins" set '../owner/plugins' 2>/dev/null; then exit 1; fi
[ ! -e "$CLAUDE_CONFIG_DIR/sandbox/dev-plugin-repo" ]
"$dev_plugins" set owner/plugins >/dev/null
[ "$("$dev_plugins" show)" = owner/plugins ]
mv "$remote.offline" "$remote"
"$init_script" 2>/dev/null
"$agent_script" | grep -Fxq -- "$clone/plugins/one"
"$dev_plugins" unset >/dev/null
[ "$("$agent_script")" = --dangerously-skip-permissions ]
[ -d "$clone/.git" ]

echo 'Claude development plugin tests passed.'
