# Design: central lifecycle broker for sandbox session groups

Specification and design for the phased plan in this folder (`01-*.md` to
`04-*.md`). It replaces the earlier handoff draft; the decisions below were
settled with the user on 2026-11-20. Phase files link to its sections.

## Problem

Compose has no lifetime for a session group. `docker compose run --rm claude`
starts the dependencies (egress proxy, session daemon, forwarder, ssh-agent)
and never stops them; `--rm` removes only the run container, and only if its
client survives to do it. Today each service guesses its own end (the proxy
and daemon count TCP connections plus `/tmp/launch-hold` files, the agent
entrypoint runs `sandbox-proxy-lease` and `sandbox-docker-lease`, ssh-agent
lives until its keys expire, the forwarder watches the daemon's DNS name).
The guesses disagree, so services linger or stop early.

## Goal

One central, privilege-free mechanism decides the lifetime of every
container in a project's session group. Nothing else keeps its own timer.
**All of the old mechanisms are removed outright**; nothing stays for
compatibility (user, 2026-11-20).

## Decisions

1. **A dedicated `lifecycle` Compose service** (the broker) owns the group's
   state. It is not inside the proxy, so proxy restarts never affect sessions.
2. **Mechanism: thin socket clients (option B).** The broker sees agents
   through the connections they hold and tells services to stop through
   theirs. No Docker API, no host socket, no shared PID namespace (rejected:
   agents, ssh-agent and the daemon share the user's UID, so a shared PID
   namespace would let an agent reach the key holder through `/proc`).
3. **Go**, one static binary `sandbox-lifecycle` (`CGO_ENABLED=0`), copied
   into every session image; everything else stays POSIX `sh`.
4. **One wrapper for every long-running container**:
   `sandbox-lifecycle run NAME -- COMMAND...`. The name picks the role
   (agent or service), the grace period and the socket's allowed names. No
   fallback mechanism for agents: if the agent role fails a terminal check,
   the wrapper is fixed.
5. **Startup order comes from Compose** (`depends_on` with health checks):
   `lifecycle` has no dependencies and every session service and agent
   depends on it being healthy. **No host leases**: a fresh group waits up
   to 120 s for its first agent, and until one joins, every member joining
   the services socket (proxy, forwarder, ssh-agent starting) resets that
   window to 120 s from then, so a cold launch is covered from the moment
   Compose starts its services, however long an SSH passphrase prompt took
   before it (user, 2026-11-21). The daemon socket does not reset it, so
   daemon workloads cannot extend a lifetime; the proxy always starts
   before the daemon. **A launch never rejoins a group whose
   last agent has left**: `sandbox` waits for it to exit and starts a fresh
   group, so a changed configuration always applies (the user usually quits
   to change it). The idle window is short (2 s) so that wait is short; a
   launch joins a running group only while one of its agents is still
   running.
6. **The broker is always required** by service images. The agent image joins
   only in a session (`SANDBOX_SESSION=1`, the existing marker for
   session-only behavior); outside one it runs the command directly, as it
   does today for `sandbox-init`-style and test use.
7. **Broker image: `scratch`** with only the binary, a new released image
   `lifecycle`.
8. **ssh-agent is a plain service**: its keys end with the group; the next
   cold start asks for the passphrase again (`ssh-unlock --if-needed`).
9. **Host functions handle only what containers cannot see**: a dead
   launching client (orphaned run container), and waiting for a stopping
   group before a launch.
10. The user authorized the Dockerfile, Compose, image, release, proxy and
    session-rule changes needed for this goal.
11. **Stopping is explicit.** The control command `stop` drains every member,
    agents included (`sandbox-stop`). SIGTERM or SIGINT to the broker (Docker
    or Compose stopping or recreating its container, as after a release
    changes its image) makes it exit at once without telling anyone to stop:
    members rejoin the replacement within 30 s, as after a crash, and stop
    themselves only if none comes.

## Broker (`lifecycle` service)

- Image `session-lifecycle` (`FROM scratch`): `/usr/local/bin/sandbox-lifecycle`
  and the directories `/run/sandbox-lifecycle/{agents,services,daemon}`
  owned 13:13, mode 0755. `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle", "serve"]`,
  `USER 13:13`.
- Compose: read-only, `cap_drop: ALL`, `no-new-privileges`, `network_mode:
  none`, tmpfs `/tmp`, `restart: on-failure`, health check
  `sandbox-lifecycle ready`. One per-project volume `lifecycle` mounted
  read-write at `/run/sandbox-lifecycle`.
- **States**: `starting` (no agent has joined yet; drains 120 s after start
  or after the last services-socket join, whichever is later)
  -> `active` (one or more agents) -> `idle` (last agent left; drains 2 s
  later unless an agent joins) -> `draining` (admission refused, every member
  sent `S`; exits 0 when all members are gone or after 25 s). The control
  command `stop` drains at once, agents included. SIGTERM or SIGINT closes
  every connection without `S` and exits 0 at once (decision 11). A
  restarted or replaced broker starts in `starting` and its clients rejoin.
- **Sockets**, one per role, all in the `lifecycle` volume; clients mount
  only their role's subdirectory, read-only, at `/run/sandbox-lifecycle`, so
  every client connects to `/run/sandbox-lifecycle/lifecycle.sock`:

  | Socket (broker path) | Mounted by (subpath) | Names admitted | Pool |
  | --- | --- | --- | --- |
  | `/run/sandbox-lifecycle/agents/lifecycle.sock` | claude, codex (`agents`) | `claude`, `codex` | 64 |
  | `/run/sandbox-lifecycle/services/lifecycle.sock` | egress-proxy, publish, ssh-agent (`services`) | `egress-proxy`, `publish`, `ssh-agent` | 16 |
  | `/run/sandbox-lifecycle/daemon/lifecycle.sock` | docker (`daemon`) | `docker` | 4 |

  The daemon's nested containers can bind-mount the daemon container's
  paths, so they can reach only the daemon socket and fill only its pool.
- **Control socket**: `/tmp/sandbox-lifecycle-control.sock` inside the
  broker container, mode 0600, reached only through
  `docker compose exec lifecycle sandbox-lifecycle ready|status|stop`.

### Client wire protocol

1. Client connects and sends one line `join NAME\n` (at most 64 bytes)
   within 2 s.
2. Broker answers one byte: `A` admitted, or `R` refused and closes (state
   `draining`, pool full, malformed line, or a name not admitted on that
   socket).
3. Later the broker may send `S`: stop. It keeps counting the member until
   the client closes.
4. Any byte from the client after `join`, or EOF, ends its membership.
5. A connection lost without `S` means the broker went away: the client
   rejoins for up to 30 s, then stops its child.

### Control protocol

One request line, a reply, then close.

- `ready\n` -> `ok\n` unless `draining`, then `draining\n`.
  `sandbox-lifecycle ready` exits 0 on `ok`, 1 otherwise (health check).
- `status\n` -> `key=value` lines, in this order:

  ```
  state=starting|active|idle|draining
  joinable=yes|no
  remaining=<whole seconds until draining starts; 0 when active or draining>
  agents=<space-separated member names, join order>
  services=<space-separated member names, join order>
  ```

  `joinable=yes` only while `active`, or while `starting` with at least the
  5 s join margin left; `idle` and `draining` are never joinable (decision
  5). `sandbox-lifecycle status` prints the reply and exits 0, or exits 1
  when it cannot reach the broker.
- `stop\n` -> `ok\n`, then the broker drains (from any state; a second
  `stop` while draining also answers `ok`). `sandbox-lifecycle stop` exits 0
  on `ok`, 1 when it cannot reach the broker; it does not wait for the
  drain to finish.

## Wrapper (`sandbox-lifecycle run NAME -- COMMAND...`)

- Names: `claude`, `codex` -> agent role; `egress-proxy`, `docker`,
  `publish`, `ssh-agent` -> service role; anything else exits 2.
- Joins `/run/sandbox-lifecycle/lifecycle.sock`, retrying every 250 ms for
  up to 10 s. `R` exits 75 with `sandbox-lifecycle: the session group is
  stopping; start the session again.`; no admission within 10 s exits 1.
- Starts the child with the wrapper's stdio and environment, with
  `Pdeathsig: SIGKILL` (spawning OS thread locked), so the child cannot
  outlive the wrapper.
- **Service role**: child in its own process group. Stop (on `S`, a lost
  broker, or the wrapper's own SIGTERM, SIGINT or SIGHUP): SIGTERM to the
  child, SIGKILL to its process group after the grace period. After the
  child exits, SIGKILL whatever is left in its group. Exit status: the
  child's code; 0 when a requested stop ended it by signal; 1 after a lost
  broker; 128+signal otherwise.
- **Agent role**: child stays in the wrapper's (foreground) process group;
  the wrapper never touches the terminal; it catches (not ignores, since
  ignored dispositions are inherited across exec) SIGINT, SIGQUIT and
  SIGTSTP and does nothing with them; it forwards SIGTERM and SIGHUP to the
  child. Stop: SIGTERM to the child, SIGKILL to the child after the grace
  period. Exit status: the child's code, or 128+signal; 1 after a lost
  broker.
- When it is PID 1 (service containers, which have no `init`), it reaps every
  child; it never loses the main child's status to that reaping.

### Forced end (user requirement, 2026-11-21)

Every container of the group must end when the broker signals a stop, even
if its process hangs. Layers, each a backstop for the one before:

1. The wrapper sends SIGTERM, then after the member's grace SIGKILL to the
   child's process group (service) or the child (agent).
2. Once a stop has begun, a hard timer makes the wrapper exit
   `hardExitMargin` (2 s) after the grace, whatever the child's state, with
   status 1 and `sandbox-lifecycle: NAME did not stop in time; forcing
   exit.`
3. The wrapper's exit ends the whole container: in service containers it is
   PID 1 (no `init`; `check-sandbox` enforces it), and the kernel kills every
   process of a PID namespace when its init exits, including processes that
   left the process group; in agent containers it is tini's only child, and
   tini exits with it.
4. At its drain limit the broker logs the members still connected
   (`sandbox-lifecycle: did not stop in time: NAME ...`). It cannot kill
   other containers (no Docker access, by design).
5. The host is the last backstop: before a launch and in `sandbox-stop` it
   waits for every service container of the project to stop and, after its
   40 s bound, force-removes what still runs (`docker rm -f`), saying which.

## Per-service scripts

Only setup remains, and each image's `ENTRYPOINT` is the wrapper around its
script. Removed: idle counting, launch-hold files, `sandbox-proxy-lease`,
`sandbox-docker-lease`, the daemon's proxy hold, the forwarder's DNS check,
ssh-agent's key-expiry and start-grace exits, and their settings
(`SANDBOX_PROXY_IDLE_*`, `SANDBOX_PROXY_START_GRACE`,
`SANDBOX_PROXY_LAUNCH_HOLD`, `SANDBOX_DOCKER_IDLE_*`,
`SANDBOX_DOCKER_START_GRACE`, `SANDBOX_DOCKER_LAUNCH_HOLD`,
`SANDBOX_FORWARD_INTERVAL`, `SANDBOX_FORWARD_CHECKS`,
`SANDBOX_SSH_CHECK_INTERVAL`, `SANDBOX_SSH_START_GRACE`, and the lease
retry variables). The daemon still wipes ephemeral data before dockerd
starts and after it exits, within its grace. The proxy keeps in-place policy
reloads; squid's `shutdown_lifetime` fits inside its grace.

## Host (`sandbox/shell/sandbox.sh`)

- Before `ssh-unlock` and again before `compose run` of claude or codex:
  if the broker reports `joinable=no` (its last agent has left, or it is
  stopping), wait (up to 40 s) for the lifecycle container to stop, so
  Compose starts a fresh group with the current configuration; a broker that
  is not running needs no wait. The wait also covers the project's service
  containers: it ends when none runs, and at the 40 s bound it
  force-removes those still running (Forced end, layer 5). If the second
  wait waited and the project uses SSH, unlock again: the old group's keys
  are gone.
- Before `ssh-unlock` starts the group, make every image the launch needs
  present: `docker compose --env-file .sandbox/env pull --quiet --policy
  missing --include-deps --ignore-buildable SERVICE`, then `docker compose
  --env-file .sandbox/env build --quiet --with-dependencies SERVICE` (a
  no-op without `build:` sections). Slow pulls and builds then happen before
  the broker's startup window begins; `--policy missing` keeps offline
  launches working when the images are present.
- Accepted limit: a passphrase prompt left open longer than the 120 s
  startup window fails the unlock ("No SSH keys were unlocked"), which stops
  the launch; running `sandbox` again starts over.
- A launch while another session of the project still runs joins that
  group; Compose then recreates only the services whose configuration
  changed, under the running session, as it does today.
- Label each launch's run container with a per-launch id; a detached
  watcher (subshell + `nohup`, no `setsid`) stops and removes it if the
  launching shell dies; on return, stop and remove any container still
  carrying the label.
- `sandbox-stop`: send the broker `stop` (it drains every member, agents
  included) and wait (up to 40 s) for it to exit, remove what is left of the project's containers, including
  one-off run containers (`compose down` does not stop those; verified),
  then `compose down` for all profiles, volumes kept.
- `sandbox-status`: the broker's `status`, or a line saying no group runs.
- Sessions started with plain `docker compose run` get no orphan protection;
  a container cannot see its client die. Accepted limit.
- Accepted limit: a launch that joins an `active` group while Compose
  recreates a changed dependency fails if the group's other sessions all
  quit during that recreation; running it again starts a fresh group.

## Timing (Go constants in `sandbox/lifecycle/protocol.go`, one doc table)

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

## Verified facts

- Compose v5.5.1 `run` starts a dependency that has exited, and recreates a
  running one whose configuration changed (earlier session).
- Compose v5.5.1 `down` does not stop one-off `run` containers; `compose ps
  -a` lists them (probe on 2026-11-20).
- A `compose run --rm` container keeps running when its client gets SIGHUP
  or SIGKILL (earlier session).
- Connecting to a Unix socket on a read-only mount works (PR #11's audit).
- Nothing outside this repository (all of `~/src`) uses the lease scripts,
  launch-hold files or idle settings (search on 2026-11-20).
- jq 1.8.1 parses `X and .a as $v | ...` as `(X and .a) as $v`; bind
  variables at the top of `check-sandbox` expressions.
- Go is not installed on the host; Go tests run in the Dockerfile's pinned
  `golang` image (`go-upstream` stage).
- Reference code from the closed PR #11: branch `fix/last-agent-review-fixes`
  (`sandbox/lifecycle/main.go`, `sandbox/tests/test-lifecycle.sh`, the
  orphan watcher in `sandbox/shell/sandbox.sh`, the audit's network cleanup).
