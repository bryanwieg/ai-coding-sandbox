# Handoff: central lifecycle broker for sandbox session groups

Draft specification and design for the next session to grill and plan with
the `plan-in-phases` skill (phased-delivery plugin, installed). Nothing here
is planned or built yet. Delete this file once the plan replaces it.

## Where things are

- Branch `lifecycle-broker`, from `origin/main` (796b754), in the worktree
  `.claude/worktrees/session-working-habits`. Holds only this file.
- PR #11 ("Stop shared sandbox services after the last agent exits") is
  closed in favor of this redesign. Its branch `fix/last-agent-service-shutdown`
  (head 3bb7fba) is checked out in the main checkout.
- Local-only branch `fix/last-agent-review-fixes` (not pushed) holds three
  review-fix commits on top of 3bb7fba, useful as reference code:
  - `6a75bd2` broker rejoin after a proxy restart; `sandbox-lifecycle lease`
    and host-side launch lease / drain wait; crash exit status; jq 1.8 fix.
  - `732a640` daemon-only lifecycle socket and pool; `tests/test-lifecycle.sh`
    (gofmt, vet, race tests in the Dockerfile's Go image) wired into CI;
    session rules; audit network-leak fix.
  - `d9f3b46` host-side orphan handling: client label, shell watcher,
    cleanup on return, `sandbox-stop`.
- Local `main` in the main checkout is 4 commits ahead of `origin/main` (the
  closed PR's commits); it was never pushed. Reset it when convenient.
- Pushes from the earlier session were blocked by the permission classifier;
  the user has since authorized any changes needed for this goal.

## The problem

Compose has no lifetime for a session group. `docker compose run --rm claude`
starts the dependencies (egress proxy, session daemon, forwarder, ssh-agent)
and never stops them; `--rm` removes only the run container, and only if the
client survives to do it.

On `main`, each service guesses its own end: the proxy and daemon count TCP
connections plus `/tmp/launch-hold` files, the agent entrypoint runs
`sandbox-proxy-lease` and `sandbox-docker-lease`, ssh-agent lives until its
keys expire (8 h), and the forwarder watches the daemon's DNS name. Stray
traffic keeps services up; keys and daemon data outlive sessions. A left-over
ssh-agent was observed on the user's machine.

PR #11 changed the signal to agent leases (right) but kept the logic spread
over every container: a broker inside the proxy, an observer, ready-file
loop, traps and deadline in each of four sidecar scripts, a detached hold in
the agent entrypoint, host-side lease and watcher, the dead standalone path
still present, and about ten timing constants across Go, shell, Compose
health checks and host functions. Every bug found in review came from two of
those pieces disagreeing. The user wants one central mechanism instead.

## Decisions made with the user

1. **One dedicated `lifecycle` service owns the group's state.** Not inside
   the proxy: coupling to squid restarts caused the "proxy restart kills
   every session" bug. Gets its own minimal image (approved).
2. **Go**, one static binary `sandbox-lifecycle` (`CGO_ENABLED=0`), copied
   into every image; everything else stays POSIX `sh`. Python was rejected:
   it would need an interpreter in minimal sidecar images (Alpine, socat,
   dind-rootless, possibly squid) and add a runtime to the key-holding and
   egress containers. A Go build stage already exists in `sandbox/Dockerfile`.
3. **Uniform wrapper for every container, agents included:**
   `sandbox-lifecycle run --role agent|service --grace N -- <command>` as
   PID 1's command. Prototype and verify the agent role first; fall back to
   a detached hold for agents only if the TTY checks below cannot pass.
4. **Host functions handle only what containers cannot see** (a dead
   client), in one place.
5. **Fresh branch, phased commits**; PR #11 closed (done).
6. The user authorized all changes needed (Dockerfiles, Compose, images,
   release tooling, session rules, boundary changes) for this goal.

## Draft design

### Broker (`lifecycle` service)

- Image: `FROM scratch` plus the static binary, user 13:13, read-only,
  `cap_drop: ALL`, `no-new-privileges`, `network_mode: none`, tmpfs `/tmp`.
  Restart on failure only (a crash should come back and clients rejoin;
  a normal stop exits 0).
- Every other session service depends on it being healthy. Health check:
  `sandbox-lifecycle ready` over the private control socket.
- One state machine: `starting` (no agent yet; 120 s) -> `active(n)` ->
  `idle` (0 leases; 2 s) -> `draining` (admission closed, services told to
  stop; up to 25 s) -> exit 0, which stops the container.
- SIGTERM to the broker (compose stop/down, `sandbox-stop`) drains everyone,
  agents included: they get the stop message, not a dropped connection.
- Sockets, each in its own volume (all mounted read-only by clients; connect
  works on read-only mounts, verified in PR #11's audit):
  - agents: claude, codex.
  - services: proxy, forwarder, ssh-agent; small pool.
  - daemon: the session daemon only, mounted at the services path so the
    wrapper needs no extra configuration; pool of 4. Its nested containers
    can bind-mount the daemon container's paths, so they must not reach the
    other services' socket (finding from PR #11 review).
  - control: private, inside the lifecycle container's `/tmp`, reached only
    through `docker compose exec lifecycle ...` from the host. Text protocol:
    `lease <seconds>` (a timed lease kept by the broker itself; no keeper
    process), `status`, `ready`.
- Client protocol on agent and service sockets: broker writes `A` on
  admission and `S` to tell a client to stop; any byte from a client ends
  its subscription. Dropped connection without `S` means the broker went
  away: rejoin for up to 30 s, then stop the child.

### Wrapper (`sandbox-lifecycle run`)

- Without `SANDBOX_LIFECYCLE=1` (standalone image tests), exec the command
  directly.
- Joins the role's socket (retry up to about 10 s for start ordering), fails
  clearly if refused, then starts the child with `Pdeathsig` (lock the
  spawning OS thread), so the child cannot outlive the wrapper.
- Service role: child in its own process group; SIGTERM to the child on `S`,
  on a lost broker or on the wrapper's own SIGTERM; SIGKILL to the group
  after the grace period; after the child exits, clean up its group. Exit
  with the child's status; a child exiting on its own with an error is a
  failure, a requested stop is not.
- Agent role: the child stays in the wrapper's (foreground) process group;
  the wrapper must not take the terminal and must catch, not ignore
  (ignored dispositions are inherited across exec), SIGINT, SIGQUIT and
  SIGTSTP; it forwards SIGTERM and SIGHUP.
- Agent prototype must pass, in a real container with a TTY: Claude and
  Codex TUIs including resize, Ctrl-C in the agent, Ctrl-Z and `fg` in
  `sandbox claude bash`, piped and non-interactive commands, exit hooks
  (`sandbox-start` runs `exit.d`), and `kill -9` of the wrapper taking the
  agent with it.

### Per-service scripts

Keep only service setup, then `exec sandbox-lifecycle run ...`. Removed:
standalone idle counting, launch-hold files, `sandbox-proxy-lease`,
`sandbox-docker-lease`, the daemon's proxy hold, the forwarder's DNS check,
ssh-agent's key-expiry exit, ready-file loops, `deadline`, `USR1` traps.
The daemon's ephemeral data wipe stays: before start and after dockerd
exits, inside its grace (22 s). The proxy keeps in-place policy reloads;
restarting it no longer affects sessions.

### Host (`sandbox/shell/sandbox.sh`)

One launch path for claude/codex: take a 30 s lease before preparation and
again before `compose run`; on "stopping", wait for the old group to exit
(up to about 40 s) so Compose starts it afresh; label the run container with
a per-launch id; a detached watcher (subshell + `nohup`, no `setsid`) stops
and removes it if the launching shell dies; on return, stop and remove any
container still carrying the label. Add `sandbox-stop` (`compose down`, all
profiles, volumes kept) and `sandbox-status` (broker status). Sessions
launched with plain `docker compose run` get no orphan protection; this is
the accepted limit, since a container cannot see its client die.

### Timing table (one place, Go constants plus one doc table)

| Setting | Value |
| --- | --- |
| Startup without an agent | 120 s |
| Idle after the last lease | 2 s |
| Service drain | 25 s |
| Rejoin window | 30 s |
| Admission retry | ~10 s |
| Host launch lease | 30 s |
| Host wait for a draining group | ~40 s |
| Grace: proxy, forwarder, ssh-agent / daemon / agent | 5 s / 22 s / 10 s |

## Facts verified in the earlier session

- Compose v5.5.1 `run` recreates a running dependency whose configuration
  changed (tested with a throwaway project), so an image update replaces old
  services at the next launch.
- A `compose run --rm` container keeps running and is never removed when
  its client gets SIGHUP or SIGKILL (tested). Plain `docker run --rm -i`
  likewise.
- Only `compose.session.yaml` sets `SANDBOX_SESSION`, always with the
  lifecycle variable in PR #11, so the standalone path is dead there.
- jq 1.8.1 parses `X and .a as $v | ...` as `(X and .a) as $v`; bind
  variables at the top of `check-sandbox` expressions.
- The runtime audit leaked one `session-daemon-direct` network per run
  (cleanup `down` ran without the direct setting). Nine such networks from
  Nov 19-20 remain on the user's machine and exhaust Docker's address pools;
  remove with
  `docker network ls -q --filter name=sandbox-session-audit- | xargs -r docker network rm`.
- Go is not installed on the host; run Go tests in the Dockerfile's pinned
  `golang` image (see `tests/test-lifecycle.sh` in `732a640`).
- Release matrix: `.github/workflows/release.yml` (`images` job),
  `sandbox/bin/pin-session-images`, `sandbox/compose.dev.yaml`,
  `tests/test-pin-session-images.sh` list the images; a new `lifecycle`
  image must be added to each.

## Open questions for the grill

- Broker image: `scratch` with the binary only, or reuse an existing image
  with another entrypoint (avoids a new release image)?
- Should the proxy depend on the broker for start ordering, or should the
  broker be the only service with no dependencies and everything else wait
  on it?
- Grace values and the 2 s idle window: keep, or lengthen idle given the
  host lease exists?
- Fallback behavior if the agent wrapper's TTY checks fail.
- Does anything outside this repository (the `ai-coding-plugins` projects,
  user scripts) rely on `sandbox-proxy-lease`, `sandbox-docker-lease`,
  launch-hold files or the services' standalone idle stop?

## Next step

In a new session in this worktree, run `plan-in-phases` with this file as
the draft specification and design: grill it, then write the phase files
next to it in `sandbox/plans/lifecycle-broker/`, then build with
`implement-in-phases`. Project rules in `AGENTS.md` apply throughout
(ShellCheck, `check-sandbox`, `audit-sandbox` and the local daemon and
forwarder tests for boundary changes, `git diff --check`, clean tree).
