# Phase 05: Close the test gaps

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md) and
[models-codex.md](models-codex.md).
Status: planned
Before: phases 01-04 built and in draft PR #12; the user asked to close the
test gaps found after CI passed (2026-11-21).
After: automated tests cover forced-end containment in service and agent
containers, the host functions against real containers, the startup-window
reset, and a broker container recreation; the new audit checks also run in
CI's `--no-docker` audit.

## Gaps not closed here, and why
- CI cannot run the session daemon (GitHub's runners cannot start the
  unprivileged rootless daemon; `.github/workflows/sandbox-image.yml`); the
  daemon and forwarder tests and the audit's Docker part stay local.
- The real Claude and Codex TUIs need signed-in agents at a terminal; they
  stay in phase 02's user inspection. The pty tests (01.3) and the
  `SANDBOX_SESSION=1` exit-hook test (02.3 fix) cover the mechanisms.

## Assumptions
- Verified: `setsid` is at `/usr/bin/setsid` in the `session-proxy` and
  `agent` images (checked with `command -v setsid` in both, 2026-11-21).
- Verified: `audit-sandbox` runs with `audit_docker=false` in CI
  (`sandbox-image.yml` line ~182) and uses its own project
  `sandbox-session-audit-$$` (`audit-sandbox` line 26), with `session()`
  (line ~97), the broker restart check (~250) and the `sandbox-stop` drain
  check (~270).
- Verified: `test-session-proxy.sh` holds a broker with `lifecycle_hold` and
  starts the proxy with `start_proxy` (~58); `test-session-state.sh` holds
  one with `lifecycle_hold` and has `entrypoint_bare` (~179).
- Verified: design.md "Forced end" layers 2-3: the wrapper hard-exits
  `grace + 2 s` after a stop and its exit (PID 1 in services, tini's only
  child in agents) ends every process in the container.

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 05.1 | Forced-end containment tests for a service and an agent | top | parallel with 05.2 | planned |
| 05.2 | Audit: real host functions, startup-window reset, broker recreation | top | parallel with 05.1 | planned |

## 05.1 Forced-end containment tests

Goal: a drain ends a service container and an agent container even while
a process that left the wrapper's process group and ignores SIGTERM runs
in it.

Context: design.md "Forced end"; the wrapper (`sandbox/lifecycle/run.go`)
SIGKILLs the child's process group after the grace and hard-exits
`grace + hardExitMargin`; a `setsid` process is outside that group, so only
the PID-namespace teardown (layer 3) ends it. Helpers in
`sandbox/tests/lifecycle-helper.sh` (`lifecycle_hold`, `lifecycle_mount`,
`lifecycle_drain`).

Contracts: none new.

Files:
- `sandbox/tests/test-session-proxy.sh`
- `sandbox/tests/test-session-state.sh`

Work:
1. Proxy test: with a proxy running on its own held broker, `docker exec -d`
   into it `setsid sh -c 'trap "" TERM; exec sleep 600'` (confirm with
   `docker exec … pgrep -f 'sleep 600'` that it runs); drain that broker;
   the container exits within 12 s (5 s grace + 2 s hard exit + margin).
   Check name: `a detached process does not keep the proxy container
   alive`.
2. State test: an agent container started as production starts it:
   `docker run --init` (tini as PID 1, the wrapper its only child), the
   image's normal entrypoint, `SANDBOX_SESSION=1`, and its own fresh
   broker's `agents` mount (not the held broker, which already lists a
   `claude` member). Its command: `setsid sh -c 'trap "" TERM; echo $$ >
   /tmp/detached.pid; exec sleep 601' & exec sleep 600`. Before draining,
   wait until `/tmp/detached.pid` exists and that PID is alive (`docker
   exec … kill -0`), and until the broker's `status` lists `claude`. Drain;
   the container exits within 17 s (10 s grace + 2 s + margin) with
   `docker wait` status 143 (the foreground `sleep` ended by SIGTERM).
   Check name: `a detached process does not keep the agent container
   alive`.
3. The proxy case likewise waits for its detached PID (written the same
   way) to be alive before draining, and checks exit status 0.
4. Each case measures the time from the drain request to `docker wait`
   returning and prints it in the pass line.

External inputs: none.

Done when:
- `sh sandbox/tests/test-session-proxy.sh` and
  `sh sandbox/tests/test-session-state.sh` pass, with both new checks `ok`.
- `shellcheck -x` is clean on both files.

Out of scope: production code; other test files.

Model basis: J1 F0 R1 C1 K2 P1 V1 S0 = 7 -> top by override (container
isolation and asynchronous shutdown: PID-namespace teardown under tini and
as PID 1).

## 05.2 Audit: real host functions, startup-window reset, broker recreation

Goal: the audit exercises the host functions in `sandbox/shell/sandbox.sh`
against real containers, the broker's startup-window reset, and a broker
container recreation, in both audit modes.

Context: `audit-sandbox` builds images, creates a disposable project and
runs sessions with `session()`; it already restarts the broker
(`restart --no-deps lifecycle`) and drains with the explicit stop. Host
functions (04.1): `sandbox-status`, `sandbox-stop`, the orphan watcher
(`_sandbox_watch`, launch label `ai-coding-sandbox.client=…`,
`_sandbox_stop_client`). Broker: in `starting`, a services-socket join
moves the deadline to `now + 120 s` (01.2).

Contracts: none new. The audit is `/bin/sh` and `sandbox.sh` needs Bash
or Zsh, so every host-function call runs in an explicit Bash process
given the absolute path, `bash -c '. "$1" && sandbox-status' bash
"$root_dir/shell/sandbox.sh"` (the same convention for `sandbox-stop` and
the watcher's launcher), started from the audit project's folder, with the audit's environment already exported (line ~46).
Direct `docker compose up` and `run` calls in these checks pass `--pull
never` (the images are prebuilt; the dev overlay's `pull_policy: build`
must not rebuild during a timed check).

Files:
- `sandbox/bin/audit-sandbox`

Work (place all four after the existing `sandbox-stop drains running
sessions` check and before the daemon section; all run in both modes;
each starts on a group the previous check has left stopped, using
`session()`'s wait):
1. Host functions against real containers: start a background session
   whose command installs a TERM trap that writes a marker file in the
   disposable project and then sleeps 60; wait until it has joined
   (`status` lists `claude`); then create one disposable one-off
   (`docker compose … run -d --pull never claude true`) and wait until it
   has stopped; `bash` running `sandbox-status` prints `agents=claude`; check
   `host sandbox-status lists the session`. Then `bash` running
   `sandbox-stop` exits 0, and within 40 s `docker ps -aq --filter
   label=com.docker.compose.project=$project_name` prints nothing (no
   running or stopped container is left) and the TERM marker exists (the
   graceful stop reached the agent, not only the `rm -f` fallback); check `host sandbox-stop ends
   and removes the group`.
2. Orphan watcher, arranged as `test-shell-functions.sh`'s watcher test
   (~309) arranges it: start `bash -c '. …/sandbox.sh; sandbox claude
   sleep 300' < /dev/null > LOG 2>&1 &` and record that launcher's PID;
   wait, bounded like the audit's existing background-session loop (~234),
   until a container with this project's label and an
   `ai-coding-sandbox.client` label runs and `status` lists `claude`; if
   the launcher exits first, fail at once and print LOG; `kill -KILL` that launcher PID and reap it (`wait`); within
   30 s that container is gone; check `host watcher stops an orphaned
   launch`. If the host launch needs a terminal and cannot run this way,
   stop and report it; do not add an option to `sandbox.sh`.
3. Startup-window reset: `docker compose … up -d --pull never lifecycle
   egress-proxy` (no agent); record the broker's container ID and its
   `.State.StartedAt`; read
   `remaining` from `status` at about 10 s and at about 100 s (it
   decreases); `docker compose … restart --no-deps egress-proxy` (a fresh
   services-socket join); poll until `status` lists `egress-proxy` again
and `remaining` reads at least 110; wait until
   130 s after the broker started (past its original window), confirm the
   broker's container ID and `StartedAt` are unchanged and
   `state=starting`, then run a
   short `session()` and confirm the same broker container admitted it
   (its ID and `StartedAt` are unchanged afterwards and its `status` lists
   the agent while the session runs); check `a helper join extends the startup window`.
4. Broker recreation: with a background session (sleep 60) joined, record
   the broker's container ID, the agent's container ID and the `services=`
   names `status` reports; `docker compose
   … up -d --no-deps --force-recreate --pull never lifecycle`; within 30 s
   the broker's container ID differs, its `status` lists the agent and
   every recorded service, and the same agent container is still running;
   then the session's command finishes with status 0; check `broker recreation
   keeps sessions`.
5. Every new check leaves no container of the audit project running when
   it finishes (stop with `sandbox-stop` or the explicit stop).

External inputs: none.

Done when:
- `sandbox/bin/audit-sandbox --no-docker` and the full audit pass with the
  five new checks `ok`, and no `sandbox-session-audit-*` network or
  container is left afterwards.
- `sh sandbox/tests/test-audit-session.sh` passes; `shellcheck -x` is clean.

Out of scope: `sandbox/shell/sandbox.sh` and every production file; if a
check shows a production bug, stop and report it instead of fixing it.

Model basis: J1 F0 R1 C1 K2 P1 V1 S2 = 9 -> top (K2: asynchronous
ordering with destructive container cleanup; S2: the watcher's
run-dependent branch; P1: adapting the stubbed watcher test).

## Notes
- Plan start (phase 05): 90dac50
- 2026-11-21 (user): "close the test gaps next", after PR #12 passed CI.
  Stages go to Codex, as before; the orchestrator runs Docker checks.
- 2026-11-21 (plan review round 1, Codex gpt-6.2-astra high): host calls
  run in explicit bash processes; the watcher check kills the launcher's
  own PID; the agent case runs under `--init` on a fresh broker and waits
  for the detached PID before draining, checking status 143; the reset and
  recreation checks track container IDs; the stop check requires no
  container at all, including a stopped one-off; `--pull never` on direct
  Compose calls; model bases re-scored.
- 2026-11-21 (plan review round 2): absolute path to `sandbox.sh` for the
  bash calls; `StartedAt` continuity in the reset check; a TERM marker so
  `sandbox-stop`'s graceful path is proven; bounded watcher startup with
  its log; recreation requires every prior service to rejoin and the
  session to finish 0; scores corrected. Further rounds kept refining the
  same checks, so the phase review covers the rest.
