#!/bin/sh
# Endpoint port validation and approval canonicalization for the https, http
# and ssh sections, without Docker.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
helper=$sandbox_dir/image/sandbox-policy
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
policy=$test_dir/policy.yaml

printf 'ssh:\n  - Server.Example\n' > "$policy"
bare_hash=$("$helper" hash "$policy")
expected_hash=$(printf 'ssh server.example\n' | sha256sum | cut -d ' ' -f 1)
[ "$bare_hash" = "$expected_hash" ]
printf 'ssh:\n  - server.example:22\n  - SERVER.EXAMPLE\n' > "$policy"
[ "$("$helper" hash "$policy")" = "$bare_hash" ]

for port in 1 2222 65535; do
    printf 'https:\n  - base.example\nssh:\n  - Server.Example:%s\n  - 192.0.2.1:%s\n' "$port" "$port" > "$policy"
    "$helper" check project "$policy"
    "$helper" check base "$policy"
    "$helper" additions "$policy" | grep -Fxq "ssh server.example:$port"
    "$helper" additions "$policy" | grep -Fxq "ssh 192.0.2.1:$port"
    [ "$("$helper" hash "$policy")" != "$bare_hash" ]
done

printf 'ssh:\n  - server.example:2222\n' > "$policy"
custom_hash=$("$helper" hash "$policy")
printf '# reordered and duplicated\nssh:\n  - SERVER.EXAMPLE:2222\n  - server.example:2222\n' > "$policy"
[ "$("$helper" hash "$policy")" = "$custom_hash" ]
printf 'ssh:\n  - server.example:2223\n' > "$policy"
[ "$("$helper" hash "$policy")" != "$custom_hash" ]

for endpoint in server.example:0 server.example:65536 server.example:999999999999999999999 \
    server.example:022 server.example:-1 server.example:+22 server.example:abc \
    server.example: server.example:22:22 :2222; do
    printf 'ssh:\n  - %s\n' "$endpoint" > "$policy"
    if "$helper" check project "$policy" 2>/dev/null || "$helper" hash "$policy" 2>/dev/null; then
        echo "Invalid SSH endpoint accepted: $endpoint" >&2
        exit 1
    fi
done

# https and http take the same NAME:PORT syntax, with their own default port.
for spec in https:443 http:80; do
    section=${spec%:*}
    default=${spec#*:}
    printf '%s:\n  - Web.Example\n' "$section" > "$policy"
    bare=$("$helper" hash "$policy")
    printf '%s:\n  - web.example:%s\n' "$section" "$default" > "$policy"
    [ "$("$helper" hash "$policy")" = "$bare" ]
    printf '%s:\n  - .Web.Example:8443\n  - 192.0.2.1:1\n' "$section" > "$policy"
    "$helper" check project "$policy"
    "$helper" additions "$policy" | grep -Fxq "$section .web.example:8443"
    "$helper" additions "$policy" | grep -Fxq "$section 192.0.2.1:1"
    for endpoint in web.example:0 web.example:65536 web.example:0443 web.example: web.example:1:2; do
        printf '%s:\n  - %s\n' "$section" "$endpoint" > "$policy"
        if "$helper" check project "$policy" 2>/dev/null; then
            echo "Invalid $section endpoint accepted: $endpoint" >&2
            exit 1
        fi
    done
done

# Sections with the same name and port are distinct approvals.
printf 'https:\n  - web.example:8080\n' > "$policy"
https_hash=$("$helper" hash "$policy")
printf 'http:\n  - web.example:8080\n' > "$policy"
[ "$("$helper" hash "$policy")" != "$https_hash" ]

printf 'http_8888:\n  - web.example\n' > "$policy"
if "$helper" check project "$policy" 2> "$test_dir/err"; then
    echo 'The retired http_8888 section was accepted' >&2
    exit 1
fi
grep -Fq 'http_8888 is retired' "$test_dir/err"

# unrestricted_out is a top-level project key that changes the approval. Its
# older name, unrestricted, approves identically, so approvals carry over.
printf 'unrestricted_out: true\n' > "$policy"
"$helper" check project "$policy"
[ "$("$helper" additions "$policy")" = 'unrestricted all-destinations' ]
new_hash=$("$helper" hash "$policy")
printf 'unrestricted: true\n' > "$policy"
[ "$("$helper" hash "$policy")" = "$new_hash" ]
printf 'unrestricted_in: true\n' > "$policy"
if "$helper" check project "$policy" 2>/dev/null; then
    echo 'unrestricted_in was accepted' >&2
    exit 1
fi
printf 'https:\n  - base.example\nunrestricted: true\n' > "$policy"
if "$helper" check base "$policy" 2>/dev/null; then
    echo 'A base policy accepted unrestricted' >&2
    exit 1
fi
printf 'https:\n  - web.example\n' > "$policy"
listed_hash=$("$helper" hash "$policy")
printf 'https:\n  - web.example\nunrestricted: false\n' > "$policy"
[ "$("$helper" hash "$policy")" = "$listed_hash" ]
printf 'https:\n  - web.example\nunrestricted: true\n' > "$policy"
[ "$("$helper" hash "$policy")" != "$listed_hash" ]
# The key ends the preceding section, so entries after it need a header.
printf 'https:\n  - web.example\nunrestricted: true\n  - other.example\n' > "$policy"
if "$helper" check project "$policy" 2>/dev/null; then
    echo 'An entry after unrestricted was accepted without a section' >&2
    exit 1
fi
for value in yes 1 TRUE ''; do
    printf 'unrestricted: %s\n' "$value" > "$policy"
    if "$helper" check project "$policy" 2>/dev/null; then
        echo "unrestricted accepted the value: $value" >&2
        exit 1
    fi
done

echo 'Policy checks passed.'
