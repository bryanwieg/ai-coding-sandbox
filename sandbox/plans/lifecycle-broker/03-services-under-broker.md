# Phase 03: Services under the broker

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md).
Status: planned
Before: phase 02 runs the broker in every session group and agents join it;
the proxy, daemon, forwarder and ssh-agent still end themselves (idle
counting, launch holds, the daemon's proxy hold, the forwarder's DNS check,
ssh-agent's key expiry), and the agent entrypoint still runs the leases.
After: each service image's `ENTRYPOINT` is `sandbox-lifecycle run NAME --
<its script>`; the scripts do setup only; the leases, launch holds and every
idle setting are gone; the session rules name the broker. The whole group now
ends 2 s after its last agent, plus each service's grace.

## Assumptions
- Verified: each service image has its script as `ENTRYPOINT` and no `CMD`
  (`sandbox/Dockerfile`: `session-daemon` `ENTRYPOINT
  ["/usr/local/bin/sandbox-dockerd"]`, `session-forwarder`
  `["/usr/local/bin/sandbox-forward"]`, `session-ssh-agent`
  `["/usr/local/bin/sandbox-ssh-agent"]`, `session-proxy`
  `["/usr/local/bin/sandbox-proxy"]`); Compose overrides the entrypoint only
  for `trust` (proxy image) and `ssh-unlock` (ssh-agent image), which must
  stay unwrapped.
- Verified: `sandbox-dockerd` adds its default flags only when it gets no
  arguments or only flags (`[ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]`); with the
  wrapper in front it still gets no arguments from Compose.
- Verified (03.1 builder, 2026-11-21): `sandbox/image/sandbox-proxy-config`
  appends `shutdown_lifetime 1 seconds` to the rendered config on start and
  reload, below the proxy's 5 s grace; `squid.conf` itself leaves it unset.
  (The planning read missed the renderer.)
- Verified: `ssh-agent -D` removes its socket when it gets SIGTERM, and
  then exits with status 2 (OpenSSH's `cleanup_exit(2)`; probe in
  `alpine:3.24.4` with `openssh-client`, 2026-11-21). So the script must
  not `exec` it: the wrapper would report 2 for a requested stop. The script
  already removes a stale socket at start (`rm -f "$socket"`).
- Verified: CI runs `test-session-proxy.sh` and `test-session-ssh-agent.sh`;
  `test-session-daemon.sh` and `test-session-forwarder.sh` run only locally
  (rootless daemon), per `.github/workflows/sandbox-image.yml`'s comment.
- Verified: every reference to the leases, launch holds and idle settings
  (search on 2026-11-20 for `proxy-lease|docker-lease|launch-hold|IDLE|
  START_GRACE|LAUNCH_HOLD|FORWARD_CHECKS|SSH_CHECK_INTERVAL`) is in the files
  of this phase, `sandbox/shell/sandbox.sh` and
  `sandbox/tests/test-shell-functions.sh` (phase 04), and the READMEs and
  `session-guide.md` (phase 04). Nothing outside this repository uses them.
- Verified (03.1, 2026-11-21: the proxy drained with an open tunnel in 2787 ms
  from the broker's `stop`, exit 0, no SIGKILL; within the test's 4 s and the
  5 s grace): was open: squid exits within 2 s of SIGTERM with the existing
  `shutdown_lifetime 1 seconds` while a CONNECT tunnel is open. Check in
  03.1's test (an open tunnel during the drain).

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 03.1 | Egress proxy runs under the broker | top | first | planned |
| 03.2 | ssh-agent runs under the broker | top | after 03.1 | planned |
| 03.3 | Session daemon and forwarder run under the broker | top | after 03.2 | planned |
| 03.4 | Retire the leases and the idle settings; session rules | top | after 03.3 | planned |

The stages are sequential because 03.1-03.3 each edit `sandbox/Dockerfile`.

## 03.1 Egress proxy runs under the broker

Goal: the proxy image starts squid under `sandbox-lifecycle run egress-proxy`,
with no idle logic, and its test proves it serves under a broker and stops
when the broker drains.

Context:
- `sandbox/image/sandbox-proxy`: renders config with `sandbox-proxy-config`,
  starts `squid -N -f /tmp/squid.conf` in the background, then counts
  connections (`accepted`, `connected`, `held`) until idle.
- `sandbox/tests/test-session-proxy.sh`: `start_proxy` (line ~50) starts the
  proxy container; the "Lifetime" section (from `# Lifetime:` to the end of
  the launch-hold case, lines ~370-440) tests idle stops.
- Helper from 02.3: `sandbox/tests/lifecycle-helper.sh` (`lifecycle_build`,
  `lifecycle_start`, `lifecycle_mount`, `lifecycle_hold`,
  `lifecycle_release`, `lifecycle_drain`, `lifecycle_field`).
- Wrapper (01.3): service role, grace 5 s for `egress-proxy`; exits 0 when a
  requested stop ends the child, 1 without a reachable broker (after 10 s).
- Compose's proxy health check reads `/tmp/squid.pid` and parses
  `/tmp/squid.conf`; unchanged.

Contracts:
- `session-proxy`: `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle", "run",
  "egress-proxy", "--", "/usr/local/bin/sandbox-proxy"]`.
- `sandbox-proxy` body: `set -eu`; `sandbox-proxy-config`; `exec squid -N -f
  /tmp/squid.conf`. Header comment: config rendering and in-place reloads
  (keep that part), and that the image's entrypoint runs it under the
  lifecycle broker, which stops it with the session group.

Files:
- `sandbox/Dockerfile`
- `sandbox/image/sandbox-proxy`
- `sandbox/tests/test-session-proxy.sh`

Work:
1. Change the entrypoint and the script as above; no squid setting
   changes (the renderer's 1 s `shutdown_lifetime` stays).
2. In the test: source the helper, build the broker, start one broker and
   `lifecycle_hold` it with the proxy image under test; `start_proxy` adds
   `$(lifecycle_mount "$proxy_broker" services)`, where `proxy_broker`
   defaults to that broker and a case sets it to B2 or B3. The no-broker
   case starts its container with `docker run` directly, without
   `start_proxy`'s wait for `/tmp/squid.pid`, which never appears there. Replace the whole "Lifetime" section
   with:
   - the proxy stops when the broker drains: start a fresh broker B2 without
     a hold, start a proxy on it with an open CONNECT tunnel through it,
     `lifecycle_drain B2`; the proxy container exits with status 0 within 10
     s, and it exits within 4 s of the drain with no SIGKILL from the
     wrapper (measure the time; this settles the squid assumption);
   - the proxy stops shortly after the last agent: broker B3 with a hold,
     proxy on it, `lifecycle_release B3`; the proxy exits 0 within 15 s;
   - without a broker (no mount) the proxy container exits 1 within 15 s and
     its log says `cannot reach the lifecycle broker`;
   - `trust` still runs with its entrypoint override (the existing
     `trust_cmd` cases cover it).
   Update the header comment's last clause accordingly.
3. Run `sh sandbox/tests/test-session-proxy.sh`.

External inputs: none new.

Done when:
- `sh sandbox/tests/test-session-proxy.sh` passes, including the new
  lifetime cases and every existing policy, reload and trust case.
- `sandbox/bin/audit-sandbox --no-docker` passes, and the full audit passes
  locally (AGENTS.md: proxy behavior changed).
- `sandbox/bin/check-sandbox` passes; ShellCheck clean for changed scripts.
- The open squid-shutdown assumption is resolved and noted.

Out of scope: removing the agent's `sandbox-proxy-lease` (03.4); the host's
launch-hold `touch` (phase 04); policy behavior.

Model basis: J1 F1 R1 C0 K2 P1 V0 S1 = 7 -> top (override 1: K = 2, the
egress boundary's only uplink and a retired code path)

## 03.2 ssh-agent runs under the broker

Goal: the ssh-agent sidecar runs `ssh-agent -D` under `sandbox-lifecycle run
ssh-agent` and ends with the group; keys still expire after their lifetime.

Context:
- `sandbox/image/sandbox-ssh-agent`: starts `ssh-agent -D -a "$socket" -t
  "$lifetime"` in the background, polls `ssh-add -l` to exit when no keys are
  left or none were loaded within the grace.
- `sandbox/tests/test-session-ssh-agent.sh`: `start_agent` (line ~43); cases
  `$prefix-grace` (line ~126) and `$prefix-expiry` (line ~134) test the old
  exits; `$prefix-none` (line ~143) follows.
- Helper and wrapper as in 03.1; grace 5 s for `ssh-agent`.
- `ssh-unlock` uses the same image with `entrypoint:
  ["/usr/local/bin/sandbox-ssh-unlock"]`, so it stays unwrapped.

Contracts:
- `session-ssh-agent`: `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle",
  "run", "ssh-agent", "--", "/usr/local/bin/sandbox-ssh-agent"]`.
- `sandbox-ssh-agent` body: `set -eu`; `socket=/run/ssh-agent/agent.sock`;
  `lifetime=${SANDBOX_SSH_KEY_LIFETIME:-8h}`; `rm -f "$socket"`;
  `ssh-agent -D -a "$socket" -t "$lifetime" >/dev/null &`; `agent=$!`;
  `stopping=false`; `trap 'stopping=true; kill -TERM "$agent" 2>/dev/null ||
  :' TERM INT`; wait in a loop until the agent is gone, keeping its status
  (the pattern in `sandbox/image/sandbox-start`); `rm -f "$socket"`; exit 0
  when `stopping` is true, else the agent's status. Header comment: it
  serves an empty agent for `sandbox-ssh-unlock`, keys expire after the
  lifetime, the sidecar ends with the session group, and a requested stop
  exits 0 (ssh-agent itself exits 2 on SIGTERM).

Files:
- `sandbox/Dockerfile`
- `sandbox/image/sandbox-ssh-agent`
- `sandbox/tests/test-session-ssh-agent.sh`

Work:
1. Change the entrypoint and the script.
2. In the test: source the helper; one held broker for the file;
   `start_agent` adds `$(lifecycle_mount B services)`. Replace the grace and
   expiry cases with:
   - a key unlocked with `SANDBOX_SSH_KEY_LIFETIME=3s` is gone from
     `ssh-add -l` after 5 s while the sidecar keeps running;
   - the sidecar exits 0 within 10 s when its broker drains (fresh broker),
     and the socket file is gone from the volume;
   - without a broker it exits 1 within 15 s.
   Update the header comment ("exits after its grace period or once its keys
   expire").
3. Run `sh sandbox/tests/test-session-ssh-agent.sh`.

External inputs: none new.

Done when:
- `sh sandbox/tests/test-session-ssh-agent.sh` passes, including the
  unlock, permission and socket-only client cases.
- ShellCheck clean; `sandbox/bin/check-sandbox` passes.

Out of scope: `sandbox-ssh-unlock`; the host's `ssh-unlock --if-needed`
flow (unchanged); Compose (the mount and dependency exist from 02.2).

Model basis: J0 F1 R1 C0 K2 P1 V0 S1 = 6 -> top (override 1: K = 2,
ssh-agent holds the user's keys, and the grace and expiry exits are a
retired code path)

## 03.3 Session daemon and forwarder run under the broker

Goal: the daemon and the forwarder run under `sandbox-lifecycle run docker`
and `run publish`; the daemon keeps only validation, its default flags and
the ephemeral wipe; the forwarder keeps its relays and their failure check.

Context:
- `sandbox/image/sandbox-dockerd`: validation (UID, `SANDBOX_DOCKER_DATA`,
  group), `wipe()`, the proxy hold (`start_proxy_hold`, `stop_proxy_hold`),
  default flags, then `dockerd-entrypoint.sh "$@" &` and the idle loop
  (`accepted`, `connected`, `held`, `stop`), then `wipe`.
- `sandbox/image/sandbox-forward`: `slots()` validation, one `socat` per
  port, then a loop checking relays and `getent hosts docker`.
- `sandbox/tests/test-session-daemon.sh`: `start_daemon` (line ~37); idle,
  launch-hold, proxy-hold and client-lease cases (`$prefix-grace`,
  `$prefix-launch-hold`, `$prefix-hold`, `$prefix-lease`, lines ~170-255)
  and the `keep_env` settings in the persistence case (lines ~293-330).
- `sandbox/tests/test-session-forwarder.sh`: starts a daemon with
  `SANDBOX_DOCKER_START_GRACE=600` (line ~51) and holds a client lease
  (line ~67); the "exits with the daemon" case.
- `sandbox/image/sandbox-start` shows the trap-and-wait loop to copy (wait
  again while the child still exists after a trapped signal).
- Wrapper grace: `docker` 22 s; `publish` 5 s. Compose `docker`
  `stop_grace_period: 25s` (02.2).

Contracts:
- `session-daemon`: `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle", "run",
  "docker", "--", "/usr/local/bin/sandbox-dockerd"]`.
- `session-forwarder`: `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle",
  "run", "publish", "--", "/usr/local/bin/sandbox-forward"]`.
- `sandbox-dockerd`: keeps the validation, `wipe()`, the default-flag block
  and its comments on `/run/docker.sock` (drop the sentence about the client
  lease); then `wipe`; `dockerd-entrypoint.sh "$@" &`; `daemon=$!`; `trap
  'kill -TERM "$daemon" 2>/dev/null || :' TERM INT`; wait in a loop until the
  daemon is gone, keeping its status; `wipe`; `exit "$status"`. Header
  comment: what it validates and wipes, and that it runs under the broker.
- `sandbox-forward`: keeps `slots()`, the relays, the UDP idle setting and
  the EXIT trap; the loop only checks every second that each relay still
  runs (`fail 'a port relay stopped; exiting.'`). With no ports set it still
  exits 0 at once (the wrapper then exits 0). Remove `interval`, `checks` and
  the DNS check, and the header's sentences on them.

Files:
- `sandbox/Dockerfile`
- `sandbox/image/sandbox-dockerd`
- `sandbox/image/sandbox-forward`
- `sandbox/tests/test-session-daemon.sh`
- `sandbox/tests/test-session-forwarder.sh`

Work:
1. Change both entrypoints and scripts. Also update the Dockerfile comment
   above `session-forwarder` ("… and exits with the daemon", line ~81): it
   ends with the session group.
2. Daemon test: source the helper; one held broker; `start_daemon` adds
   `$(lifecycle_mount B daemon)`. Remove the grace, launch-hold, proxy-hold
   and client-lease cases and `keep_env`. Add:
   - the daemon stops when its broker drains (fresh broker): the container
     exits 0 within 30 s and, with ephemeral data, the data volume holds no
     `docker` data root afterwards;
   - persistent data survives a drain and a new daemon start (rewrite the
     existing persistence case to stop through a drain instead of idling);
   - `docker` on the services socket is refused: start a daemon with
     `$(lifecycle_mount B services)`; it exits 75 at once;
   - without a broker it exits 1 within 15 s.
   Keep every other case. Update the header comment.
3. Forwarder test: its daemon and forwarder use one held broker (daemon on
   `daemon`, forwarder on `services`); drop `SANDBOX_DOCKER_START_GRACE` and
   the client lease, and `-e SANDBOX_FORWARD_INTERVAL=1` from
   `start_forwarder` (line ~91); replace "exits with the daemon" with "the forwarder
   exits 0 within 10 s when the broker drains". Keep the port, UDP, invalid
   value and limit cases. Update the header comment.
4. Run both tests locally (they cannot run in CI).

External inputs: none new.

Done when:
- `sh sandbox/tests/test-session-daemon.sh` and
  `sh sandbox/tests/test-session-forwarder.sh` pass locally.
- The full `sandbox/bin/audit-sandbox` passes locally (the daemon's start
  path changed).
- ShellCheck clean; `sandbox/bin/check-sandbox` passes.

Out of scope: the daemon's privileges and networks (unchanged); the agent
entrypoint (03.4); the audit (phase 04).

Model basis: J1 F2 R1 C0 K2 P1 V0 S1 = 8 -> top (override 1: K = 2, data
wipe and a retired path; F = 2 is two small scripts with their tests, kept
together because the forwarder test starts the daemon)

## 03.4 Retire the leases and the idle settings; session rules

Goal: nothing of the old lifetime mechanisms remains in the images: the
lease scripts are deleted, the entrypoint only sets up identity, the Docker
variables and the broker join, and the session rules name the broker.

Context:
- `sandbox/image/sandbox-entrypoint`: the block from `# Sessions
  (SANDBOX_SESSION=1), for every command` through the `until … leases_connected`
  loop starts the leases; the `getent hosts docker` check inside it clears
  the Docker variables when the docker profile is off, which stays.
- `sandbox/Dockerfile` `base` stage: `COPY` and `chmod` lists name
  `image/sandbox-docker-lease` and `image/sandbox-proxy-lease`.
- `sandbox/tests/test-session-state.sh`: the `entrypoint()` cases (from
  02.3) still assert lease behavior (`docker-calls` reconnects,
  `sandbox-proxy-lease` processes).
- `sandbox/image/session-rules.md` lines 35-37 name the leases.

Contracts:
- Entrypoint, after the identity setup: in a session with `DOCKER_HOST` set,
  `timeout 2 getent hosts docker` failing unsets `DOCKER_HOST
  DOCKER_TLS_VERIFY DOCKER_CERT_PATH SANDBOX_DOCKER_SOCKET`; then the
  session join from 02.3. No background processes.
- Session rules bullet: "Do not stop or interfere with the sandbox's own
  processes and services: the lifecycle broker (the `lifecycle` service) and
  `sandbox-lifecycle`, which runs each session process, the egress proxy,
  the session daemon, the port forwarder, and the ssh-agent."

Files:
- `sandbox/image/sandbox-proxy-lease` (delete)
- `sandbox/image/sandbox-docker-lease` (delete)
- `sandbox/image/sandbox-entrypoint`
- `sandbox/Dockerfile`
- `sandbox/tests/test-session-state.sh`
- `sandbox/image/session-rules.md`

Work:
1. Delete both lease scripts and their `COPY`/`chmod` entries.
2. Reduce the entrypoint as above; rewrite its comments.
3. In `test-session-state.sh`, replace the lease cases with: without a
   daemon, `DOCKER_HOST` is cleared; with `--add-host docker:127.0.0.1`, the
   three Docker variables stay; no `sandbox-*-lease` process exists in a
   session; drop the stub `docker` that recorded connections if nothing
   else uses it.
4. Update the session-rules bullet (boundary document; authorized by the
   user for this goal).
5. Search the tree outside `sandbox/plans/`, `sandbox/README.md`,
   `README.md`, `sandbox/image/session-guide.md`, `sandbox/shell/` and
   `sandbox/tests/test-shell-functions.sh` (phase 04) for `proxy-lease`,
   `docker-lease`, `launch-hold`, `_IDLE_`, `START_GRACE`, `LAUNCH_HOLD`,
   `FORWARD_CHECKS`, `FORWARD_INTERVAL`, `SSH_CHECK_INTERVAL`, and the
   phrases `stops itself`, `holds a connection`, `until its keys expire`,
   `exits with the daemon`, `idle connection`; there must be no hits.
6. Run `sh sandbox/tests/test-session-state.sh`,
   `sh sandbox/tests/test-session-init.sh`,
   `sh sandbox/tests/test-session-exit.sh`, `sandbox/bin/check-sandbox`,
   and the full `sandbox/bin/audit-sandbox` locally.

External inputs: none.

Done when:
- Step 5's search has no hits; the lease scripts are gone from the image
  (`docker run --rm --entrypoint sh IMAGE -c 'command -v
  sandbox-proxy-lease'` fails).
- The tests in step 6 pass, including the full audit (its last check: the
  services stop once the session ends).
- ShellCheck clean.

Out of scope: the host functions and their test (phase 04); the READMEs and
the session guide (phase 04).

Model basis: J0 F2 R1 C0 K2 P0 V0 S1 = 6 -> top (override 1: K = 2, a
retired code path and the session rules, a permissions document)

## Notes
- 2026-11-20: ssh-agent's keys end with the group (design decision 8); its
  `SANDBOX_SSH_KEY_LIFETIME` still caps how long a key stays loaded within a
  long session.
- 2026-11-20: The forwarder keeps its check that every relay still runs:
  that is a failure of the service itself, not a lifetime guess.
- 2026-11-20: Stages are sequential (shared Dockerfile). The leases go last
  so that each commit leaves sessions working: until 03.4 the agent
  entrypoint still holds leases the not-yet-switched services count.
- 2026-11-21 (03.1 builder stop): the renderer already appends
  `shutdown_lifetime 1 seconds`; the planned `squid.conf` change would have
  duplicated it. Kept the 1 s value, dropped `squid.conf` from 03.1.
- 2026-11-21 (03.1): test-session-proxy, check-sandbox, `audit-sandbox
  --no-docker` and the full audit pass. The first full audit failed only
  the direct-egress section: Docker's address pools were exhausted by ten
  empty `sandbox-session-audit-*_session-daemon-direct` networks leaked by
  earlier audits (the leak 04.2's cleanup fix addresses; one more leaked on
  the passing run). Removed them; the rerun passed.
