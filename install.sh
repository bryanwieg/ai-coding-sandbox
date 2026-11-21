#!/bin/sh
# Installs or updates the sandbox shell functions on this machine, safe to
# rerun:
#
#   curl -fsSL https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/install.sh | sh
#
# Sessions need only the published images and Compose file, so no checkout is
# needed. It downloads shell/sandbox.sh to
# ${XDG_DATA_HOME:-~/.local/share}/ai-coding-sandbox/sandbox.sh and records
# the download URL in source-url next to it, from which agent launches keep
# that copy updated. It creates the shared state volumes when Docker is
# reachable, and sources the functions from the startup file of the shell
# that ran it: ~/.zshrc for zsh, ~/.bashrc for bash, falling back to $SHELL.
# Name another file with: ... | sh -s -- RC_FILE. A startup file that already
# sources the functions, from a checkout for example, is pointed at the
# downloaded copy.
#
# SANDBOX_FUNCTIONS_DIR and SANDBOX_FUNCTIONS_URL override the folder and the
# download.
set -eu

dir=${SANDBOX_FUNCTIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-coding-sandbox}
url=${SANDBOX_FUNCTIONS_URL:-https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/sandbox/shell/sandbox.sh}
functions=$dir/sandbox.sh
marker='# ai-coding-sandbox shell functions'
line=". \"$functions\""

if [ "$#" -gt 1 ]; then
    echo 'Usage: install.sh [RC_FILE]' >&2
    exit 2
fi
command -v curl >/dev/null || { echo 'install.sh: curl is required.' >&2; exit 1; }

# Piped from curl, this runs as a child of the interactive shell, which may
# differ from the login shell in $SHELL.
if [ "$#" -eq 1 ]; then
    rc=$1
else
    shell=$(ps -o comm= -p "$PPID" 2>/dev/null) || shell=
    shell=${shell#-}
    shell=${shell##*/}
    case "$shell" in
        zsh|bash) ;;
        *) shell=${SHELL##*/} ;;
    esac
    case "$shell" in
        zsh) rc=${ZDOTDIR:-$HOME}/.zshrc ;;
        bash) rc=$HOME/.bashrc ;;
        *) echo "install.sh: unsupported shell ${shell:-unknown}; name the startup file: ... | sh -s -- RC_FILE" >&2; exit 2 ;;
    esac
fi

# Download next to the target and swap it in whole, so a failed or partial
# download never replaces a working copy.
mkdir -p "$dir"
download=$(mktemp "$dir/.sandbox.sh.XXXXXX")
record=
trap 'rm -f "$download" "$record"' EXIT HUP INT TERM
curl -fsSL "$url" -o "$download"
if ! grep -q '^sandbox() {$' "$download"; then
    echo "install.sh: $url is not the sandbox shell functions." >&2
    exit 1
fi
chmod 0644 "$download"
mv -f "$download" "$functions"
# Record the source, so the copy's agent launches update it from there.
record=$(mktemp "$dir/.source-url.XXXXXX")
printf '%s\n' "$url" > "$record"
chmod 0644 "$record"
mv -f "$record" "$dir/source-url"
echo "Installed the sandbox shell functions in $functions."

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    for volume in claude-state codex-state trust; do
        docker volume create "ai-coding-sandbox-$volume" >/dev/null
    done
    echo 'The shared state volumes are ready.'
else
    echo 'Docker is not reachable; create the state volumes later by rerunning this script.' >&2
fi

# Add the marked source line once, or repoint the one after an existing
# marker; the rewrite keeps the file itself, so links and modes stay.
if [ -f "$rc" ] && grep -Fxq "$marker" "$rc"; then
    if ! awk -v marker="$marker" -v line="$line" '
        previous == marker && $0 != line { exit 1 }
        { previous = $0 }' "$rc"; then
        updated=$(mktemp)
        awk -v marker="$marker" -v line="$line" '
            previous == marker { $0 = line }
            { previous = $0; print }' "$rc" > "$updated"
        cat "$updated" > "$rc"
        rm -f "$updated"
        echo "Pointed $rc at $functions."
    fi
else
    printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
    echo "Added the sandbox shell functions to $rc."
fi
echo "Open a new terminal, or load them into this one with:"
echo "  $line"
