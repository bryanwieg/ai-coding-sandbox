#!/bin/sh
# sandbox-ssh-hostkey against a throwaway unprivileged sshd: it prints the
# known_hosts line ssh itself would look up without logging in, reports a
# listed key as known, refuses to offer a replacement for a changed key, and
# fails cleanly without a host key or with an option-like host. It needs
# sshd and ssh-keygen on the host.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
helper=$sandbox_dir/image/sandbox-ssh-hostkey
test_dir=$(mktemp -d)
sshd_pid=
failures=0

cleanup() {
    [ -z "$sshd_pid" ] || kill "$sshd_pid" 2>/dev/null || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

sshd=$(command -v sshd || echo /usr/sbin/sshd)
port=$(awk 'BEGIN { srand(); print 20000 + int(rand() * 20000) }')
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/other_key"
cat > "$test_dir/sshd_config" <<CONF
Port $port
ListenAddress 127.0.0.1
HostKey $test_dir/host_key
PidFile none
UsePAM no
StrictModes no
CONF
"$sshd" -D -e -f "$test_dir/sshd_config" 2> "$test_dir/sshd.log" &
sshd_pid=$!
tries=0
until grep -q 'Server listening' "$test_dir/sshd.log"; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || { cat "$test_dir/sshd.log" >&2; exit 1; }
    sleep 0.1
done

known=$test_dir/known_hosts
: > "$known"
cat > "$test_dir/ssh_config" <<CONF
Host target
    HostName 127.0.0.1
    Port $port
    User nobody
    UserKnownHostsFile $known
CONF
hostkey() { "$helper" -F "$test_dir/ssh_config" "$@"; }
expected="[127.0.0.1]:$port $(cut -d ' ' -f 1,2 "$test_dir/host_key.pub")"

if out=$(hostkey target) && printf '%s\n' "$out" | grep -Fxq "$expected" &&
    printf '%s\n' "$out" | grep -Fq SHA256: && ! grep -q Accepted "$test_dir/sshd.log"; then
    pass 'an unknown host gets its exact known_hosts line and fingerprint, without a login'
else
    fail "unknown host: $out"
fi

printf '%s\n' "$expected" > "$known"
if out=$(hostkey target) && printf '%s\n' "$out" | grep -q 'already listed' &&
    ssh -F "$test_dir/ssh_config" -o BatchMode=yes -o StrictHostKeyChecking=yes target true 2>&1 |
        grep -q 'Permission denied'; then
    pass 'the printed line satisfies strict host key checking'
else
    fail "listed host: $out"
fi

printf '[127.0.0.1]:%s %s\n' "$port" "$(cut -d ' ' -f 1,2 "$test_dir/other_key.pub")" > "$known"
status=0
out=$(hostkey target 2>&1) || status=$?
if [ "$status" = 2 ] && printf '%s\n' "$out" | grep -q '^WARNING: .* differs' &&
    ! printf '%s\n' "$out" | grep -Fxq "$expected"; then
    pass 'a changed key is reported, not offered as a replacement'
else
    fail "changed key: status $status, $out"
fi

status=0
"$helper" -F "$test_dir/ssh_config" -p 1 127.0.0.1 >/dev/null 2>&1 || status=$?
if [ "$status" = 1 ]; then pass 'no host key fails cleanly'; else fail "no host key: status $status"; fi
status=0
"$helper" -oProxyCommand=true >/dev/null 2>&1 || status=$?
if [ "$status" = 64 ]; then pass 'an option-like host is refused'; else fail "option host: status $status"; fi

[ "$failures" -eq 0 ] || { printf '%s ssh host key check(s) failed.\n' "$failures" >&2; exit 1; }
echo 'SSH host key checks passed.'
