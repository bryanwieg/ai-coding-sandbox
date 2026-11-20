#!/bin/sh
# Run against both agent images built with compose.dev.yaml, or image tags
# supplied as arguments. No remote host or network access is needed.
set -eu

if [ "$#" -eq 0 ]; then
    set -- ai-coding-sandbox-dev:claude ai-coding-sandbox-dev:codex
fi

for image do
    docker run --rm -i --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges:true \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        "$image" sh -s <<'EOF'
set -eu
test "$(id -u)" -ne 0
test ! -w "$HOME"
test ! -e "$HOME/.cache"
test "${POWERSHELL_TELEMETRY_OPTOUT}" = 1
test "${POWERSHELL_UPDATECHECK}" = Off
parent_xdg_config_home=${XDG_CONFIG_HOME-}
# Compare with the package version supplied by the pinned SDK image, so
# Dependabot can update the image without a second version pin drifting.
set -- /usr/share/powershell/.store/powershell.linux.x64/*
test "$#" -eq 1
test -d "$1"
version=$(basename "$1")
test ! -d /usr/share/dotnet/sdk
actual=$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
test "$actual" = "$version"
printf 'ok   PowerShell %s starts as %s with read-only HOME and noexec /tmp\n' "$actual" "$(id -un)"
# A second launch reuses the temporary directories without touching HOME.
pwsh -NoProfile -Command '
    foreach ($name in "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME") {
        $path = [Environment]::GetEnvironmentVariable($name)
        if (!$path.StartsWith("/tmp/")) { throw "Unexpected ${name}: $path" }
        [IO.File]::WriteAllText((Join-Path $path "startup-test"), "ok")
    }
'
test ! -e "$HOME/.cache"
test -z "${XDG_CACHE_HOME:-}${XDG_DATA_HOME:-}"
test "${XDG_CONFIG_HOME-}" = "$parent_xdg_config_home"
echo 'ok   PowerShell XDG state is writable and scoped to its process'
EOF
done
