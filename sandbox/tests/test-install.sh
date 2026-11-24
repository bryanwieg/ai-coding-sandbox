#!/bin/sh
# The curl installer: piped into sh from zsh or bash, it downloads the shell
# functions, creates the state volumes, and sources the functions once from
# the startup file of the shell that ran it, not the login shell; a rerun
# replaces the copy and repoints a startup file that sourced a checkout; it
# records the download URL in source-url, which follows a rerun's URL; a
# failed or wrong download keeps the working copy; it works without Docker,
# takes a named startup file, and refuses an unknown shell.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install="$root_dir/../install.sh"
# Stubs must be executable: /tmp is noexec in sandbox sessions.
mkdir -p "$root_dir/tests/.tmp"
test_dir=$(mktemp -d "$root_dir/tests/.tmp/test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

cp "$root_dir/shell/sandbox.sh" "$test_dir/sandbox.sh"
export SANDBOX_FUNCTIONS_URL="file://$test_dir/sandbox.sh"
unset ZDOTDIR XDG_DATA_HOME SANDBOX_FUNCTIONS_DIR

# A stub docker logs created volumes; SANDBOX_TEST_NO_DOCKER makes it
# unreachable.
mkdir -p "$test_dir/bin"
cat > "$test_dir/bin/docker" <<'STUB'
#!/bin/sh
[ -z "${SANDBOX_TEST_NO_DOCKER:-}" ] || exit 1
case "$1 ${2:-}" in
    'volume create') printf '%s\n' "$3" >> "$HOME/volumes" ;;
esac
STUB
chmod 0755 "$test_dir/bin/docker"
PATH="$test_dir/bin:$PATH"

marker='# ai-coding-sandbox shell functions'
for shell in zsh bash; do
    command -v "$shell" >/dev/null || { echo "skipping $shell: not installed"; continue; }
    home=$test_dir/home-$shell
    mkdir -p "$home"
    case "$shell" in zsh) rc=.zshrc login=/bin/bash ;; *) rc=.bashrc login=/usr/bin/zsh ;; esac
    HOME=$home SHELL=$login "$shell" -c "cat '$install' | sh" > "$test_dir/output"
    functions=$home/.local/share/ai-coding-sandbox/sandbox.sh
    cmp -s "$functions" "$test_dir/sandbox.sh"
    [ "$(cat "${functions%/*}/source-url")" = "$SANDBOX_FUNCTIONS_URL" ]
    [ "$(grep -cFx "$marker" "$home/$rc")" -eq 1 ]
    grep -Fxq ". \"$functions\"" "$home/$rc"
    [ ! -e "$home/.zshrc" ] || [ "$rc" = .zshrc ]
    [ ! -e "$home/.bashrc" ] || [ "$rc" = .bashrc ]
    grep -Fxq "  . \"$functions\"" "$test_dir/output"
    [ "$(sort "$home/volumes" | tr '\n' ' ')" = 'ai-coding-sandbox-claude-state ai-coding-sandbox-codex-state ai-coding-sandbox-trust ' ]
    HOME=$home SHELL=$login "$shell" -c ". '$home/$rc'; type sandbox-prune" >/dev/null
done

# A rerun replaces the copy and adds nothing; a startup file that sourced a
# checkout is repointed, keeping its other lines.
home=$test_dir/home-update
mkdir -p "$home"
printf '# mine\n%s\n. "/old/checkout/sandbox/shell/sandbox.sh"\n# after\n' "$marker" > "$home/.bashrc"
HOME=$home bash -c "cat '$install' | sh" > "$test_dir/output"
grep -Fq "Pointed $home/.bashrc" "$test_dir/output"
functions=$home/.local/share/ai-coding-sandbox/sandbox.sh
[ "$(cat "$home/.bashrc")" = "$(printf '# mine\n%s\n. "%s"\n# after' "$marker" "$functions")" ]
[ "$(cat "${functions%/*}/source-url")" = "$SANDBOX_FUNCTIONS_URL" ]
printf '# updated\n' >> "$test_dir/sandbox.sh"
HOME=$home bash -c "cat '$install' | sh" > "$test_dir/output"
cmp -s "$functions" "$test_dir/sandbox.sh"
if grep -Fq Pointed "$test_dir/output"; then exit 1; fi
[ "$(grep -cFx "$marker" "$home/.bashrc")" -eq 1 ]
[ "$(cat "${functions%/*}/source-url")" = "$SANDBOX_FUNCTIONS_URL" ]

# A rerun from another source, such as a fork, records that source.
cp "$test_dir/sandbox.sh" "$test_dir/fork.sh"
printf '# fork\n' >> "$test_dir/fork.sh"
HOME=$home SANDBOX_FUNCTIONS_URL="file://$test_dir/fork.sh" bash -c "cat '$install' | sh" >/dev/null
cmp -s "$functions" "$test_dir/fork.sh"
[ "$(cat "${functions%/*}/source-url")" = "file://$test_dir/fork.sh" ]

# A failed or wrong download keeps the working copy and its source record,
# and leaves no temp file.
cp "$functions" "$test_dir/working"
for bad in missing wrong; do
    printf 'echo not the functions\n' > "$test_dir/wrong"
    if HOME=$home SANDBOX_FUNCTIONS_URL="file://$test_dir/$bad" bash -c "cat '$install' | sh" >/dev/null 2>"$test_dir/err"; then
        echo "install.sh accepted a $bad download" >&2
        exit 1
    fi
    cmp -s "$functions" "$test_dir/working"
    [ "$(cat "${functions%/*}/source-url")" = "file://$test_dir/fork.sh" ]
    [ "$(ls -A "$home/.local/share/ai-coding-sandbox")" = "$(printf 'sandbox.sh\nsource-url')" ]
done
grep -Fq 'is not the sandbox shell functions' "$test_dir/err"

# Without Docker it still installs; a named file wins over the shell.
home=$test_dir/home-named
mkdir -p "$home"
HOME=$home SANDBOX_TEST_NO_DOCKER=1 bash -c "cat '$install' | sh -s -- '$home/custom-rc'" >/dev/null 2>"$test_dir/err"
grep -Fq 'Docker is not reachable' "$test_dir/err"
grep -Fxq "$marker" "$home/custom-rc"
[ "$(cat "$home/.local/share/ai-coding-sandbox/source-url")" = "$SANDBOX_FUNCTIONS_URL" ]
[ ! -e "$home/.bashrc" ] && [ ! -e "$home/volumes" ]

# An unknown shell, from neither the parent nor $SHELL, is refused before
# anything is written.
home=$test_dir/home-fish
mkdir -p "$home"
result=0
HOME=$home SHELL=/usr/bin/fish sh "$install" >/dev/null 2>"$test_dir/err" || result=$?
[ "$result" -eq 2 ]
grep -Fq 'unsupported shell' "$test_dir/err"
[ -z "$(ls -A "$home")" ]

echo 'Installer tests passed.'
