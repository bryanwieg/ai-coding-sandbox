# Sandbox Session Guide

You are running inside a restricted development sandbox, started from the
sandbox's Compose file. This guide explains how the sandbox is put together,
what it provides, how the project's `.sandbox/` configuration works, and how
to work well within it. The session rules that follow it govern every
session. Both come from the sandbox image and apply in addition to the
project's own instructions; where they conflict, the rules win.

## Components

A session is a set of Compose services, all from the sandbox's images:

- **The agent** (`claude` or `codex`): this container. It runs as the user's
  UID and GID, with a read-only root filesystem, no capabilities and
  `no-new-privileges`, on an internal network with no route out. Both CLIs,
  `claude` and `codex`, are installed and signed in from their own state
  volumes, so either agent can run the other non-interactively (such as
  `codex exec` for a delegated task); `SANDBOX_AGENT` names the one this
  session started. Codex's own sandbox (bubblewrap) cannot start in this
  container, so Codex runs with `danger-full-access` and the container is
  the boundary: the image sets that as Codex's default and as
  `CODEX_BUILD_SANDBOX`; do not pass `--sandbox read-only` or
  `workspace-write`, under which every command fails.
- **`egress-proxy`**: the only service with an Internet uplink. Every request
  leaves through it, and it allows only the base policy plus the project's
  approved additions.
- **`docker`** (profile `docker`): the project's own rootless Docker daemon,
  reached at `DOCKER_HOST=tcp://docker:2376` with mutual TLS. Never the
  host's daemon.
- **`publish`** (profile `publish`): forwards the ports in the
  `SANDBOX_PUBLISH_*` slots from the user's machine to the session daemon.
- **`ssh-agent`** (profile `ssh`): holds the user's unlocked SSH keys. This
  session gets only its socket (`SSH_AUTH_SOCK`), never the keys.
- One-shot services the user runs on the host: `trust` (approves the egress
  policy), `ssh-unlock` (loads SSH keys), and `*-state-init` (prepares
  volumes before each start).

The proxy and the daemon belong to the project: several sessions of either
agent in the same project share them, and each stops shortly after the last
session ends.

### Volumes

| Volume | Mounted at | Scope and lifetime |
| --- | --- | --- |
| Agent state | `~/.claude` and `~/.codex`, one volume each | Shared by all the user's projects and both agents; sign-ins, sessions, memory, settings, plugins, and the started agent's `gh` login (`GH_CONFIG_DIR`) |
| `cache` | `/cache` | This project only, persists; Go's `GOPATH` and caches, VS Code's server, and other build caches |
| `trust` | `/run/sandbox-trust`, read-only | Approved policy hashes, written only by `trust` on the host |
| `docker-certs` | `/run/docker-certs`, read-only | The client certificate for the session daemon |
| `ssh-socket` | `/run/ssh-agent`, read-only | The ssh-agent's socket |
| `docker-data` | Session daemon only | Its images and containers; wiped when it stops unless `SANDBOX_DOCKER_DATA=persistent` |

## Files

- The working directory is the selected project, writable, at
  `/workspace/<COMPOSE_PROJECT_NAME>`. The folder name keeps the agent's
  conversations and memory, which are stored by folder, apart from other
  projects'.
- When configured, `/reference` is an additional read-only host folder:
  other projects there can be read for context. Without a reference folder,
  it is an empty file.
- `/tmp` is writable, `noexec`, and emptied whenever the container starts.
  `/cache` is writable and allows executables. Everything else outside the
  agents' state volumes is read-only, including the home directory.
- `.ai-scratchpad/` in the project is the agents' own working folder for
  notes, plans, logs and scratch files that should outlast `/tmp`; it keeps
  itself out of Git. At a normal exit, when it changed, the agent is run once
  more to tidy it; each start deletes entries untouched for the project's last
  `SANDBOX_SCRATCHPAD_DAYS` session days (default 7). Exit also deletes local
  branches already merged, rebased or squashed into the default branch.
- `XDG_CONFIG_HOME` defaults to `~/.claude/xdg`, shared by both agents, so
  plugins and tools can persist settings and task ledgers while the rest of
  the home is read-only. An explicit `XDG_CONFIG_HOME` is preserved.
- `~/.ssh` is the project's `.sandbox/ssh`, read-only.
- The image's own reference files are in `/usr/local/share/sandbox/`: this
  guide and the rules (`session-guide.md`, `session-rules.md`) and the base
  egress policy (`base-policy.yaml`).

## The project's `.sandbox/` folder

The user's configuration for this project. It is mounted read-only into the
session at `.sandbox` in the project (and into the proxy and daemon), so nothing
in a session can change it. The user creates it once with
`sandbox-init-config` and edits it on the host. Changes to it take effect at
the next session start, except the egress policy, which the user can approve
and reload into a running session.

### `env`

Compose's settings for the project, passed with `--env-file`. Mode `0600` and
ignored by Git; older configurations may still hold secrets in it. It configures
Compose; it does not pass arbitrary variables into the session. The settings
that matter to a session reach it as environment variables, so read those
rather than the file:

| Setting in `env` | In the session | Meaning |
| --- | --- | --- |
| `COMPOSE_FILE` | – | The published, digest-pinned Compose file (`oci://…`) |
| `COMPOSE_PROJECT_NAME` | The working directory's name | Scopes the proxy, daemon and project volumes |
| `COMPOSE_PROFILES` | `SANDBOX_PROFILES` | Optional services: `docker`, `publish`, `ssh` |
| `SANDBOX_UID`, `SANDBOX_GID` | `id -u`, `id -g` | The user's account, which runs the agent |
| – | `HOST_PWD` | The project's folder on the host, where the session was started |
| `SANDBOX_REFERENCE` | `SANDBOX_REFERENCE` | The host folder at `/reference`, or empty |
| `SANDBOX_PUBLISH_PORTS` (and `_2`, `_3`, `UDP_PORTS`, `UDP_PORTS_2`, `UDP_PORTS_3`) | Same names | Ports forwarded to the user's machine |
| `SANDBOX_PUBLISH_ADDRESS` | Same name | Host address for published ports (default `127.0.0.1`) |
| `SANDBOX_DAEMON_EGRESS` | Same name | `proxied` (default) or `direct` for the daemon's containers |
| `SANDBOX_DOCKER_DATA` | Same name | `ephemeral` (default) or `persistent` daemon data |
| `SANDBOX_SSH_KEY_DIR` | Same name | The host folder of SSH keys; only `ssh-agent` and `ssh-unlock` mount it |

`DOCKER_HOST` and `SANDBOX_DOCKER_SOCKET` are set only when the `docker`
profile is on; `SSH_AUTH_SOCK`
is useful only when `ssh` is on and keys are unlocked.

### `agent.env`

Environment variables and secrets for both agents and the commands they run,
such as `CONTEXT7_API_KEY` (an optional key for Context7's rate limits) or
the session cleanup settings `SANDBOX_SCRATCHPAD_DAYS`, `SANDBOX_EXIT_CLEANUP`
and `SANDBOX_EXIT_CURATE`, as
literal `NAME=value` lines (no quotes, no `export`). Mode `0600`
and ignored by Git. Use the variables it provides; do not read the file
itself.

### `egress-policy.yaml`

Destinations this project adds to the base policy. Sections, each a list of
`NAME` or `NAME:PORT` entries:

- `https`: CONNECT, port 443 by default.
- `http`: plain HTTP, port 80 by default.
- `ssh`: CONNECT for SSH, port 22 by default.
- `hosts`: `NAME: IPv4` pins for names the proxy cannot resolve.
- `unrestricted_out: true` at the top level (older name: `unrestricted`)
  allows every outbound destination instead. Inbound access is only the
  ports published in `env`.

An entry allows only its own name and port; a leading dot (`.example.com`)
also allows subdomains. Additions apply only once the user approves them
with `trust`, which stores a hash of the entries in the `trust` volume;
comments and layout do not affect it. An unapproved or invalid policy leaves
the base policy alone in force, and the session start warns about it. To
check approval from here:

```sh
policy=.sandbox/egress-policy.yaml
sandbox-policy check project "$policy"
test "$(sandbox-policy hash "$policy")" = \
  "$(cat "/run/sandbox-trust/$(sandbox-policy trust-id "$HOST_PWD").sha256" 2>/dev/null)"
```

The base list is `/usr/local/share/sandbox/base-policy.yaml`.

### `ssh/`

`config` (client settings such as `User`, `Port` and aliases) and
`known_hosts`, mounted read-only as `~/.ssh`. A host on a nonstandard port is
listed as `[name]:port` in `known_hosts`.

### `.gitignore` and sharing

`.gitignore` keeps `env` and `agent.env` out of Git. The rest of `.sandbox/`
(the policy and SSH settings) can be committed to share them with the
project.

## Tools

- Languages: Node.js, Python 3 (with pytest, pytest-timeout, pycodestyle,
  Ruff, PyYAML, scapy and python-on-whales), the PHP CLI (with Composer,
  PHPUnit and PHP_CodeSniffer), Go, and GCC for cgo. `GOPATH`, Go's caches
  and `GOTMPDIR` persist in `/cache/go`; `go install`ed binaries come last on
  `PATH`.
- Also installed: PowerShell 7 (`pwsh`), Git with Git LFS, the GitHub CLI
  (`gh`), jq, ShellCheck, bmake (there is no GNU make), xmllint, netcat, the
  OpenSSH client, zip and unzip.
- The Docker CLI with the compose and buildx plugins, for the session daemon.
- The user may attach VS Code to the session. `~/.vscode-server` and
  `~/.vscode-remote-containers` link to `/cache/vscode`, where VS Code keeps
  its server and extensions; do not modify them.
- The default shell is `/bin/bash`, with its history in `/tmp`; the agent
  container's hostname is `sandbox`.
- Context7 is configured as an MCP server: use it for current library and
  framework documentation instead of guessing.

## Network

- All traffic leaves through the egress proxy (`HTTPS_PROXY`), which allows
  only listed destinations: HTTPS (port 443) to the base list (the model
  APIs, sign-in, Claude's user content hosts, Google Cloud Storage
  (`storage.googleapis.com`), Context7, GitHub including its MCP endpoint,
  the VS Code Marketplace, GitLab, Docker Hub, GHCR and LSCR including
  subdomains, PyPI, the Go module proxy and checksum database, and a broad
  list of documentation, reference, Q&A and source code sites) plus the
  project's approved `https` additions; plain HTTP only to names in the
  project's `http` list; and SSH to `gitlab.com` and to destinations in the
  project's `ssh` list. A project the user approved as `unrestricted_out: true`
  allows every destination through the proxy; the session start warns when
  it is on. Treat that as the user's choice, not as license to send project
  data to destinations the task does not need.
- PyPI is allowed: install Python packages into a virtual environment in
  the project or `/cache` (the image's site-packages and the home are
  read-only), and only those the task needs. Other package registries
  (npm, Packagist, apt) are blocked unless the project's policy adds them,
  so installing those packages usually fails. Prefer the installed tools;
  when a task needs a package or another destination, tell the user which
  name to add to `.sandbox/egress-policy.yaml`.
- A refused destination shows up as a 403 from the proxy or a failed
  `CONNECT` tunnel. That means the name is not allowed; do not retry it
  another way.
- Web search (Claude's WebSearch) runs on the model provider's side and
  works regardless of the allowlist. Fetching a page (WebFetch, `curl`)
  goes through the proxy and needs its host allowed.
- When documentation or source code you need is on a refused host, do not
  give up or guess at its contents. Ask the user for access, naming the
  exact host and why the task needs it, in a form they can paste:

  ```
  The proxy refused docs.example.org, which has the reference for <topic>.
  To allow it, add it to .sandbox/egress-policy.yaml:

    https:
      - docs.example.org

  then approve it on the host (a running session picks it up at once):

    docker compose --env-file .sandbox/env run --rm trust
  ```

  While waiting, use what is reachable: web search, Context7, the
  installed tools' `--help` and man pages, and sources on allowed hosts
  (GitHub, GitLab, PyPI, the Go module proxy). Say which source an answer
  came from, and continue once the user confirms the host is approved.
- GitHub works over HTTPS with the GitHub CLI's stored sign-in; Git uses it
  automatically, and `git@github.com:` remotes are rewritten to HTTPS.

## Docker

- When `DOCKER_HOST` is set, `docker` and `docker compose` drive a rootless
  daemon that belongs to this project and runs in its own container. It
  starts empty and is wiped when the last session in the project ends:
  images, containers, volumes and build cache do not persist. When the user
  set `SANDBOX_DOCKER_DATA=persistent`, they persist between sessions
  instead; do not rely on what an earlier session left there without
  checking it, and remove what a task no longer needs.
- Images pull from Docker Hub, GHCR and LSCR through the proxy. Containers
  and builds get the HTTPS proxy automatically, so the network rules apply to
  them too. When the user set `SANDBOX_DAEMON_EGRESS=direct` (startup warns
  about it), containers instead have a direct route to any host, port and
  protocol for workloads that need it; this session still has only the
  proxy. The data-handling rules still apply to everything containers send.
  Plain HTTP between containers works.
- Bind mount sources are paths in the daemon's container, not in this one.
  The project directory is there at the same path as here and is the one
  folder to mount; the reference folder, `/cache` and `/tmp` are not
  available to containers.
- A port a container publishes on the daemon (`-p 8080:80`) is reached from
  this session at `docker:8080`, not `localhost:8080`.

### Connecting to the daemon

- From this session nothing needs configuring: `DOCKER_HOST`,
  `DOCKER_TLS_VERIFY` and `DOCKER_CERT_PATH` point the CLI, Compose and
  Docker SDKs at `tcp://docker:2376` with the session's client certificate.
  Never copy the certificate into the project or into containers.
- Containers that manage containers themselves (a scheduler, a CI runner,
  Testcontainers, an update agent) use the daemon's own socket, the standard
  pattern unchanged. `SANDBOX_DOCKER_SOCKET` names it,
  `/var/run/docker.sock`, a path on the daemon's side only; it does not exist
  in this session, so do not `stat` it here:

  ```yaml
  services:
    scheduler:
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
      environment:
        DOCKER_HOST: unix:///var/run/docker.sock
  ```

- Container root owns the socket (user and group 0), so run such a
  container as root, or as another user with `group_add: ["0"]`.
- The socket reaches this same daemon, nothing else: containers it starts
  follow every rule above, and project bind mounts from them work at the
  same path. Socket clients do not keep the daemon running; it still stops
  when the last session ends.
- Root in a container maps to the user's own account, so files containers
  create in the project belong to the user. Privileged containers are
  refused.

## Ports for the user

- `SANDBOX_PUBLISH_PORTS` lists the ports (one, or a range such as
  `8000-8009`) forwarded to the user's machine, on `127.0.0.1` unless
  `SANDBOX_PUBLISH_ADDRESS` says otherwise. `SANDBOX_PUBLISH_PORTS_2` and
  `_3` add TCP slots, and `SANDBOX_PUBLISH_UDP_PORTS`, `_2` and `_3` UDP
  ones; publish UDP with `-p PORT:PORT/udp`. Publish a service on one of
  those daemon ports, for example `docker run -p 8080:80 …` when 8080 is
  listed, and the user opens `http://127.0.0.1:8080`.
- When it is empty or lacks the port a task needs, ask the user to set it in
  `.sandbox/env` and start a new session.

## SSH

- When the user enabled SSH and unlocked keys, `ssh host` works for hosts in
  the project's `ssh` list, through the proxy and `SSH_AUTH_SOCK`. For a
  `name:port` entry, use `ssh -p port name` or the matching `Port` setting in
  `.sandbox/ssh/config`.
- The host's optional `sandbox` command approves the egress policy, reloads
  a running proxy whose policy is out of date, and unlocks SSH keys before
  launching an agent, reusing already-unlocked keys. Direct Compose launches
  require these steps manually. Neither workflow lets the agent approve
  policy changes or load keys itself. To allow a blocked destination
  mid-session, ask the user to add it to `.sandbox/egress-policy.yaml` and
  run `sandbox-trust` on the host; the running proxy then reloads with it,
  with no restart of the session.
- Host keys come from `.sandbox/ssh/known_hosts`, which is read-only here,
  and an unknown or changed key fails instead of prompting. For a new host,
  `sandbox-ssh-hostkey <host>` (with `-p PORT` like `ssh`) prints the exact
  line to add and its fingerprint without logging in; give both to the
  user. Exit status 2 means the key differs from the listed one.

## Working well here

- Check what this session has before planning around it: `SANDBOX_PROFILES`
  for Docker, ports and SSH; `DOCKER_HOST`; `SANDBOX_PUBLISH_PORTS`;
  `ssh-add -l` for unlocked keys; the approval check above for the policy.
- Put anything that must execute (virtual environments, downloaded tools,
  build output) in the project or `/cache`, not `/tmp`, which is `noexec`.
  Prefer `/cache` for caches that should not land in the project.
- When something is blocked by the sandbox (a refused destination, a missing
  port, a locked key, a read-only path), stop and tell the user the exact
  change and command; do not look for a way around it. For documentation and
  source code, ask for access as shown under Network rather than giving up.
- Give the user commands to run from the project folder on the host, using
  the `docker compose --env-file .sandbox/env …` form; the `sandbox` shell
  functions are an optional convenience they may not have.

### Working habits

Defaults for any project; the project's own instructions override them.

- Read first, then code: check the project's docs and search for existing
  helpers and patterns before writing new ones, reuse them, and match the
  project's naming. Hand-roll only when nothing applies, and say why.
- Use the most precise tool available, such as a language server for
  definitions and references rather than text search. When a tool fails or
  is missing (a language server that does not start, an MCP server error, a
  command not found), tell the user what failed and its error before falling
  back; do not fall back silently.
- Before diagnosing a failure, read its full output and logs. When the cause
  stays unclear, add temporary logging instead of guessing, and remove it
  afterwards unless the failure is likely to recur. Report initial findings
  before going deep.
- Keep behavior unchanged unless asked, and do not add single-use helpers or
  new files without a reason.
- Keep personal notes, plans and logs in `.ai-scratchpad/`, not in `/tmp`
  or the project's tracked files, and never commit them. Start each note
  with its date and topic, and delete it once its work is done.
- Notes, memories and docs may be out of date: check them against the code
  before relying on them. When you change behavior, update or remove what
  describes it, replacing outdated text rather than appending to it.
- Work on a branch, not the default branch, and commit in logical steps. A
  pull request may hold several commits, and some plugins rely on them;
  whether to squash is decided per pull request. Pushing and opening pull
  requests still follow the session rules.
- When the user corrects your approach or a non-obvious decision is made,
  propose recording its reasoning, the why and not only the rule, in the
  project's guidance files.

## What only the user can do

Tell the user the exact command when a task needs one of these. Each runs on
their machine, from the project folder:

- Approve egress additions:
  `docker compose --env-file .sandbox/env run --rm trust`
- Unlock SSH keys:
  `docker compose --env-file .sandbox/env run --rm ssh-unlock`
- Change ports, profiles (for example `ssh`) or the reference root: edit
  `.sandbox/env`, then start a new session.
- Provide tokens or custom environment variables: edit `.sandbox/agent.env`
  (private, mode `0600`, ignored by Git), then start a new session. Use
  literal `NAME=value` entries without quotes or `export`.
- Sign the agent in again, or sign in the other agent:
  `docker compose --env-file .sandbox/env run --rm <agent> sandbox-auth [claude|codex] login`
