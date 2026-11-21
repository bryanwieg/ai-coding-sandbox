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
2. State test: an agent container (`SANDBOX_SESSION=1`, a held broker's
   `agents` mount) whose command starts `setsid sh -c 'trap "" TERM; exec
   sleep 600' &` and then `exec sleep 600`; drain the broker; the
   container exits within 17 s (10 s grace + 2 s + margin). Check name:
   `a detached process does not keep the agent container alive`.
3. Each case measures the time from the drain request to `docker wait`
   returning and prints it in the pass line.

External inputs: none.

Done when:
- `sh sandbox/tests/test-session-proxy.sh` and
  `sh sandbox/tests/test-session-state.sh` pass, with both new checks `ok`.
- `shellcheck -x` is clean on both files.

Out of scope: production code; other test files.

Model basis: J1 F1 R1 C1 K1 P0 V1 S0 = 6 -> top (process-group and
PID-namespace semantics; timing).

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

Contracts: none new. The audit sources `sandbox/shell/sandbox.sh` in a
subshell with the audit's project environment exported
(`COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, and the rest already exported at
line ~46) and runs it from the audit project's folder.

Files:
- `sandbox/bin/audit-sandbox`

Work (place all four after the existing `sandbox-stop drains running
sessions` check and before the daemon section; all run in both modes;
each starts on a group the previous check has left stopped, using
`session()`'s wait):
1. Host functions against real containers: start a background session
   (sleep 60); `sandbox-status` (sourced) prints `agents=claude`; check
   `host sandbox-status lists the session`. Then `sandbox-stop`; within
   40 s no container of the audit project runs (`docker ps -q --filter
   label=com.docker.compose.project=$project_name`); check `host
   sandbox-stop ends the group`.
2. Orphan watcher: in a background subshell, source `sandbox.sh` and launch
   a claude session through the host's launch path with the command
   `sleep 300` (the same function `sandbox` uses for an agent with a
   command); once the labeled container runs, SIGKILL that subshell (not
   the audit's shell); within 30 s the labeled container is gone; check
   `host watcher stops an orphaned launch`. If the launch path needs a
   terminal, give the subshell `< /dev/null` the way the audit's
   `session()` does; do not add an option to `sandbox.sh`.
3. Startup-window reset: `docker compose … up -d lifecycle egress-proxy`
   (no agent), wait 100 s, `docker compose … restart --no-deps
   egress-proxy` (a fresh services-socket join), wait 30 s more (130 s
   after the broker started, past the original window), then run a short
   `session()`; it succeeds, and `status` showed `state=starting` just
   before it; check `a helper join extends the startup window`.
4. Broker recreation: with a background session (sleep 60) joined,
   `docker compose … up -d --no-deps --force-recreate lifecycle`; within
   30 s `status` lists the agent again and the session is still running;
   check `broker recreation keeps sessions`.
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

Model basis: J1 F0 R1 C1 K1 P0 V1 S1 = 6 -> top (real-Docker timing,
backgrounded host shell functions).

## Notes
- Plan start (phase 05): 90dac50
- 2026-11-21 (user): "close the test gaps next", after PR #12 passed CI.
  Stages go to Codex, as before; the orchestrator runs Docker checks.
