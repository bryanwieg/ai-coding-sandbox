#!/bin/sh
# Run against the agent image built with compose.dev.yaml, or image tags
# supplied as arguments. No network access is needed: the test module has no
# dependencies. /tmp is noexec as in a session; a tmpfs with exec stands in for
# the project's cache volume at /cache.
set -eu

if [ "$#" -eq 0 ]; then
    set -- ai-coding-sandbox-dev:agent
fi

for image do
    docker run --rm -i --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges:true \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=1777 \
        --tmpfs /cache:rw,exec,nosuid,nodev,mode=1777 \
        "$image" sh -s <<'EOF'
set -eu
test "$(id -u)" -ne 0
test ! -w "$HOME"
test "$(go env GOROOT)" = /usr/local/go
test "$(go env GOTOOLCHAIN)" = local
test "$(go env CGO_ENABLED)" = 1
test "$(go env GOPATH)" = /cache/go
for dir in "$(go env GOCACHE)" "$(go env GOMODCACHE)" "$(go env GOTMPDIR)"; do
    case $dir in
        /cache/go/*) ;;
        *) echo "Go state outside the cache volume: $dir" >&2; exit 1 ;;
    esac
done
test -d "$GOTMPDIR"
# The bundled toolchain matches the version the pinned image ships.
test "$(go env GOVERSION)" = "go$(sed -n 1s/^go//p /usr/local/go/VERSION)"

# The project lives in noexec /tmp, like any source; only Go's own build
# directories need exec.
project=$(mktemp -d)
cd "$project"
go mod init example.test/hello >/dev/null 2>&1
cat > hello.go <<'GO'
package main

// int answer(void) { return 42; }
import "C"

import "fmt"

func Greeting() string { return fmt.Sprintf("hello %d", int(C.answer())) }

func main() { fmt.Println(Greeting()) }
GO
cat > hello_test.go <<'GO'
package main

import "testing"

func TestGreeting(t *testing.T) {
	if Greeting() != "hello 42" {
		t.Fatal("unexpected greeting")
	}
}
GO
test -z "$(gofmt -l .)"
go vet ./...
go test -race ./... >/dev/null
test "$(go run .)" = 'hello 42'
go install .
test "$(command -v hello)" = /cache/go/bin/hello
test "$(hello)" = 'hello 42'
# Installed binaries come after the image's tools on PATH.
case $PATH in
    *":$GOPATH/bin:"* | "$GOPATH/bin:"*) echo 'GOPATH/bin is not last on PATH' >&2; exit 1 ;;
    *":$GOPATH/bin") ;;
    *) echo 'GOPATH/bin is missing from PATH' >&2; exit 1 ;;
esac

# gopls checks a plain package (no cgo) of the module offline, with its cache
# in the cache volume.
test "$(command -v gopls)" = /usr/local/bin/gopls
mkdir plain
cat > plain/plain.go <<'GO'
package plain

func Answer() int { return 42 }
GO
plain_out=$(gopls check plain/plain.go)
test -z "$plain_out"
test -d /cache/gopls
cat > plain/broken.go <<'GO'
package plain

func Broken() int { return "no" }
GO
gopls check plain/broken.go | grep -q 'broken.go:3'
test ! -e "$HOME/go"
test ! -e "$HOME/.cache"
test ! -e "$HOME/.config"
printf 'ok   %s builds cgo, runs -race tests and installs as %s with noexec /tmp\n' "$(go env GOVERSION)" "$(id -un)"
EOF
done
