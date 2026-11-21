# Agent Sandbox

This directory builds the sandbox: container images and a Compose file that
run a coding agent, Codex or Claude Code, in an isolated session for one
project at a time. A project needs only Docker with Compose and a `.sandbox/`
folder; it does not need this repository. Sessions start without routine
command-approval prompts (Codex with `-a never`, Claude Code with
`--dangerously-skip-permissions`), because the container is the boundary.
Codex also runs plugin and configured hooks without its per-hook trust review
(`--dangerously-bypass-hook-trust`), as Claude Code does.

A session is `docker compose --env-file .sandbox/env run --rm claude` (or
`codex`) from the project root. `.sandbox/env` points `COMPOSE_FILE` at the
published Compose file, `oci://ghcr.io/bryanwieg/ai-coding-sandbox-compose:latest`,
which pins every image by digest. These services make up a session:

| Service | Profile | Role |
| --- | --- | --- |
| `claude`, `codex` | named by the run | The agent, in the shared agent image with both agents' state volumes |
| `claude-state-init`, `codex-state-init` | always | Give each state volume to your user; create the daemon's client certificate folder |
| `lifecycle` | always | Coordinates the project's session group and stops it after the last session ends |
| `egress-proxy` | always | The only route out: an allowlisting Squid proxy |
| `docker` | `docker` | A rootless Docker daemon for the project |
| `publish` | `publish` | Forwards `SANDBOX_PUBLISH_PORTS` from the host to the daemon |
| `ssh-agent`, `ssh-unlock` | `ssh` | Serve SSH keys without exposing them |
| `trust`, `migrate-*-state` | `tools` | Approve the egress policy; copy old state |

## Set up a machine

Once per machine, create the shared volumes. They hold sign-ins, sessions,
memory, settings and plugins for every project, and egress approvals:

```sh
docker volume create ai-coding-sandbox-claude-state
docker volume create ai-coding-sandbox-codex-state
docker volume create ai-coding-sandbox-trust
```

The volumes are external, so no project's `down -v` can delete them. Build
caches are not shared: each project gets its own `cache` volume at `/cache`,
created by Compose and named after the project. To move state over from the
retired `run-sandbox` launcher, see
[Migrate from run-sandbox](#migrate-from-run-sandbox).

The shell functions in [`shell/sandbox.sh`](shell/sandbox.sh) shorten the
commands below. Sessions need only the published images and Compose file, so
no checkout of this repository is needed: [`install.sh`](../install.sh)
downloads the functions and does the setup above in one step, and rerunning
it updates them:

```sh
curl -fsSL https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/install.sh | sh -s -- ~/.zshrc   # name the startup file
```

It downloads `shell/sandbox.sh` from `main` to
`~/.local/share/ai-coding-sandbox/sandbox.sh` (under `$XDG_DATA_HOME` when
set), replacing the copy only after a complete download. It creates the three
volumes when Docker is reachable, and sources the functions from the startup
file of the shell that runs it, which may differ from the login shell in
`$SHELL`. A startup file that already sources them, from a checkout for
example, is pointed at the downloaded copy. Piped from `curl`, it runs in a
child process, so it cannot load the functions into the current terminal; it
prints the `.` command that does. Your startup file then runs code fetched
from this repository's `main` branch, as a checkout pulled from `main` would.

The installed copy keeps itself current. The installer records the URL it
downloaded from in `source-url` next to the copy. Each `sandbox`,
`sandbox claude` or `sandbox codex` launch from that copy first downloads
`sandbox.sh` from that URL; other services and the other functions do not
check. A download that differs from the copy must hold the `sandbox`
function and parse in the running shell, and then replaces the copy
atomically. Whenever the installed copy differs from what the shell loaded,
whether this launch, another terminal or an installer rerun updated it, the
launch sources it and continues with the new functions, before it pulls
images. A failed check (offline, no `curl`, an invalid download) prints a
warning and launches with the installed copy. A copy sourced from a checkout
has no `source-url`, so it never updates itself and makes no request. This
means every agent launch runs host code from that URL without review, in
your shell and outside the sandbox, as the Compose file from `:latest`
already shapes each session; to avoid that, source a checkout's copy
instead. A copy installed before this feature has neither the check nor a
`source-url`; rerun the installer once to get both.

To use a checkout's copy instead, for example while developing the sandbox,
add it to your startup file from the checkout:

```sh
sandbox/bin/install-shell-functions            # ~/.zshrc or ~/.bashrc, from $SHELL
sandbox/bin/install-shell-functions ~/.zshrc   # or name the file
```

| Function | Runs |
| --- | --- |
| `sandbox --help` (or `-h`) | Show sandbox commands and parameters without starting Docker; works before setup |
| `sandbox-init [--reference PATH] [--force]` | `sandbox-init-config` from the dedicated init image, offline, in this folder |
| `sandbox [SERVICE [ARGS...]]` | Without `.sandbox/env`, run `sandbox-init` at a Git repository's root (and stage `.sandbox/`) or in a folder outside any repository; for `claude` and `codex`, first update the installed functions and load them into this shell; approve egress, unlock SSH if enabled, then run the agent with Compose (default `claude`); other services run directly |
| `sandbox-trust` | `sandbox trust`, then reload a running proxy whose policy changed |
| `sandbox-unlock` | Unlock SSH keys for the running session group or for a session you start within two minutes |
| `sandbox-stop` | Stop the project's sessions and services, keeping its volumes |
| `sandbox-status` | Show the project's session group status |
| `sandbox-prune` | Remove released sandbox images that a newer release replaced; runs after every `claude` or `codex` session |

For `claude` and `codex`, including a shell or command in either image,
`sandbox` first updates an installed copy of the functions as described
above, before it creates a missing `.sandbox/`. It then pulls missing images
and builds images configured for local builds before starting any services.
It waits for a stopping group, then validates
and automatically approves the project's egress policy. With the `ssh`
profile enabled, it unlocks SSH keys if none are loaded, prompting for
passphrases when needed. A failed approval or unlock stops the launch.

When a `claude` or `codex` session ends, successful or not, `sandbox` runs
`sandbox-prune`. Each release pins its images by digest, so an update leaves
the previous ones behind untagged; `sandbox-prune` removes the untagged
images of `ghcr.io/bryanwieg/ai-coding-sandbox` that neither this project's
Compose file nor any container, running or stopped, uses. Tagged images stay.
A stopped service container of another project keeps its image until that
project's next launch replaces the container. A project on other images, such
as a development checkout, skips the cleanup. It does not touch build cache
or the session daemon's own data; see [Keeping Docker data](#keeping-docker-data).

Automatic approval means policy edits take effect without a separate review
prompt. The policy and trust store remain read-only to the agent. When this
project's proxy is already running with a different policy, `sandbox` reloads
it in place before launching; running sessions keep their open connections.
A proxy from an older image, which cannot reload, is restarted instead, and
the open connections of other sessions (an SSH login, a streaming request)
drop once. Just before launching, `sandbox` checks again and waits if the
group is stopping, so the next group starts with the current settings. If
services are still running at the wait limit, `sandbox` names and removes
the stuck containers.

These preparation steps belong to the optional shell function. Direct
`docker compose` launches still require manual `trust` and `ssh-unlock`.
After updating this checkout, reload the functions with
`. sandbox/shell/sandbox.sh` from the repository root, or open a new shell.

If your shell has `autocd` set and the functions are not loaded, typing
`sandbox` changes into a folder of that name instead of failing.

## Session lifecycle

Each project's `lifecycle` service is the broker for its sessions and the
services they share. Compose starts it first. The agent and service
containers stay connected to the broker while their commands run.

- `starting` waits up to 120 seconds for the first agent. Each join on the
  services socket renews that window while the broker is in this state.
- `active` lasts as long as at least one agent is connected, even when the
  agent is waiting for input.
- `idle` begins when the last agent disconnects. `sandbox` waits a few
  seconds for the old group to stop so the next launch starts a fresh group
  with the current settings. A launch can join an active group or a starting
  group with at least 5 seconds left.
- `draining` begins when the startup or idle window runs out, or when
  `sandbox-stop` asks the broker to stop. The broker rejects joins and tells
  every connected member to stop. It exits when all members disconnect or
  the drain limit is reached.

Sessions keep running during a broker update or restart while their wrappers
reconnect. If a wrapper cannot reconnect within 30 seconds, it stops its
command.

The broker mounts the whole per-project `lifecycle` volume. Each client
mounts only its role's subdirectory read-only at `/run/sandbox-lifecycle`
and connects to `/run/sandbox-lifecycle/lifecycle.sock`.

| Socket (broker path) | Mounted by (subpath) | Names admitted | Pool |
| --- | --- | --- | --- |
| `/run/sandbox-lifecycle/agents/lifecycle.sock` | claude, codex (`agents`) | `claude`, `codex` | 64 |
| `/run/sandbox-lifecycle/services/lifecycle.sock` | egress-proxy, publish, ssh-agent (`services`) | `egress-proxy`, `publish`, `ssh-agent` | 16 |
| `/run/sandbox-lifecycle/daemon/lifecycle.sock` | docker (`daemon`) | `docker` | 4 |

Containers on the daemon can bind-mount paths from the daemon's container,
so the daemon gets its own socket and connection pool. The control socket
at `/tmp/sandbox-lifecycle-control.sock` is available only inside the broker
container.

| Setting | Value | Where |
| --- | --- | --- |
| Startup without an agent | 120 s | broker |
| Idle after the last agent | 2 s | broker |
| Join margin (`starting` is not joinable below it) | 5 s | broker |
| Drain limit | 25 s | broker |
| Rejoin window | 30 s | wrapper |
| Admission retry at start | 10 s, every 250 ms | wrapper |
| Join reply timeout | 2 s | wrapper and broker |
| Hard exit after the grace | 2 s | wrapper |
| Grace: egress-proxy, publish, ssh-agent | 5 s | wrapper |
| Grace: docker | 22 s | wrapper |
| Grace: claude, codex | 10 s | wrapper |
| Compose `stop_grace_period`: docker / claude, codex | 25 s / 15 s | Compose |
| Host wait for a stopping group (also `sandbox-stop`) | 40 s | `sandbox.sh` |

Run `sandbox-status` from the project root to see the broker's state,
whether the group is joinable, any time left in the startup or idle window,
and the connected agents and services. It reports when no group is running.
If a group will not stop, run `sandbox-stop` to drain it, remove any
remaining project containers, and keep the project's volumes. To inspect
the broker's logs before removing the container, run
`docker compose --env-file .sandbox/env logs lifecycle`.

`sandbox` labels each agent container and watches the launching shell. If
the shell dies, the watcher stops and removes the container. `sandbox` also
removes any container left behind when its Compose command returns. A plain
`docker compose run` launch has no watcher and can leave its container
running if the Compose client dies.

Run `sandbox` again if an SSH passphrase prompt stays open past the two-minute
startup window and the unlock fails. Also retry if a launch into an active
group fails because all other sessions quit while Compose recreates a
service whose settings changed.

## Set up a project

From the project root, run `sandbox-init`, or without the functions:

```sh
docker run --rm --pull=always -it --network none --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --user "$(id -u):$(id -g)" -v "$PWD:/project" -e HOST_PWD="$PWD" \
  ghcr.io/bryanwieg/ai-coding-sandbox:init-latest sandbox-init-config
```

The initializer contains neither Codex nor Claude. Each invocation checks the
registry for the current init image; Docker reuses cached layers and downloads
only missing layers. The initializer itself runs without network access.
`SANDBOX_INIT_IMAGE` selects another image (it must be available in a registry).

It asks for an optional Context7 API key, then creates:

| File | Contents |
| --- | --- |
| `.sandbox/env` | Compose settings (mode `0600`) |
| `.sandbox/agent.env` | Environment variables and secrets for both agents, including `CONTEXT7_API_KEY` and the session cleanup settings under [Session exit](#session-exit) (mode `0600`) |
| `.sandbox/.gitignore` | Keeps `env` and `agent.env` out of Git |
| `.sandbox/egress-policy.yaml` | Destinations this project adds to the base policy |
| `.sandbox/ssh/config`, `.sandbox/ssh/known_hosts` | SSH client settings and host keys |

The reference folder is an optional host folder the agent may read but not
change, mounted at `/reference`. It can be anywhere; it need not contain the
project. Without `--reference`, initialization configures project-only access
and does not prompt for a reference folder. To include a reference:

```sh
sandbox-init --reference /absolute/path/to/reference
sandbox codex
```

`--force` replaces an existing `.sandbox/env` and keeps the other files.
Commit the rest of `.sandbox/` if the project should share its policy and SSH
settings.

Running `sandbox` at the root of a Git repository without `.sandbox/env`,
such as a fresh clone, runs `sandbox-init` with its defaults first, stages
`.sandbox/` with `git add` and then starts the session. The `.gitignore` keeps
`env` and `agent.env` unstaged, and files that already exist are kept. Review
and commit the staged files; a repository that ignores `.sandbox/` is not
staged. In a folder outside any repository, such as one holding several
repositories the agent should work across, `sandbox` creates `.sandbox/` the
same way without staging it. In a subfolder of a repository, the home folder
or `/`, `sandbox` still stops and asks you to run `sandbox-init`.

To provide tokens or other environment variables to the agents, edit
`.sandbox/agent.env` in your editor, then start a new session normally:

```dotenv
MY_SERVICE_TOKEN=your-token
ANOTHER_API_KEY=your-key
```

Both Claude and Codex, and commands they run, receive these variables;
sidecars do not. Values are literal: do not add quotes or `export`, and `$`
characters are preserved. The sandbox's explicit environment settings, such
as its proxy variables, take precedence. This requires Docker Compose 2.30
or newer. `.sandbox/env` configures Compose and does not automatically pass
arbitrary variables into containers.

For an existing project, create `.sandbox/agent.env`, set its permissions to
`0600` (`chmod 600 .sandbox/agent.env`), and add `agent.env` to
`.sandbox/.gitignore`. The file is optional, so existing projects continue to
launch without it. Keep tokens out of Git; the initializer creates the file
with private permissions and preserves it when run with `--force`.

`.sandbox/env` settings; it holds no secrets:

| Variable | Meaning |
| --- | --- |
| `COMPOSE_FILE`, `COMPOSE_PATH_SEPARATOR` | The published Compose file; the separator keeps the `oci://` reference whole |
| `COMPOSE_PROJECT_NAME` | Scopes the proxy, daemon and their volumes, and names the project's folder in sessions, `/workspace/<name>` (default: the folder name) |
| `COMPOSE_PROFILES` | `docker`, `publish` and `ssh`, comma-separated (default `docker,publish`) |
| `SANDBOX_UID`, `SANDBOX_GID` | Your user, which runs the agent |
| `SANDBOX_REFERENCE` | Optional host folder, read-only at `/reference`; empty or omitted for project only |
| `SANDBOX_PUBLISH_PORTS`, `SANDBOX_PUBLISH_ADDRESS` | Ports to forward to the host, and their address (default `127.0.0.1`) |
| `SANDBOX_PUBLISH_PORTS_2`, `_3`, `SANDBOX_PUBLISH_UDP_PORTS`, `_2`, `_3` | More TCP slots, and UDP slots; see [Publishing ports](#publishing-ports-to-the-host) |
| `SANDBOX_DAEMON_EGRESS` | `proxied` (default) or `direct`; see [Direct egress for containers](#direct-egress-for-containers) |
| `SANDBOX_DOCKER_DATA` | `ephemeral` (default) or `persistent`; see [Keeping Docker data](#keeping-docker-data) |
| `SANDBOX_SSH_KEY_DIR` | SSH private keys (default `~/.config/ai-coding-sandbox/ssh-keys`) |
| `SANDBOX_SSH_KEY_LIFETIME` | How long unlocked keys stay loaded (default `8h`) |
| `SANDBOX_DOCKER_MEMORY` | The daemon's memory limit (default `4g`) |

A variable set in your shell overrides `.sandbox/env` for one launch, for
example `SANDBOX_PUBLISH_PORTS=3000 sandbox`. `--profile` on the command line
replaces `COMPOSE_PROFILES` instead of adding to it.

To add, change or remove a reference later, edit only `SANDBOX_REFERENCE`
and start a new session. With no reference, Compose mounts `/dev/null`
read-only at `/reference` as a placeholder; no extra host directory is exposed.

### Upgrading an older configuration

Projects work at `/workspace/<COMPOSE_PROJECT_NAME>`. The agents keep
conversations and memory by folder in state that every project shares, so
each project needs a folder of its own; earlier releases put most projects
at `/workspace` itself, where they shared one history and memory. Older
`.sandbox/env` files need these changes, which take effect with this release:

- Move `CONTEXT7_API_KEY` to `.sandbox/agent.env`. Compose no longer reads
  it from `.sandbox/env`.
- Remove `SANDBOX_PROJECT`, `SANDBOX_PROJECT_PATH` and
  `SANDBOX_REFERENCE_MOUNT`. They are ignored: the reference is always at
  `/reference`, and the launch folder is no longer compared with a setting.

To keep a project's Claude conversations and memory, rename its folder in
the state volume before the project's first session on this release (once a
session has created the new folder, `mv` would nest the old one inside it). The old name is the old
working directory with `/` replaced by `-`, such as `-workspace` or
`-workspace-src-my-project`:

```sh
docker run --rm -v ai-coding-sandbox-claude-state:/state busybox \
  mv -n /state/projects/-workspace-src-my-project /state/projects/-workspace-my-project
```

## Start a session

```sh
sandbox                  # Claude Code
sandbox codex            # Codex
sandbox claude bash      # a shell in a Claude session, skipping agent setup
```

Start from the project root: bind mounts use the current folder, and a
session started elsewhere is refused. Each start checks the project's
configuration, signs the agent and GitHub in when needed, installs plugins
when their manifest changed, and starts the agent. Exit the agent normally;
`--rm` removes only the container. Several sessions, of either agent, can run
in one project at a time and share its proxy and daemon.

The agent gets the sandbox's guide, [`image/session-guide.md`](image/session-guide.md),
and its rules, [`image/session-rules.md`](image/session-rules.md), on every
launch. The image combines them into
`/usr/local/share/sandbox/session-instructions.md`, which Claude Code gets
through `--append-system-prompt-file` and Codex as developer instructions.
The guide explains the session's components, volumes, files, the
`.sandbox/` configuration, network, Docker, ports and SSH, and the commands
only you can run; the image also carries the base egress policy at
`/usr/local/share/sandbox/base-policy.yaml`. The rules govern what a
session may do.

Each launch checks the registry for the Compose file, so starting a session
needs network access even when everything is cached. Docker downloads the
pinned images once and reuses them.

### Session exit

When the agent exits normally, the session cleans up after itself before the
container goes:

- Local branches whose work is already in the default branch (merged,
  rebased or squashed into it) are deleted after a quick `git fetch --prune`.
  The default branch, the checked-out branch, branches checked out in a
  worktree and branches still at the default branch's tip stay. Each deletion
  prints the `git branch` command that restores it.
- When `.ai-scratchpad/` changed during the session, the agent tidies it
  non-interactively for up to three minutes, deleting notes for finished work
  and merging overlapping ones. Ctrl-C skips it, and it runs only at a
  terminal.
- Separately, each start deletes scratchpad entries untouched for the
  project's last `SANDBOX_SCRATCHPAD_DAYS` session days (default 7). Only
  days with a session count, so time away from a project does not age its
  notes.

Set these in `.sandbox/agent.env`: `SANDBOX_EXIT_CLEANUP=off` skips both exit
steps, `SANDBOX_EXIT_CURATE=off` only the tidy-up, and
`SANDBOX_SCRATCHPAD_DAYS=off` keeps scratchpad entries indefinitely.

## Files and mounts

| Path in the session | Access |
| --- | --- |
| The project, at `/workspace/<COMPOSE_PROJECT_NAME>` | Writable; the working directory |
| `/reference`, when configured | Read-only |
| `.sandbox/` in the project | Read-only |
| `.ai-scratchpad/` in the project | Writable agent scratch space, ignored by Git; tidied by the agent at exit, and entries untouched for the project's last `SANDBOX_SCRATCHPAD_DAYS` session days (default 7, `off` keeps them) are deleted at start |
| `~/.claude` and `~/.codex`, the agents' state volumes | Writable, shared by all projects |
| `/tmp` | Writable, emptied whenever the container starts |
| `~/.ssh` | `.sandbox/ssh`, read-only |

Everything else, including the root filesystem, `/run` and the home
directory, is read-only. The agent runs as your UID and GID, with no
capabilities and `no-new-privileges`. The image entrypoint provides passwd and
group entries for that UID through `libnss-wrapper`, so any UID works; use
command overrides rather than `--entrypoint` to keep it. Both agents' CLIs
are in the one agent image, and every session mounts both state volumes, so
either agent can run the other with its sign-in (for example, Claude handing
a build stage to `codex exec`). Each session can therefore read both agents'
credentials. `SANDBOX_AGENT` names the agent the session starts;
`GH_CONFIG_DIR` is that agent's state volume's `gh` folder.
`XDG_CONFIG_HOME` defaults to one folder both agents share, `~/.claude/xdg`
in Claude's state volume, so plugin settings, Ponytail Band ledgers and tool
config (`go env`, Composer, Git, pip, Ruff) persist with a read-only home and
are the same whichever agent runs, including a Codex build that Claude
started. An explicit `XDG_CONFIG_HOME` is preserved. The home is `/home/agent`;
`/home/claude` and `/home/codex`, the homes of the former per-agent images,
link to it, so paths saved in existing state still resolve.

Both agents run without their own bubblewrap sandboxes, which Docker's default
seccomp profile blocks. The container's boundary replaces them. The image
sets `CODEX_BUILD_SANDBOX=danger-full-access`, so a Codex that another agent
runs as a builder (phased-delivery's `codex-build.sh`) does the same instead
of failing to start its own sandbox. Codex's system configuration,
`/etc/codex/config.toml` from `codex/config.toml`, makes `danger-full-access`
the default for plain `codex exec` as well; the user's
`~/.codex/config.toml`, `-c` and `--sandbox` still override it.

## Egress policy

Agents have only an internal network. All traffic goes through
`egress-proxy`, the only service with an uplink, which allows:

- HTTPS (`CONNECT` to port 443) to the base list in
  [`squid/base-policy.yaml`](squid/base-policy.yaml), built into the proxy
  image: the OpenAI, Anthropic and Context7 hosts, Claude's user content
  hosts (`claudeusercontent.com` and its subdomains), Google Cloud Storage
  (`storage.googleapis.com`, where Claude Code's `/plugin` reads install
  counts; any bucket is reachable there), GitHub (with its Git LFS
  storage bucket `github-cloud.s3.amazonaws.com`, not the rest of S3), the
  VS Code Marketplace for an attached window's extensions
  (`marketplace.visualstudio.com`, `*.gallery.vsassets.io`,
  `*.gallerycdn.vsassets.io` and `main.vscode-cdn.net`), a broad list of
  documentation, reference, Q&A and source code sites (official language,
  framework, OS and tool documentation, standards bodies, Stack Overflow and
  Stack Exchange, Codeberg, Bitbucket and other source browsers) for reading
  with WebFetch or `curl`, GitLab
  (`gitlab.com` and its subdomains), Docker Hub, GHCR and LSCR (`ghcr.io`
  and `lscr.io`, including subdomains), and the Go module proxy and
  checksum database (`proxy.golang.org` and `sum.golang.org` only), PyPI
  (`pypi.org` and `files.pythonhosted.org`), and
  Ubuntu's `archive.ubuntu.com`, `security.ubuntu.com` and
  `keyserver.ubuntu.com`.
  Anthropic, Claude and GitHub Copilot entries allow the apex domains and
  their subdomains (`anthropic.com`, `claude.ai`, `claude.com`,
  `claudeusercontent.com`, `githubcopilot.com`);
- SSH (`CONNECT` to port 22) to `gitlab.com`, from the base list's `ssh`
  section; its host key still belongs in `.sandbox/ssh/known_hosts`;
- plus the project's approved additions in `.sandbox/egress-policy.yaml`:
  `https` (`CONNECT`, port 443 by default), `http` (plain HTTP, port 80 by
  default) and `ssh` (`CONNECT`, port 22 by default), each entry a bare
  name or `name:port` for another port, and `hosts` pins
  (`name: IPv4 address`) for names the proxy cannot resolve. An entry allows
  only its own port and method. The former `http_8888` section is retired:
  list its names under `http` as `name:8888`.

A project whose work cannot fit an allowlist can set `unrestricted_out: true`
at the top level of its policy instead (`unrestricted: true`, its older name,
works the same). Once approved, the proxy allows every
host and port for that project folder: HTTPS and SSH tunnels and plain HTTP.
That removes egress filtering for the project, so an agent misled by what it
reads could send data anywhere; `trust` warns about it, and each session
start repeats the warning. The networks stay internal, so traffic that
ignores the proxy variables (raw TCP, UDP, DNS lookups outside the proxy)
still cannot leave, and the session daemon's containers proxy only HTTPS;
[direct egress](#direct-egress-for-containers) is the opt-in for those.

The documentation list leaves out package registries, hosts where anyone
can create a subdomain (such as `*.readthedocs.io`) and sites that accept
anonymous edits (such as Wikipedia), since those could carry data out; a
project adds them to its own policy if it needs them. The session guide tells
agents to ask for a refused documentation host by name, with the policy
entry and `trust` command, instead of giving up.

Everything else gets a 403 from the proxy. Clearing the proxy variables only
removes the route. Package registries other than Go's and PyPI are not in
the base list (Go modules are verified against `sum.golang.org` and install
no code that runs on their own). PyPI is allowed so agents can install
Python packages into a virtual environment in the project or `/cache`;
packages run their own code at install and import, inside the session's
limits, so review what an agent installs.
`registry.npmjs.org` would let any agent install npm packages with automatic
approval, so npm-sourced plugins cannot install. The agent image turns off Claude Code's
the optional traffic that would need more hosts (telemetry, error reporting,
claude.ai MCP connectors and auto-updates).

A project's additions apply only after approval. The `sandbox` shell command
approves them automatically before launching an agent. For direct Compose
launches, approve them manually:

```sh
sandbox-trust     # docker compose --env-file .sandbox/env run --rm trust
```

`trust` shows the additions, or what changed since the last approval, and
records the approval in the shared trust volume for this project folder.
Its `--yes` option skips the confirmation prompt while retaining validation;
the shell function uses it during startup. It
has no network, and the proxy mounts that volume read-only, so nothing in a
session can approve its own policy. Comment and layout changes keep an
approval; a new entry withdraws it until you approve again. An unapproved or
invalid policy leaves the base policy in force, and the session start says so.

The proxy applies the policy when it starts, and reloads it in place on
request without dropping connections. To change the policy while a session is
running, edit `.sandbox/egress-policy.yaml` and run `sandbox-trust` in another
terminal on the host: after approval it reloads the running proxy, and the
session can use the new entries at once. The `sandbox` command does the same
for a running proxy whose policy is out of date. After approving a change with
a direct Compose command while sessions are running, reload it yourself:

```sh
docker compose --env-file .sandbox/env exec egress-proxy sandbox-proxy-config --reload
```

A change that is not approved reloads to the base policy alone.

SSH entries can specify a port for each destination:

```yaml
ssh:
  - standard.example
  - server.example:2222
```

The first entry allows port 22; the second allows only port 2222 on
`server.example`. Ports must be decimal integers from 1 to 65535 without
leading zeros. Changing a port requires approval again. The proxy allows
CONNECT to the approved destination and port; it does not inspect the tunnel
to verify that the traffic is SSH.

## Docker

With the `docker` profile, `docker` and `docker compose` in the session drive
the project's own rootless daemon at `DOCKER_HOST=tcp://docker:2376`, never
the host daemon. The daemon requires mutual TLS. Agents mount only the client
certificate, read-only, and the daemon keeps its CA key. It has no published
port, so nothing outside the project's internal network can reach it.

Root in the daemon's containers maps to your user, so files they write into
the project are yours; other container UIDs map to a subordinate range. The
daemon runs as any UID from 500 to 65533 with a group equal to that UID, so
when your GID differs it uses the UID and says so. It needs these exceptions,
which apply to the `docker` service alone:

| Setting | Why |
| --- | --- |
| `cap_add: SETUID, SETGID` (all others dropped) | The setuid `newuidmap` and `newgidmap` helpers write the user-namespace ID maps. |
| No `no-new-privileges` | Those helpers gain their file capabilities through exec, which `no-new-privileges` blocks. |
| `seccomp=unconfined` | Docker's default profile blocks user-namespace creation and mounting. |
| `systempaths=unconfined` | RootlessKit mounts a fresh `/proc`, which the masked paths prevent. |
| `label=disable` | SELinux confinement blocks the daemon's mounts. |
| `/dev/net/tun` | `slirp4netns` networking for the daemon's containers. |

The service is never privileged, so a breakout from the daemon's user
namespace lands as your unprivileged user in a capability-free container. Its
root filesystem is read-only, and it is limited to 4096 processes and
`SANDBOX_DOCKER_MEMORY`. Rootless mode has no cgroup delegation here, so
per-container `--memory` and `--cpus` limits do not apply, and privileged
containers do not start.

The daemon mounts only the project, writable, and `.sandbox/`, read-only, at
the same paths as in the agent, so bind mounts in `docker run -v` and Compose
files resolve. Build contexts are sent from the agent and need no mount.
Nothing filters bind mount sources: any path in the daemon's container can
be mounted, including its certificate volume at `/certs` with the CA key.
That gives a container no more than the agent's own client certificate
already does, against this daemon only; the session rules forbid mounting
those paths.

Besides the TLS port, the daemon listens on `/var/run/docker.sock` inside
its own mount namespace, which agents see as `SANDBOX_DOCKER_SOCKET`.
Containers that manage containers (schedulers, CI runners, Testcontainers)
bind-mount it as on a normal host,
`-v /var/run/docker.sock:/var/run/docker.sock`. It reaches the same rootless
daemon with the same rights as the agent's TLS client: privileged containers
stay refused and host paths stay out of reach. Container root owns it, so
non-root containers need `group_add: ["0"]`. The daemon ends with the
session group even if Docker clients are still connected.

Containers have no direct Internet route. The daemon pulls through the proxy,
so a registry must be allowed; the base policy has Docker Hub, GHCR and LSCR.
GitHub Container Registry's blobs use the existing `.githubusercontent.com`
entry. The agent's Docker client configuration (`DOCKER_CONFIG=/tmp/docker`)
gives every build and container
`HTTPS_PROXY`, with `NO_PROXY` covering only `localhost`. It sets no HTTP
proxy, so containers reach each other over plain HTTP by name. Services that
call each other over HTTPS need those names in their own `NO_PROXY`. A port a
container publishes in the daemon is reached from the agent at
`docker:<port>`.

### Direct egress for containers

Some workloads cannot use a proxy at all: game servers, peer-to-peer and
UDP services, or clients that connect to arbitrary ports. For a project that
needs them, set `SANDBOX_DAEMON_EGRESS=direct` in `.sandbox/env` and start a
new session. The daemon then joins `session-daemon-direct`, a network with
its own outbound route that no other service joins, instead of the internal
`session-daemon-proxied`, so its containers and builds reach any host, port
and protocol directly. Any other value stops the launch.

This removes egress filtering for everything that runs in the daemon, and
the agent drives the daemon, so it can reach and send data anywhere,
including your local network, by running a container. Use it only for
projects that need it. The agent's own container stays on the internal
network with the proxy as its only route, the setting lives in `.sandbox/`,
which sessions mount read-only, every session start warns while it is on,
and the daemon's other limits (rootless, the project-only mounts, no
privileged containers) are unchanged. The agent's Docker client then sets no
proxy for containers, since the proxy would only refuse destinations their
route allows.

With ephemeral data, the daemon starts empty. When the session group ends,
it gives running containers 2 seconds to stop by default
(`SANDBOX_DOCKER_STOP_TIMEOUT`) before wiping its data. To keep images,
containers, volumes and build cache, see
[Keeping Docker data](#keeping-docker-data).

### Keeping Docker data

To keep images and build cache between sessions, set
`SANDBOX_DOCKER_DATA=persistent` in `.sandbox/env` and start a new session.
The daemon then neither wipes its data root when it starts nor when it stops,
so images, containers, volumes and build cache stay in the project's
`docker-data` volume. Registry logins belong to each session's client and
still end with it. Containers stop with the daemon and restart
on the next start only if they have a restart policy. Any other value than
`ephemeral` or `persistent` stops the daemon at launch.

This trades a clean start for speed. Whatever one session leaves in the
daemon, including a tampered image, cache entry or container with a restart
policy, is there for every later session of the project, so the clean slate
no longer limits what a misbehaving session can leave behind. The data stays
in this project's daemon, which keeps its rootless, unprivileged and
network limits. The volume grows until you prune it: run
`docker system prune` in a session, or, with no session running, remove
everything on the host with
`docker volume rm <COMPOSE_PROJECT_NAME>_docker-data`. Setting it back to
`ephemeral` wipes the data at the next start.

### Publishing ports to the host

To reach a service you are building from your machine, set
`SANDBOX_PUBLISH_PORTS` to a port or a range such as `8000-8009` and start a
new session. Ports that are not contiguous go in `SANDBOX_PUBLISH_PORTS_2`
and `SANDBOX_PUBLISH_PORTS_3`, and UDP ports in `SANDBOX_PUBLISH_UDP_PORTS`,
`_UDP_PORTS_2` and `_UDP_PORTS_3`, each a port or a range, at most 100 ports
in all. A game server, for example:

```sh
SANDBOX_PUBLISH_ADDRESS=0.0.0.0
SANDBOX_PUBLISH_UDP_PORTS=7777-7778   # game traffic
SANDBOX_PUBLISH_PORTS=27020           # RCON
```

Relayed UDP reaches the container from the forwarder's address, and each
client's relay ends after 5 minutes of inactivity. The `publish` service
forwards each host port, on `127.0.0.1` unless `SANDBOX_PUBLISH_ADDRESS` says
otherwise, to the same port on the daemon, so `docker run -p 8080:80 …` in
the session serves `http://127.0.0.1:8080`. Use `0.0.0.0` only on a trusted
network; an SSH tunnel to a loopback port is the safer way to reach a headless
host. A host port that is already in use stops the launch.

Containers publish UDP the usual way (`-p 7777:7777/udp`).

The forwarder runs as `nobody`, read-only, with no capabilities and only its
read-only lifecycle socket mount. It joins the internal network and
`session-publish`, the only other network outside the proxy. With outbound
NAT disabled, traffic on `session-publish` enters only from the host. The
forwarder ends with the session group.

## SSH

SSH is off unless `COMPOSE_PROFILES` includes `ssh`. Keep private keys
outside the project and every reference folder, in `~/.config/ai-coding-sandbox/ssh-keys` or
`SANDBOX_SSH_KEY_DIR`, at mode `0600`. Passphrases are optional; without one,
anyone who can read a private key file can use it. A session refuses to
start when the key folder is inside the project or reference folder. The
`sandbox` shell command unlocks keys automatically when none are loaded. If
its final check waits for a group to stop, it unlocks again for the new group.
For direct Compose launches, use the command below to unlock keys. If it
starts a new group, start a session within two minutes.

```sh
sandbox-unlock    # docker compose --env-file .sandbox/env run --rm ssh-unlock
```

`ssh-unlock` loads the keys into the project's `ssh-agent` service, asking
for a passphrase only when a key requires one. It refuses keys readable by
others. Only those two services mount the key folder, and neither has a
network. Sessions get only the agent's socket (`SSH_AUTH_SOCK`), so they can
authenticate with the keys but cannot read or copy them. The `ssh-agent`
service and its unlocked keys end with the session group. Keys can expire
earlier according to `SANDBOX_SSH_KEY_LIFETIME`, and a session warns when
none are unlocked.

`ssh host` then works for names in the project policy's `ssh` list, through
the proxy. Put `User` and other client settings in `.sandbox/ssh/config` and
the hosts' keys in `.sandbox/ssh/known_hosts`. Both are read-only in the
session, and the image's client configuration sets
`StrictHostKeyChecking yes`, so the agent cannot accept a new host key. For an
unknown host it runs `sandbox-ssh-hostkey <host>`, which reads the key through
the proxy with every authentication method disabled and prints the exact
`known_hosts` line with its fingerprint; check the fingerprint before adding
it. A key that differs from the listed one is reported as a change, with no
line to paste. The session rules also forbid jumping from a host to another
one, agent forwarding and SSH port forwards without your permission for the
request at hand.

For an entry such as `server.example:2222`, use `ssh -p 2222 server.example`
or configure an alias in `.sandbox/ssh/config`:

```sshconfig
Host my-server
    HostName server.example
    Port 2222
    User deploy
```

For a nonstandard port, its known-hosts entry uses `[server.example]:2222`.

## GitHub

Git reaches GitHub only over HTTPS. The image's `/etc/gitconfig` uses the
GitHub CLI's stored token as the credential helper and rewrites
`git@github.com:` and `ssh://git@github.com/` remotes to HTTPS, so existing
clones work unchanged and need no SSH. Each agent keeps its own GitHub login in
its state volume.

## Authentication

On the first start, or after credentials expire, the session runs the
agent's login and then GitHub's, printing a URL to open on any device:
Codex's device-code flow, and `claude auth login`, where you paste the
resulting code back. Without a terminal it prints the commands instead. To
manage logins without starting the agent:

```sh
sandbox claude sandbox-auth status    # exits 0 only when signed in
sandbox claude sandbox-auth login
sandbox codex sandbox-auth logout
sandbox claude gh auth login --hostname github.com --git-protocol https --web
```

`sandbox-auth` takes an optional agent, to sign in the one a session did not
start, such as Codex for builds handed off from Claude:

```sh
sandbox claude sandbox-auth codex login
```

Credentials stay in each agent's state volume, outside every project and
image. The headless image has no system credential store, so the GitHub CLI
may keep its token in plain text there.

## Context7

Context7 runs as a local stdio MCP process in the agent container, configured
at each start in the state volume: in Codex's `config.toml`, and as a
user-scope server in Claude Code's `.claude.json`. `CONTEXT7_API_KEY` from
`.sandbox/agent.env` raises its rate limits. The key reaches only the agent's
environment and is never stored in a volume. Each start checks it with one
library search, limited to five seconds, and reports the result without ever
stopping the launch.

## Claude Code settings

At each start, `claude/init.d/20-settings` sets
`skipDangerousModePermissionPrompt` in the volume's `settings.json`, leaving
other settings alone. This accepts the one-time bypass-permissions dialog, the
counterpart of Codex's automatic approval. The image also sets
`DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and
`ENABLE_CLAUDEAI_MCP_SERVERS=false`. Per-project plugins and settings belong in
the project's own `.claude/settings.json`.

## Bundled plugins

Each agent has a plugin manifest, [`codex/plugins.txt`](codex/plugins.txt) and
[`claude/plugins.txt`](claude/plugins.txt). Every start sets up both agents,
the started one first, since either may run the other. On the first start
after a manifest changes, its agent installs each plugin through its marketplace
command and records the manifest's checksum in the state volume; later starts
do no plugin work. Codex installs plugins only once it is signed in, and
Claude, in Codex sessions, likewise; until then the other agent's setup
stays quiet. The Context7 key is checked once per start. Both
manifests can name GitHub-hosted marketplaces (`marketplace owner/repo`),
cloned through the GitHub entries. Plugins that need the npm registry cannot
install. Claude's GitHub plugin requires `GITHUB_PERSONAL_ACCESS_TOKEN` in
`.sandbox/agent.env` and connects to `api.githubcopilot.com`, which the base
policy allows over HTTPS. Both agents include Ponytail from its own
marketplace, `DietrichGebert/ponytail`, with its lifecycle hooks, and the
user's own plugins from `bryanwieg/ai-coding-plugins`.
`check-sandbox` rejects malformed entries.

## Tools in the image

The agent image has Node.js, Python 3 with `pytest`, `pytest-timeout`, `pycodestyle`, Ruff, PyYAML,
Scapy and python-on-whales, the PHP CLI with the extensions OPNsense uses, Composer, PHPUnit and
PHP_CodeSniffer, Go with GCC for cgo, PowerShell 7 (`pwsh`), Git with Git LFS, the GitHub CLI, `jq`, ShellCheck, BSD make (`bmake`, no GNU make), `xmllint`, netcat, the OpenSSH client, and the Docker CLI with its `compose`
and `buildx` plugins.
The container supports source editing and lint, style and test tooling, not a
FreeBSD package build.

Go is copied from the pinned official `golang` image, which Dependabot
updates. The home is read-only and `/tmp` is `noexec`, while `go test` and
`go run` execute their builds, so `GOPATH` is `/cache/go` in the project's
`cache` volume, with `GOCACHE` and `GOTMPDIR` inside it. Compose names that
volume after the project, so no other project's session sees it; both agents
of the project share it, it persists between sessions, and `down -v` or
`go clean -cache -modcache` empties it. `go install` puts binaries in
`/cache/go/bin`, last on `PATH`, so they never shadow the image's tools.
`GOTOOLCHAIN=local` stops `go` from downloading other toolchains. GCC and the
C library headers are installed, so cgo and the race detector work. Modules
download through the base policy's `proxy.golang.org`; private modules that
bypass it need their Git host (GitHub and GitLab are in the base list).

The default shell is `/bin/bash` (both the login shell and `$SHELL`), and
both agent services use the hostname `sandbox`. Start one with
`sandbox claude bash` or `sandbox codex bash`. Its history lives in `/tmp`
(`HISTFILE`) and resets with the container.

PowerShell remoting to Windows hosts uses the existing SSH client, proxy
configuration, known hosts and forwarded agent. For an SSH-enabled host in
the project's approved SSH list, use:

```powershell
New-PSSession -HostName <host> -UserName <user> -Options @{ UpdateHostKeys = 'no'; BatchMode = 'yes' }
```

`UpdateHostKeys = 'no'` avoids SSH's `hostfile_replace_entries` warnings when
it tries to update the read-only known_hosts file. CIM objects (for example,
from `Get-CimInstance`) cannot be returned to the client because `libmi` is
absent. No WinRM or extra modules are installed. The `pwsh` wrapper sets
`XDG_CACHE_HOME`, `XDG_DATA_HOME` and `XDG_CONFIG_HOME` under `/tmp` for
PowerShell only, so it starts with a read-only home; this state is temporary.
PowerShell and its required .NET runtime are copied from Microsoft's pinned
.NET SDK image; the SDK itself is excluded from the agent image. The
PowerShell version follows that source image.

## VS Code

VS Code's Dev Containers extension can attach to a running session, so the
editor's language servers, terminal and debugger use the image's tools. The
home is read-only, so the images link `~/.vscode-server` and
`~/.vscode-remote-containers` to `/cache/vscode`, in the project's `cache`
volume; VS Code installs its server there once per project and VS Code
version. `down -v` or `rm -rf /cache/vscode` removes it.

Start a session as usual, then in VS Code (connected with Remote-SSH when
Docker runs on another machine) run **Dev Containers: Attach to Running
Container**, choose the session's `claude` or `codex` container and open
`/workspace/<COMPOSE_PROJECT_NAME>`. The window closes when the session ends.

By default VS Code carries host credentials and ports across the boundary.
Turn that off in your user settings before attaching:

```jsonc
"remote.autoForwardPorts": false,                       // publish ports through the forwarder instead
"dev.containers.copyGitConfig": false,
"dev.containers.gitCredentialHelperConfigLocation": "none",
"dev.containers.dockerCredentialHelper": false,
"dev.containers.mountWaylandSocket": false
```

Dev Containers also forwards your SSH agent when VS Code has one. In the
attached terminal, `echo $SSH_AUTH_SOCK` must print `/run/ssh-agent/agent.sock`
(the session's sidecar); if it names a `/tmp/vscode-*` socket, disable agent
forwarding for that connection (with Remote-SSH,
`"remote.SSH.enableAgentForwarding": false`).

Extensions run inside the container with the agent's permissions and reach
the network only through the egress proxy. The agent can also change the
server in `/cache/vscode`, so treat the attached window as untrusted: do not
open host folders or grant it anything the agent should not have.

## Migrate from run-sandbox

`run-sandbox` kept each agent's state in volumes named after the workspace
folder, such as `ai-coding-sandbox_claude-state`. After creating the shared
volumes, copy them over from any project that has a `.sandbox/env`:

```sh
SANDBOX_MIGRATE_FROM=ai-coding-sandbox docker compose --env-file .sandbox/env run --rm migrate-claude-state
SANDBOX_MIGRATE_FROM=ai-coding-sandbox docker compose --env-file .sandbox/env run --rm migrate-codex-state
```

`SANDBOX_MIGRATE_FROM` is the old workspace folder's name
(`codex-sandbox-workspace` for checkouts older than the rename). The copy
fills only an empty volume, so a second run changes nothing, and it never
modifies the old volume. To add a second old workspace's Claude conversations
and memory to state already migrated, add `SANDBOX_MIGRATE_MODE=merge`: it
copies only missing files and merges the prompt history, never overwriting
anything. Sign-ins, settings and plugins stay those of the first copy.

Claude keys conversations by folder: `run-sandbox` used
`/workspace/src/my-project`, and sessions use `/workspace/<COMPOSE_PROJECT_NAME>`.
Rename the folder as in [Upgrading an older
configuration](#upgrading-an-older-configuration) so `claude --resume` finds
earlier sessions. Once you have checked them, delete the
old volumes with `docker volume rm`, along with the leftover `sandbox/.env`,
`sandbox/.ssh/`, `sandbox/squid/egress-policy.yaml` and
`sandbox/.proxy-state/` in an old checkout.

## Reset

To discard one agent's sign-ins, sessions, memory and plugins, remove its
shared volume and create it again empty:

```sh
docker volume rm ai-coding-sandbox-claude-state && docker volume create ai-coding-sandbox-claude-state
```

`docker compose --env-file .sandbox/env down -v` in a project removes only
that project's own volumes (daemon data, certificates and the SSH socket).

## Troubleshooting

| Message or symptom | Fix |
| --- | --- |
| "Run sandbox-init-config first" | `.sandbox/env` lacks `COMPOSE_PROJECT_NAME` or `SANDBOX_UID`; start from the project root, or add them. |
| ".sandbox/env must belong to you" or "readable only by you" | Run the `chown` or `chmod 600` it prints. |
| "the SSH key folder is inside the project or reference root" | Move the keys out and set `SANDBOX_SSH_KEY_DIR`. |
| "…/ssh-keys holds files that this session could read" | A `run-sandbox` workspace's `ssh-keys/` still holds private keys; move them to the key folder. |
| "the project egress policy is not approved" or "is invalid" | Run `sandbox-trust`. |
| "SSH is enabled, but no keys are unlocked" | Run `sandbox-unlock`. |
| A 403 or a failed `CONNECT` in the session | The destination is not allowed; add it to `.sandbox/egress-policy.yaml` and approve it. |
| The Compose file or an image fails to download | Starting needs the registry; while the packages are private, `docker login ghcr.io` first. |
| A port is already allocated | Free the host port or change `SANDBOX_PUBLISH_PORTS`. |

## Images and releases

The Dockerfile has a shared `base` stage with all agent-independent tooling
and one `agent` target with both CLIs, each installed in its own stage and
layer from its pinned manifest (`claude/package.json` under `/opt/claude`,
`codex/package.json` under `/opt/codex`); `sandbox-agent-version claude` or
`codex` prints either version. The other targets are `session-init`,
`session-lifecycle`, `session-daemon`, `session-proxy`, `session-forwarder`
and `session-ssh-agent`.

`ENTRYPOINT` is `sandbox-entrypoint`, which supplies the runtime user's
identity and joins the broker through `sandbox-lifecycle run` when
`SANDBOX_SESSION=1`. The proxy, daemon, forwarder and SSH agent images run
their service scripts under `sandbox-lifecycle run`. The agent's default
`CMD`, `sandbox-start`, runs the executable scripts in
`/usr/local/libexec/sandbox/init.d/` in name order, then those of the agent
`SANDBOX_AGENT` names in `/usr/local/libexec/sandbox/<agent>/init.d/`, then
the other agent's, and then runs the named agent's launcher,
`/usr/local/libexec/sandbox/<agent>/agent`. It stays as the agent's parent,
passing it the terminal and default Ctrl-C handling and forwarding a stop or
hangup, and once the agent exits runs the scripts in
`/usr/local/libexec/sandbox/exit.d/` in name order, best effort, before
exiting with the agent's status. A `docker stop` skips them.
Each agent's `init.d` scripts, `agent` and `auth` come from `claude/` or
`codex/`; the shared scripts live in `image/`. Scripts that only make sense in a session check
`SANDBOX_SESSION=1`, which the Compose file sets, so the agent image also runs on
its own. `sandbox-init` uses a separate Alpine image containing only the
initializer script and standard system tools.

`release.yml` publishes every image to `ghcr.io/bryanwieg/ai-coding-sandbox` on
a push to `main` that changes an image input (host-side scripts, tests and
documentation do not), weekly to refresh apt and apk packages,
and on manual runs. All seven images rebuild together, sharing BuildKit layers
through the GitHub Actions cache.

Each release gets an ID from its UTC date, such as `2026.11.19`, with `_1`,
`_2` and so on for later releases the same day. Images are versioned as
follows; a rebuild the same day that changed the image appends `_1`, `_2`
and so on (`agent-2026.11.19_1`). The agent image holds both CLIs, so no
single agent version names it; `sandbox-agent-version` reports each:

| Image | Version tag | Moving tag |
| --- | --- | --- |
| Agents (Claude Code and Codex) | `agent-<release ID>` | `agent-latest` |
| Project initializer | `init-<release ID>` | `init-latest` |
| Lifecycle broker | `lifecycle-<image version>` | `lifecycle-latest` |
| Session daemon | `docker-daemon-<release ID>` | `docker-daemon-latest` |
| Egress proxy | `proxy-<release ID>` | `proxy-latest` |
| Port forwarder | `forwarder-<release ID>` | `forwarder-latest` |
| ssh-agent | `ssh-agent-<release ID>` | `ssh-agent-latest` |

An image whose rebuild has the same content as its newest version, ignoring
the build time and the commit label, keeps that version and digest, so a
release downloads again only the images that changed. `bin/release-tags`
names the versions; each image's commit is in its
`org.opencontainers.image.revision` label.

It then publishes `compose.session.yaml`, with every image pinned by digest
(`bin/pin-session-images`), as the Compose artifact
`ghcr.io/bryanwieg/ai-coding-sandbox-compose:<release ID>`, tags the commit
with the release ID, and moves the artifact's `latest` tag. The artifact's
`sandbox.images` annotation lists the image versions it pins, and the run's
summary shows them. The artifact is pushed with `oras` in the format
`docker compose publish` writes, because that command's secret check loads the
file uninterpolated and rejects its ports entry. While the repository is
public, every image and the artifact carry a build provenance attestation;
verify on demand with
`gh attestation verify oci://ghcr.io/bryanwieg/ai-coding-sandbox-compose:latest --owner bryanwieg`.
GitHub refuses attestations for private repositories owned by a user account,
so the release skips them while this one is private and the pinned digests
are the only check.

Dependabot checks Codex and Claude Code daily. Its weekly
maintenance group covers Docker images (including the SDK supplying
PowerShell and the `golang` image supplying Go), Compose images,
GitHub Actions, Context7 (`package.json`)
and Python tools (`requirements.in`, with every dependency locked by hash in
the `pip-compile` output `requirements.txt`). Dependency installs use independent build stages
so an update can reuse the other installs. Scheduled builds bypass the cache
for the apt and apk installation
stages, so packages such as the GitHub CLI receive updates even when no
pinned image version changes.

Dependabot's pull requests merge themselves once the Sandbox image workflow
passes (`dependabot-automerge.yml`). Any other pull request merges the same
way when it carries the `automerge` label (a merge commit, keeping its
commits) or `automerge-squash` (one squashed commit), through
`automerge.yml`: when the checks pass, or when the label is added after
they passed, and only if no commit arrived since. Adding the label is the
request to merge and release, for example
`gh pr edit <number> --add-label automerge`. A pull request that changes
nothing under the workflow's paths gets no checks and is never merged
automatically.

Merges by the auto-merge workflows do not trigger push workflows, so they
dispatch `release.yml` themselves.
Publishing uses the workflow's `GITHUB_TOKEN`; no registry secret is needed.
GHCR creates new packages as private: make the image and Compose packages
public once, so sessions pull without a login.

## Develop the sandbox

This repository is a project like any other. Its own `.sandbox/env` (ignored)
uses the source files and builds the images from this checkout instead of
pulling them:

```sh
COMPOSE_PATH_SEPARATOR=,
COMPOSE_FILE=sandbox/compose.session.yaml,sandbox/compose.dev.yaml
COMPOSE_PROJECT_NAME=ai-coding-sandbox-session
```

[`compose.dev.yaml`](compose.dev.yaml) only adds `build` sections and local
image names; `check-sandbox` verifies that it changes nothing else.

Before committing sandbox changes, run the structural check, the tests for
what you changed, and ShellCheck on changed scripts:

```sh
sandbox/bin/check-sandbox
sh sandbox/tests/test-session-init.sh    # and the other tests in sandbox/tests/
```

`check-sandbox` renders the Compose file and checks each service's
boundary: read-only root, dropped capabilities with only the documented
additions, `no-new-privileges` except on the daemon, which services may run as
root or reach a network, that only the forwarder publishes ports and only the
ssh services mount keys, the agents' mounts, external shared volumes, and
released images only. It also validates the base policy and plugin manifests.

After changing networks, mounts, privileges or the proxy, run the runtime
audit. It starts real sessions of both agents from this checkout in a
disposable project, with disposable volumes, and checks the boundary from
inside: identity, capabilities, read-only paths, `/tmp` reset, state
persistence, egress only through the allowlist, the daemon's isolation (TLS,
user mapping, only the project visible, its socket for containers, no direct
route, HTTPS proxy only), bind mounts, a published port reaching the host,
refused privileged containers, lifecycle socket isolation, session survival
across a broker restart, and group shutdown after the last session or an
explicit stop.

```sh
sandbox/bin/audit-sandbox
sandbox/bin/audit-sandbox --no-docker   # without the daemon and forwarder
```

The unprivileged rootless daemon does not start on GitHub's Ubuntu runners,
so CI runs `audit-sandbox --no-docker` and skips
`tests/test-session-daemon.sh` and `tests/test-session-forwarder.sh`. Run
those and the full audit locally after changing the daemon, the forwarder, the
Docker client hook or the Compose file. Pull requests also build and
smoke-test the agent image (`sandbox-image.yml`).
