#!/bin/sh
# sandbox-init-config: the reference root default and validation, the files
# it writes and their modes, never overwriting templates, and --force.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
init="$root_dir/image/sandbox-init-config"
policy="$root_dir/image/sandbox-policy"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
unset CONTEXT7_API_KEY

# run FOLDER INPUT [ARGUMENTS...]: runs the script for a project at FOLDER,
# answering its prompts with the lines of INPUT.
run() {
    folder=$1 input=$2
    shift 2
    mkdir -p "$folder"
    printf '%b' "$input" | SANDBOX_INIT_DIR=$folder HOST_PWD=$folder "$init" "$@" 2>"$test_dir/err"
}
value() {
    sed -n "s/^$1=//p" "$2/.sandbox/${3:-env}"
}

# References are opt-in, including for projects below src/.
project=$test_dir/workspace/src/team/My_App
run "$project" 'secret-key\n'
env_file=$project/.sandbox/env
[ "$(stat -c %a "$env_file")" = 600 ]
[ -z "$(value SANDBOX_REFERENCE "$project")" ]
[ "$(value COMPOSE_PROJECT_NAME "$project")" = my_app ]
[ "$(value COMPOSE_PATH_SEPARATOR "$project")" = , ]
[ "$(value COMPOSE_FILE "$project")" = oci://ghcr.io/bryanwieg/ai-coding-sandbox-compose:latest ]
[ "$(value COMPOSE_PROFILES "$project")" = docker,publish ]
[ "$(value SANDBOX_UID "$project")" = "$(id -u)" ]
[ "$(value SANDBOX_GID "$project")" = "$(id -g)" ]
# Secrets go to agent.env; env holds settings only.
[ "$(value CONTEXT7_API_KEY "$project" agent.env)" = secret-key ]
if grep -q 'CONTEXT7\|SANDBOX_PROJECT' "$env_file"; then exit 1; fi
grep -Fxq env "$project/.sandbox/.gitignore"
grep -Fxq agent.env "$project/.sandbox/.gitignore"
[ "$(stat -c %a "$project/.sandbox/agent.env")" = 600 ]
"$policy" check project "$project/.sandbox/egress-policy.yaml"
[ -z "$("$policy" hash "$project/.sandbox/egress-policy.yaml")" ]
[ -f "$project/.sandbox/ssh/config" ] && [ -f "$project/.sandbox/ssh/known_hosts" ]
[ ! -e "$project/.sandbox/.env.tmp" ]

# An existing env is kept unless --force, which keeps the templates and
# agent.env without asking for a key again.
if run "$project" '\n\n'; then exit 1; fi
grep -Fq 'already exists' "$test_dir/err"
printf 'https:\n  - kept.example\n' > "$project/.sandbox/egress-policy.yaml"
printf 'MY_SERVICE_TOKEN=kept-token\n' > "$project/.sandbox/agent.env"
# Upgrade an existing ignore file without replacing its custom entries.
printf 'env\ncustom-secret\n' > "$project/.sandbox/.gitignore"
CONTEXT7_API_KEY=from-env run "$project" '' --force
[ "$(value COMPOSE_PROJECT_NAME "$project")" = my_app ]
grep -Fq kept.example "$project/.sandbox/egress-policy.yaml"
grep -Fxq MY_SERVICE_TOKEN=kept-token "$project/.sandbox/agent.env"
grep -Fxq custom-secret "$project/.sandbox/.gitignore"
grep -Fxq agent.env "$project/.sandbox/.gitignore"

# Omitting --reference and selecting "." expose only the project.
project=$test_dir/standalone
run "$project" '\n\n'
[ -z "$(value SANDBOX_REFERENCE "$project")" ]
project=$test_dir/workspace/src/other
run "$project" '\n' --reference .
[ -z "$(value SANDBOX_REFERENCE "$project")" ]
project=$test_dir/no-reference
run "$project" 'key-without-reference-prompt\n'
[ -z "$(value SANDBOX_REFERENCE "$project")" ]
[ "$(value CONTEXT7_API_KEY "$project" agent.env)" = key-without-reference-prompt ]
project=$test_dir/key-from-env
CONTEXT7_API_KEY=from-env run "$project" ''
[ "$(value CONTEXT7_API_KEY "$project" agent.env)" = from-env ]

# An explicit reference folder must be absolute, and can be unrelated.
project=$test_dir/workspace/src/third
run "$project" '' --reference "$test_dir/workspace/src/"
[ "$(value SANDBOX_REFERENCE "$project")" = "$test_dir/workspace/src" ]
project=$test_dir/workspace/src/fourth
run "$project" '\n' --reference "$test_dir/elsewhere"
[ "$(value SANDBOX_REFERENCE "$project")" = "$test_dir/elsewhere" ]
if run "$test_dir/workspace/src/fifth" '' --reference relative/path; then exit 1; fi
grep -Fq 'must be an absolute path' "$test_dir/err"

# HOST_PWD must be an absolute path.
if printf '\n\n' | SANDBOX_INIT_DIR=$test_dir HOST_PWD=relative "$init" 2>"$test_dir/err"; then exit 1; fi
grep -Fq 'HOST_PWD' "$test_dir/err"

echo 'sandbox-init-config tests passed.'
