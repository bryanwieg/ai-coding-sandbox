#!/bin/sh
# Run the module checks offline in the same Go image used for the sandbox.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
image=$(awk '$1 == "FROM" && $3 == "AS" && $4 == "go-upstream" { print $2; exit }' "$root_dir/Dockerfile")
[ -n "$image" ] || { echo 'test-lifecycle: no go-upstream stage in the Dockerfile.' >&2; exit 1; }

docker run --rm -i --network none --tmpfs /tmp:exec \
    -v "$root_dir/lifecycle:/src:ro,z" \
    "$image" sh -s <<'EOF'
set -eu
cp -R /src /tmp/build
cd /tmp/build
export GOTOOLCHAIN=local GOFLAGS=-mod=mod
unformatted=$(gofmt -l .)
[ -z "$unformatted" ] || { echo "gofmt: $unformatted" >&2; exit 1; }
go vet ./...
CGO_ENABLED=0 go build -o /tmp/sandbox-lifecycle .
go test -race -count=1 ./...
EOF
echo 'Lifecycle tests passed.'
