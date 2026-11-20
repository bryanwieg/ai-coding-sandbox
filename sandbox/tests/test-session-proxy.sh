#!/bin/sh
# Runtime test for the session-proxy image on an internal network, with a fake
# upstream instead of the Internet: base names are allowed and others denied;
# project additions apply only once approved for that project folder; comment
# edits keep the approval and new names lose it; hosts pins route to their
# address; https, http and ssh entries allow only their own port and method;
# an approved unrestricted policy allows every destination;
# invalid policies fall back to the base policy; and the proxy cannot
# write its trust store; it records the project policy hash it applied; it
# reloads an approved change in place, keeping its connections; and it
# stops once no session holds a connection and no launch hold is fresh.
set -eu

sandbox_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=ai-coding-sandbox-session-proxy:test
prefix=sandbox-proxy-test-$$
network=$prefix-net
trust=$prefix-trust
proxy=$prefix-proxy
folder=/projects/demo
test_dir=$(mktemp -d)
policy=$test_dir/egress-policy.yaml
failures=0

cleanup() {
    docker ps -aq --filter "label=$prefix" | xargs -r docker rm -f -v >/dev/null 2>&1 || :
    docker volume rm "$trust" >/dev/null 2>&1 || :
    docker network rm "$network" >/dev/null 2>&1 || :
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

docker build --quiet --target session-proxy --tag "$image" "$sandbox_dir" >/dev/null
docker network create --internal --label "$prefix" "$network" >/dev/null
# Like the real trust volume, created empty and root-owned before first use.
docker volume create "$trust" >/dev/null
docker run -d --name "$prefix-upstream" --label "$prefix" --network "$network" busybox:1.37 \
    sh -c 'mkdir /w && echo pinned-ok > /w/index.html &&
        httpd -p 22 -h /w && httpd -p 2222 -h /w && httpd -p 2223 -h /w &&
        httpd -p 80 -h /w && httpd -p 8443 -h /w && httpd -p 8888 -h /w &&
        httpd -f -p 443 -h /w' >/dev/null
upstream=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$prefix-upstream")
: > "$policy"

# start_proxy [FOLDER [OPTIONS...]]: (re)starts the proxy for project FOLDER
# (default: $folder), with extra docker run OPTIONS.
start_proxy() {
    proxy_folder=${1:-$folder}
    [ "$#" -eq 0 ] || shift
    docker rm -f -v "$proxy" >/dev/null 2>&1 || :
    docker run -d --name "$proxy" --label "$prefix" --network "$network" --network-alias egress-proxy \
        --user 13:13 --read-only --cap-drop ALL --security-opt no-new-privileges \
        --tmpfs /run --tmpfs /tmp:mode=1777 \
        --tmpfs /var/log/squid:uid=13,gid=13,mode=0755 --tmpfs /var/spool/squid:uid=13,gid=13,mode=0755 \
        -v "$policy:/etc/squid/project-policy.yaml:ro" -v "$trust:/trust:ro" \
        -e "HOST_PWD=$proxy_folder" "$@" "$image" >/dev/null
    tries=0
    until docker exec "$proxy" sh -c 'test -r /tmp/squid.pid && kill -0 "$(cat /tmp/squid.pid)"' 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            docker logs "$proxy" 2>&1 | tail -5 >&2
            return 1
        fi
        sleep 1
    done
}

# Runs the trust command for project folder $2 (default: $folder) with answer $1.
trust_cmd() {
    answer=$1
    project_folder=${2:-$folder}
    if [ "$#" -ge 2 ]; then shift 2; else shift; fi
    printf '%s\n' "$answer" | docker run --rm -i --label "$prefix" --network none \
        --user 0:0 --read-only --cap-drop ALL --security-opt no-new-privileges \
        -v "$policy:/etc/squid/project-policy.yaml:ro" -v "$trust:/trust" \
        -e "HOST_PWD=$project_folder" --entrypoint sandbox-trust "$image" "$@" 2>&1
}

# Prints the proxy's status line for CONNECT to $1:${2:-443}.
status() {
    docker run --rm --label "$prefix" --network "$network" busybox:1.37 sh -c \
        "printf 'CONNECT $1:${2:-443} HTTP/1.1\r\nHost: $1:${2:-443}\r\n\r\n' | nc -w 5 egress-proxy 3128 | head -n 1" |
        tr -d '\r' | cut -d ' ' -f 2
}

# Prints the proxy's status line for a plain HTTP GET of http://$1:${2:-80}/.
http_status() {
    docker run --rm --label "$prefix" --network "$network" busybox:1.37 sh -c \
        "(printf 'GET http://$1:${2:-80}/ HTTP/1.0\r\n\r\n'; sleep 2) | nc -w 5 egress-proxy 3128 | head -n 1" |
        tr -d '\r' | cut -d ' ' -f 2
}

expect_http() {
    actual=$(http_status "$2" "${4:-80}")
    if [ "$actual" = "$1" ]; then pass "$3"; else fail "$3 (got status ${actual:-none})"; fi
}

# Fetches / from $1 through a CONNECT tunnel.
tunnel() {
    docker run --rm --label "$prefix" --network "$network" busybox:1.37 sh -c \
        "(printf 'CONNECT $1:443 HTTP/1.1\r\nHost: $1:443\r\n\r\n'; sleep 1; printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2) | nc egress-proxy 3128" |
        tail -n 1
}

# Passes $1 when the remaining arguments succeed.
check() {
    description=$1
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
logged() { docker logs "$proxy" 2>&1 | grep -q -- "$1"; }
trust_says() { trust_cmd "$1" | grep -q -- "$2"; }

expect_status() {
    actual=$(status "$2" "${4:-443}")
    if [ "$actual" = "$1" ]; then pass "$3"; else fail "$3 (got status ${actual:-none})"; fi
}
allowed() {
    actual=$(status "$1")
    if [ -n "$actual" ] && [ "$actual" != 403 ]; then pass "$2"; else fail "$2 (got status ${actual:-none})"; fi
}

start_proxy
allowed api.anthropic.com 'a base name is allowed'
allowed registry-1.docker.io 'Docker Hub is in the base policy'
allowed api.githubcopilot.com 'GitHub MCP is in the base policy'
for domain in anthropic.com claude.ai claude.com claudeusercontent.com githubcopilot.com ghcr.io lscr.io gitlab.com; do
    allowed "$domain" "$domain is allowed"
    allowed "docs.$domain" "subdomains of $domain are allowed"
    expect_status 403 "$domain.example.org" "lookalikes of $domain are denied"
done
allowed proxy.golang.org 'the Go module proxy is in the base policy'
allowed sum.golang.org 'the Go checksum database is in the base policy'
expect_status 403 golang.org 'only the Go module hosts of golang.org are allowed'
allowed github-cloud.s3.amazonaws.com "GitHub's LFS storage is in the base policy"
expect_status 403 other.s3.amazonaws.com "only GitHub's bucket of S3 is allowed"
for host in archive.ubuntu.com security.ubuntu.com keyserver.ubuntu.com; do
    allowed "$host" "$host is in the base policy"
done
expect_status 403 ubuntu.com 'only the listed Ubuntu hosts are allowed'
allowed storage.googleapis.com 'Google Cloud Storage is in the base policy'
allowed pypi.org 'the PyPI index is in the base policy'
allowed files.pythonhosted.org 'PyPI package files are in the base policy'
expect_status 403 upload.pypi.org 'only the PyPI index host of pypi.org is allowed'
expect_status 403 www.googleapis.com 'only the storage host of googleapis.com is allowed'
for host in marketplace.visualstudio.com ms-python.gallery.vsassets.io \
    ms-python.gallerycdn.vsassets.io main.vscode-cdn.net; do
    allowed "$host" "the VS Code Marketplace host $host is allowed"
done
expect_status 403 visualstudio.com 'only the Marketplace host of visualstudio.com is allowed'
for host in docs.python.org developer.mozilla.org pkg.go.dev man.freebsd.org \
    docs.vyos.io docs.fedoraproject.org komo.do docs.docker.com www.rfc-editor.org stackoverflow.com unix.stackexchange.com codeberg.org; do
    allowed "$host" "the documentation or source host $host is allowed"
done
expect_status 403 example.readthedocs.io 'arbitrary Read the Docs subdomains are denied'
expect_status 403 en.wikipedia.org 'anonymously editable Wikipedia is denied'
actual=$(status gitlab.com 22)
if [ -n "$actual" ] && [ "$actual" != 403 ]; then
    pass 'SSH to gitlab.com is in the base policy'
else
    fail "SSH to gitlab.com is in the base policy (got status ${actual:-none})"
fi
expect_status 403 gitlab.com 'base SSH allows only port 22' 2222
expect_status 403 docs.gitlab.com 'base SSH names do not cover subdomains' 22
expect_status 403 example.org 'a name outside the policy is denied'
applied() { [ "$(docker exec "$proxy" cat /tmp/applied-policy)" = "$1" ]; }
check 'the proxy records that it applied the base policy only' applied ''

cat > "$policy" <<EOF
https:
  - fake.example
hosts:
  fake.example: $upstream
EOF
start_proxy
expect_status 403 fake.example 'an unapproved addition is not applied'
check 'the proxy reports the unapproved policy' logged 'not approved'

if trust_cmd n | grep -q 'Not approved' && start_proxy && [ "$(status fake.example)" = 403 ]; then
    pass 'declining leaves the addition unapproved'
else
    fail 'declining approved the addition'
fi
trust_cmd y | grep -q 'Approved\.' || fail 'approval failed'
start_proxy
if [ "$(tunnel fake.example)" = pinned-ok ]; then
    pass 'an approved addition applies and its hosts pin routes to the pinned address'
else
    fail 'the approved addition or its pin did not apply'
fi
approved_hash=$(docker exec "$proxy" sandbox-policy hash /etc/squid/project-policy.yaml)
check 'the proxy records the hash of the project policy it applied' applied "$approved_hash"

start_proxy /projects/other
expect_status 403 fake.example 'approval is tied to the project folder'

printf '# a comment\n' >> "$policy"
start_proxy
expect_status 200 fake.example 'a comment-only edit keeps the approval'
check 'the trust command sees no change after a comment edit' trust_says y 'already approved'

printf 'ssh:\n  - new.example\n' >> "$policy"
start_proxy
expect_status 403 fake.example 'a new name withdraws the approval until it is approved again'
check 'the proxy records no project hash while the change is unapproved' applied ''
if trust_cmd n | grep -q '+ ssh new.example'; then
    pass 'the trust command shows what changed since the last approval'
else
    fail 'the trust command did not show the change'
fi

printf 'bogus line\n' >> "$policy"
start_proxy
if docker logs "$proxy" 2>&1 | grep -q 'invalid; using the base policy only' &&
    [ "$(status fake.example)" = 403 ] && [ "$(status api.anthropic.com)" != 403 ]; then
    pass 'an invalid project policy falls back to the base policy'
else
    fail 'an invalid project policy was not handled'
fi
check 'the trust command refuses an invalid policy' trust_says y 'Fix the project egress policy'
if trust_cmd '' "$folder" --yes > "$test_dir/invalid"; then
    fail 'automatic approval accepted an invalid policy'
else
    pass 'automatic approval refuses an invalid policy'
fi

cat > "$policy" <<EOF
ssh:
  - standard.example
  - custom.example:2222
  - other.example:2223
  - $upstream:2222
hosts:
  standard.example: $upstream
  custom.example: $upstream
  other.example: $upstream
  unlisted.example: $upstream
EOF
start_proxy
expect_status 403 custom.example 'an unapproved SSH endpoint is denied' 2222
trust_cmd '' "$folder" --yes | grep -q 'Approved\.' || fail 'automatic SSH endpoint approval failed'
start_proxy
expect_status 200 standard.example 'a bare SSH name allows port 22' 22
expect_status 200 custom.example 'an approved custom SSH port is allowed' 2222
expect_status 200 other.example 'a second SSH endpoint allows its own port' 2223
expect_status 200 "$upstream" 'an IPv4 SSH endpoint allows its approved port' 2222
expect_status 403 custom.example 'a custom SSH entry does not implicitly allow port 22' 22
expect_status 403 standard.example 'a bare SSH name does not inherit a custom port' 2222
expect_status 403 custom.example 'SSH hosts do not inherit each others ports' 2223
expect_status 403 unlisted.example 'an unlisted host cannot use an approved SSH port' 2222
expect_status 403 custom.example 'SSH approval does not grant HTTPS' 443
sed 's/custom.example:2222/custom.example:2223/' "$policy" > "$test_dir/changed"
cat "$test_dir/changed" > "$policy"
start_proxy
expect_status 403 custom.example 'changing an SSH port withdraws approval' 2223
expect_status 403 standard.example 'a port change withdraws the whole project approval' 22
check 'the trust command displays the changed port' trust_says n '+ ssh custom.example:2223'

cat > "$policy" <<EOF
https:
  - tls.example:8443
http:
  - plain.example
  - alt.example:8888
hosts:
  tls.example: $upstream
  plain.example: $upstream
  alt.example: $upstream
EOF
trust_cmd '' "$folder" --yes | grep -q 'Approved\.' || fail 'automatic web endpoint approval failed'
start_proxy
expect_status 200 tls.example 'an https entry allows CONNECT to its custom port' 8443
expect_status 403 tls.example 'a custom https port does not implicitly allow 443' 443
expect_http 200 plain.example 'a bare http name allows plain HTTP on port 80'
expect_http 403 plain.example 'a bare http name does not inherit a custom port' 8888
expect_http 200 alt.example 'an http entry allows plain HTTP on its custom port' 8888
expect_http 403 alt.example 'a custom http port does not implicitly allow port 80'
expect_status 403 alt.example 'http approval does not grant CONNECT' 8888
expect_http 403 tls.example 'https approval does not grant plain HTTP' 8443
expect_http 403 api.anthropic.com 'base https names do not allow plain HTTP'
printf 'http_8888:\n  - alt.example\n' > "$policy"
start_proxy
check 'the retired http_8888 section is reported' logged 'http_8888 is retired'
expect_http 403 alt.example 'a retired http_8888 entry is not applied' 8888

cat > "$policy" <<EOF
unrestricted: true
hosts:
  anything.example: $upstream
EOF
start_proxy
expect_status 403 anything.example 'an unapproved unrestricted policy allows nothing extra' 2223
trust_cmd n | grep -q 'WARNING: this policy is unrestricted' || fail 'the trust command did not warn about unrestricted'
trust_cmd '' "$folder" --yes | grep -q 'Approved\.' || fail 'automatic unrestricted approval failed'
start_proxy
check 'the proxy reports an unrestricted policy' logged 'allowing every destination'
expect_status 200 anything.example 'an unrestricted policy allows CONNECT to any port' 2223
expect_http 200 anything.example 'an unrestricted policy allows plain HTTP to any port' 8443
expect_http 200 anything.example 'an unrestricted policy allows plain HTTP on port 80'
start_proxy /projects/other
expect_status 403 anything.example 'an unrestricted approval is tied to the project folder' 2223

printf '# only comments\n' > "$policy"
check 'a policy that adds nothing needs no approval' trust_says y 'adds nothing'

if docker exec "$proxy" sh -c 'touch /trust/x' 2>/dev/null; then
    fail 'the proxy can write its trust store'
else
    pass 'the proxy cannot write its trust store'
fi

# Reload: a running proxy rereads the approved policy in place, keeping its
# process and open connections; an unapproved change reloads to the base policy.
cat > "$policy" <<EOF
https:
  - fake.example
hosts:
  fake.example: $upstream
EOF
trust_cmd '' "$folder" --yes >/dev/null
start_proxy
started=$(docker inspect -f '{{.State.StartedAt}}' "$proxy")
before=$(docker exec "$proxy" cat /tmp/applied-policy)
docker run -d --name "$prefix-held" --label "$prefix" --network "$network" busybox:1.37 \
    sh -c 'sleep 600 | nc egress-proxy 3128' >/dev/null
sleep 2
cat > "$policy" <<EOF
https:
  - fake.example
  - reload.example
hosts:
  fake.example: $upstream
  reload.example: $upstream
EOF
expect_status 403 reload.example 'a new entry does not apply before the reload'
trust_cmd '' "$folder" --yes >/dev/null
if docker exec "$proxy" sandbox-proxy-config --reload >/dev/null 2>&1; then
    pass 'the running proxy reloads its policy'
else
    fail 'the running proxy failed to reload its policy'
fi
sleep 1
if [ "$(tunnel reload.example)" = pinned-ok ]; then
    pass 'a reload applies a newly approved entry and its hosts pin'
else
    fail 'a reload did not apply the newly approved entry'
fi
after=$(docker exec "$proxy" cat /tmp/applied-policy)
if [ -n "$after" ] && [ "$after" != "$before" ]; then
    pass 'a reload records the newly applied policy'
else
    fail 'a reload did not record the newly applied policy'
fi
if [ "$(docker inspect -f '{{.State.StartedAt}}' "$proxy")" = "$started" ] &&
    [ "$(docker inspect -f '{{.State.Running}}' "$prefix-held")" = true ]; then
    pass 'a reload keeps the proxy running and its connections open'
else
    fail 'a reload restarted the proxy or dropped a connection'
fi
docker rm -f "$prefix-held" >/dev/null
printf '  - unapproved.example\n' >> "$policy"
docker exec "$proxy" sandbox-proxy-config --reload >/dev/null 2>&1 || fail 'reloading an unapproved policy failed'
sleep 1
expect_status 403 fake.example 'a reload with an unapproved change falls back to the base policy'
check 'a reload to the base policy records an empty applied policy' applied ''

# Lifetime: the proxy stops without a session, stays while a session holds an
# idle connection (as sandbox-proxy-lease does), and stops once it ends.
stopped_within() {
    tries=0
    while [ "$(docker inspect -f '{{.State.Running}}' "$proxy" 2>/dev/null)" = true ]; do
        tries=$((tries + 1))
        [ "$tries" -lt "$1" ] || return 1
        sleep 1
    done
}
lifetime='-e SANDBOX_PROXY_START_GRACE=3 -e SANDBOX_PROXY_IDLE_INTERVAL=1'
# shellcheck disable=SC2086
start_proxy "$folder" $lifetime
if stopped_within 20 && docker logs "$proxy" 2>&1 | grep -Fq 'no session connected within 3s'; then
    pass 'the proxy stops when no session connects'
else
    fail 'the proxy kept running without a session'
fi
# shellcheck disable=SC2086
start_proxy "$folder" $lifetime
docker run -d --name "$prefix-session" --label "$prefix" --network "$network" busybox:1.37 \
    sh -c 'sleep 600 | nc egress-proxy 3128' >/dev/null
sleep 8
if [ "$(docker inspect -f '{{.State.Running}}' "$proxy")" = true ]; then
    pass 'the proxy stays up past the grace period while a session holds a connection'
else
    fail 'the proxy stopped although a session held a connection'
fi
docker rm -f "$prefix-session" >/dev/null
if stopped_within 20 && docker logs "$proxy" 2>&1 | grep -Fq 'no session connected; stopping'; then
    pass 'the proxy stops once the last session ends'
else
    fail 'the proxy kept running after the session ended'
fi

# Sessions shorter than one check still count: a connection made and closed
# between two checks is seen as activity, so back-to-back brief sessions keep
# the proxy up. Open connections alone would miss most of these.
# shellcheck disable=SC2086
start_proxy "$folder" $lifetime -e SANDBOX_PROXY_IDLE_CHECKS=2
docker run -d --name "$prefix-brief" --label "$prefix" --network "$network" busybox:1.37 \
    sh -c 'while :; do timeout 0.1 nc egress-proxy 3128 </dev/null; sleep 0.9; done' >/dev/null
sleep 10
if [ "$(docker inspect -f '{{.State.Running}}' "$proxy")" = true ]; then
    pass 'brief sessions between checks keep the proxy up'
else
    fail 'the proxy stopped although brief sessions kept connecting'
fi
docker rm -f "$prefix-brief" >/dev/null
if stopped_within 20; then
    pass 'the proxy stops once brief sessions stop'
else
    fail 'the proxy kept running after brief sessions stopped'
fi

# A launch hold, touched by the host just before a launch, keeps an otherwise
# idle proxy up until it expires.
# shellcheck disable=SC2086
start_proxy "$folder" $lifetime -e SANDBOX_PROXY_LAUNCH_HOLD=8
docker exec "$proxy" touch /tmp/launch-hold
sleep 5
if [ "$(docker inspect -f '{{.State.Running}}' "$proxy")" = true ]; then
    pass 'a launch hold keeps an idle proxy up'
else
    fail 'the proxy stopped despite a fresh launch hold'
fi
if stopped_within 20; then
    pass 'the proxy stops once the launch hold expires'
else
    fail 'the proxy kept running after the launch hold expired'
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed." >&2; exit 1; }
echo 'Session proxy checks passed.'
