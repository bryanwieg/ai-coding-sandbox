# Phase 04: Host side, audit and documentation

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md).
Status: planned
Before: phase 03 put every service under the broker and removed the old
mechanisms from the images; the host's `sandbox` function still touches
`/tmp/launch-hold`, has no orphan handling, `sandbox-stop` or
`sandbox-status`, and the audit and documentation describe idle stops.
After: the host waits for a stopping group, stops orphaned run containers,
and offers `sandbox-stop` and `sandbox-status`; the audit verifies the
broker's boundary and the group's end; the READMEs and the session guide
describe the broker with one timing table; this plan's design replaces the
handoff.

## Assumptions
- Verified: `sandbox/shell/sandbox.sh` touches `/tmp/launch-hold` in the
  proxy and daemon in the `claude|codex)` branch of `sandbox`, and
  `sandbox/tests/test-shell-functions.sh`'s stub `docker` logs those holds
  (`SANDBOX_TEST_HOLDS`, `SANDBOX_TEST_FAIL=hold`).
- Verified: `docker compose down` does not stop one-off `run` containers and
  `docker compose ps -a -q` lists them (probe, Compose v5.5.1, 2026-11-20).
- Verified: the reference orphan handling (`_sandbox_watch`,
  `_sandbox_stop_client`, the `ai-coding-sandbox.client` label) is on branch
  `fix/last-agent-review-fixes`, commit d9f3b46
  (`git show d9f3b46 -- sandbox/shell/sandbox.sh`), with its test changes in
  `sandbox/tests/test-shell-functions.sh` there.
- Verified: the audit's cleanup runs `down` without the direct-egress
  setting, leaving the `session-daemon-direct` network behind; the fix
  (remove every network labeled with the audit's project) is in commit
  732a640 on that branch.
- Verified: lifetime text to update (search on 2026-11-20): `README.md`
  line ~49; `sandbox/README.md` lines ~28, ~84-110 (commands and launch
  hold), ~490, ~524-545 (daemon), ~574, ~608 (ssh-agent), ~852-864 (images
  and entrypoint), ~885-890 (image table); `sandbox/image/session-guide.md`
  lines ~40, ~52, ~240, ~284-285.
- Verified by design: `sandbox-stop` does not rely on Compose stopping
  dependents; the broker's control `stop` drains every member, and the
  following `docker rm -f` and `down` remove whatever is left.

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 04.1 | Host functions: group wait, orphan handling, sandbox-stop, sandbox-status | top | first | planned |
| 04.2 | Audit the broker's boundary and the group's end | top | after 04.1 | planned |
| 04.3 | Documentation and plan cleanup | middle+ | after 04.2 | planned |

## 04.1 Host functions: group wait, orphan handling, sandbox-stop, sandbox-status

Goal: the shell functions handle only what containers cannot see (a
stopping group before a launch, and a dead launching client), and add
`sandbox-stop` and `sandbox-status`.

Context:
- [design.md: Host](design.md#host-sandboxshellsandboxsh).
- `sandbox/shell/sandbox.sh`: `sandbox` (help text, `.sandbox/env`
  bootstrap, the `claude|codex)` preparation branch with `trust`,
  `_sandbox_update_proxy`, `ssh-unlock --if-needed` and the two
  launch-hold `touch` lines, the `HERDR_AGENT` launch, `sandbox-prune`
  after claude/codex), `sandbox-trust`, `_sandbox_update_proxy`,
  `sandbox-unlock`, `sandbox-prune`.
- Reference: `_sandbox_watch`, `_sandbox_stop_client` and the launch's label
  handling in d9f3b46 (copy their structure; change the stop timeout to 15
  to match the agents' `stop_grace_period`). Do not copy
  `_sandbox_hold_services` (the lease, removed by design).
- Broker control (01.1): `docker compose --env-file .sandbox/env exec -T
  lifecycle sandbox-lifecycle status` prints `state=`, `joinable=`,
  `remaining=`, `agents=`, `services=` lines; fails when the broker is not
  running. `… exec -T lifecycle sandbox-lifecycle stop` answers at once and
  the broker then drains every member, agents included; SIGTERM to the
  broker (`docker compose stop lifecycle`) is not a stop: it exits quietly
  and its members rejoin a replacement (design decision 11).
  `joinable=yes` only while `active` or early `starting`; an `idle` group
  (its last agent left) is never joined (design decision 5).
- `sandbox/tests/test-shell-functions.sh`: stub `docker` matched on `"$*"`,
  logs, bash and zsh runs.

Contracts:
- `_sandbox_wait_for_group`: runs the `status` command above; if it fails,
  or prints `joinable=yes`, return 0. Otherwise print once `sandbox: waiting
  for this project's previous session group to stop, so this launch starts
  with the current settings.` and poll `docker compose --env-file
  .sandbox/env ps -q --status running lifecycle egress-proxy docker publish
  ssh-agent` until it prints nothing (return 0): at most 40 polls with
  `sleep 1` between them (count polls; do not read the clock, so a stubbed
  `sleep` ends the loop). At the bound, force the end (design "Forced end",
  layer 5): print `sandbox: forcing the previous session group's stuck
  containers to stop: NAMES` (service names from `ps --format
  '{{.Service}}'`), `docker rm -f` each listed container, and return 0 when
  that succeeds, else 1.
- `_sandbox_wait_for_group` sets `sandbox_group_waited=1` (a `local` of the
  caller, `sandbox`) when it actually waited for a group to stop, else 0.
- In the poll, also return 0 (without forcing anything) when `status`
  answers `joinable=yes` again: another launch's agent joined and the group
  is live.
- `sandbox`'s `claude|codex)` branch: remove both `touch /tmp/launch-hold`
  lines; call `_sandbox_wait_for_group || return` first, before `trust
  --yes` and `_sandbox_update_proxy` (so a dying proxy is never reloaded
  or restarted), and again right before the launch. If the second call waited and the
  project has the ssh profile, run `ssh-unlock --if-needed` again before
  launching: the stopped group took the unlocked keys with it (for example,
  after a passphrase prompt left open past the broker's 120 s startup
  window).
- `_sandbox_prepare_images SERVICE`: the `pull` and `build` commands of
  design.md "Host", in that order. Capture each command's combined output;
  on success print nothing (Compose prints "Skipped … already present" and
  "No services to build" on stderr even then), on failure print the
  captured output and return its status. Called first in the
  `claude|codex)` branch, before the first `_sandbox_wait_for_group` (for
  every launch, with or without the ssh profile). The branch order is then:
  prepare images, wait, `trust --yes`, `_sandbox_update_proxy`,
  `ssh-unlock`, wait, run.
- `sandbox-unlock`'s help line: "Unlock SSH keys for this project's running
  session group, or for one started within two minutes".
- Launch label `ai-coding-sandbox.client=<$$.<epoch>.<RANDOM>>`, watcher
  marker `${TMPDIR:-/tmp}/ai-coding-sandbox-watch.<id>`, `_sandbox_watch ID`
  and `_sandbox_stop_client ID` as in d9f3b46 (`docker stop -t 15`, then
  `docker rm -f`), applied to claude and codex launches only; on return,
  `_sandbox_stop_client` then `sandbox-prune`.
- `sandbox-stop`: requires `.sandbox/env` (same message style as
  `sandbox-trust`); `docker compose --env-file .sandbox/env exec -T
  lifecycle sandbox-lifecycle stop` (skipped when it fails: no broker runs),
  then the same bounded poll and forced removal as `_sandbox_wait_for_group`;
  then remove what is left: `docker compose --env-file .sandbox/env --profile '*' ps -a -q`,
  each `docker rm -f`; then `docker compose --env-file .sandbox/env
  --profile '*' down --remove-orphans` (volumes kept). Returns the status
  of the last step.
- `sandbox-status`: requires `.sandbox/env`; prints the broker's `status`,
  or `sandbox-status: no session group is running for this project.` and
  returns 0.
- Help text and the file's header list both new commands; the help's
  `sandbox-prune` line keeps its alignment.

Files:
- `sandbox/shell/sandbox.sh`
- `sandbox/tests/test-shell-functions.sh`

Work:
1. Implement the contracts above.
2. Tests (stub `docker`; extend its `case` and logs):
   - no launch-hold command is ever issued (drop the hold stub case and its
     log checks);
   - a broker that is not running, or reports `joinable=yes`, is not waited
     for; one reporting `joinable=no` is waited for until `ps` prints
     nothing, and the launch proceeds; containers still listed at the limit
     are removed with `docker rm -f`, the message names their services, and
     the launch proceeds (make the limit testable by stubbing `sleep` on
     `PATH` to return at once, not by adding a variable);
   - a poll that sees `joinable=yes` again returns without forcing
     anything;
   - a claude or codex launch runs the `pull --quiet --policy missing
     --include-deps --ignore-buildable` and `build --quiet
     --with-dependencies` commands for its service, in that order, before
     the first `status` call, `ssh-unlock` and `run`; other services do not;
   - when the stubbed `pull` and `build` succeed while writing to stderr, the
     launch prints none of it; when `pull` fails, its output is printed and
     the launch stops with its status;
   - with the ssh profile, a second wait that waited runs `ssh-unlock
     --if-needed` a second time; one that did not wait does not;
   - claude and codex launches carry the label, other services do not;
     `_sandbox_stop_client` stops and removes a labeled container the stub
     reports, and the watcher marker is removed on return;
   - `sandbox-stop` sends the broker `stop`, waits until `ps` shows no
     running lifecycle container, then removes the listed containers, then
     runs `down --remove-orphans` with all profiles; with no broker running
     it skips straight to the removal;
   - `sandbox-status` prints the stub's status, or the no-group line;
   - every case runs under bash and, when installed, zsh, as the file does
     now.
3. Run `sh sandbox/tests/test-shell-functions.sh`; ShellCheck
   `sandbox/shell/sandbox.sh` (bash) and the test.

External inputs: the broker's `status` output and `docker compose ps`
output, both from this project's own containers: only `joinable=yes` and an
empty `ps` result have meaning; anything else counts as "not joinable" or
"still running", bounded by the 40 s limit.

Done when:
- `sh sandbox/tests/test-shell-functions.sh` passes in bash and zsh.
- `grep -n launch-hold sandbox/shell/sandbox.sh sandbox/tests/test-shell-functions.sh`
  finds nothing.
- ShellCheck is clean.

Out of scope: `_sandbox_update_proxy` and its restart fallback (policy
reloads, not lifetime); `sandbox-prune`; installer.

Model basis: J1 F0 R1 C1 K2 P0 V0 S1 = 6 -> top (override 1: K = 2,
stopping and removing containers, and code with partial coverage)

## 04.2 Audit the broker's boundary and the group's end

Goal: `audit-sandbox` verifies, in real sessions, that each client sees only
its role's socket read-only, that the daemon's workloads cannot reach the
agents' or services' socket, that an idle session keeps the group, that the
group ends after the last session, and that `sandbox-stop`'s first step
drains a running session.

Context:
- `sandbox/bin/audit-sandbox`: `session_services` per profile, the explicit
  `build` (with `lifecycle` since 02.2), `session()` runs, the daemon
  section (`daemon_ls` runs a container with `/` of the daemon bind-mounted),
  the idle check ("sleep 25 … the session lease keeps the daemon up"), and
  the final stop wait (150 s, comment on the proxy's start grace).
- Cleanup fix from 732a640 (Assumptions).
- Timing: idle 2 s, drain at most 25 s, graces 5/22 s
  ([design.md](design.md#timing-go-constants-in-sandboxlifecycleprotocolgo-one-doc-table)).

Contracts: none new; it uses the Compose service names and paths of 02.2.

Files:
- `sandbox/bin/audit-sandbox`
- `sandbox/tests/test-audit-session.sh` (only if its structural checks of the
  audit need the new service name)

Work:
1. Add `lifecycle` to `session_services` in both profile settings, and
   remove the literal `lifecycle` that 02.2 put in the build command and in
   `session()`'s `ps` poll, which now come from `$session_services`.
2. In each agent session's checks: `/run/sandbox-lifecycle` contains only
   `lifecycle.sock`, is read-only, and `sandbox-lifecycle status` is not
   reachable (no control socket in the agent: `test ! -e
   /tmp/sandbox-lifecycle-control.sock`); expected tokens
   `lifecycle-socket-only`, `lifecycle-read-only`.
3. In the daemon section: a container bind-mounting the daemon container's
   `/run/sandbox-lifecycle` sees only `lifecycle.sock`, and the daemon
   container's `/run/sandbox-lifecycle` has no `agents` or `services`
   folder (`daemon_ls /run/sandbox-lifecycle` equals `lifecycle.sock`);
   token `daemon-socket-isolated`. In dockerd's namespace rootlesskit's
   `--copy-up=/run` makes `/run/sandbox-lifecycle` a relative symlink
   (`.roNNN/sandbox-lifecycle`); `ls -A` without `-l` or `-d` follows it and
   lists the volume's contents, so keep `daemon_ls` as it is.
4. Rename the idle check to "an idle session keeps the group up" (it waits
   25 s, far longer than the 2 s idle window; keep the logic).
5. Group end after the last session (the existing final wait, kept in
   place): services and the broker stop within 60 s of the last session
   (2 s idle + 22 s daemon grace + margin); update its comment (no more
   start grace). Afterwards `docker compose ps -a --status running` for the
   project lists nothing: no container of the group keeps running.
6. Place steps 7 and 6, in that order, right after the reference-mount
   loop and before the `if [ "$audit_docker" = true ]` daemon section; both
   run in `--no-docker` mode too. Step 5 stays last, after the last normal
   session, so it still tests the end after the last agent leaves.
   Step 6: after step 7's session has exited and its group is gone (the
   `session()` wait), on a fresh group: start a session that sleeps 60 s in
   the background, wait until `sandbox-lifecycle status` (through `docker
   compose exec lifecycle`) lists the agent, run the explicit stop that
   `sandbox-stop` uses first (04.1's contract), and check the session ended
   within 30 s (its status is the stopped command's, 143 for a shell ended
   by SIGTERM; any status is accepted) and the services stopped:
   `sandbox-stop drains running sessions`.
7. A broker restart keeps a running session (design decision 11): with a
   session sleeping 60 s in the background, `docker compose --env-file
   .sandbox/env restart --no-deps lifecycle` (without `--no-deps` Compose
   also restarts the services that depend on it); 10 s later the session still runs and
   `status` lists its agent again: `broker restart keeps sessions`. Run it
   before step 6, on its own group.
8. Keep `session()`'s wait for a group that is not joinable (added in
   02.2).
9. Apply the network cleanup fix in `cleanup()`.
10. Run `sandbox/bin/audit-sandbox --no-docker` and, locally, the full
   `sandbox/bin/audit-sandbox`.

External inputs: none.

Done when:
- Both audit runs pass locally, with the new tokens reported `ok`.
- `docker network ls --filter name=sandbox-session-audit-` is empty after
  the run.
- ShellCheck clean; `sh sandbox/tests/test-audit-session.sh` passes.

Out of scope: changing what the audit checks about egress, mounts or
privileges beyond the lifecycle items above.

Model basis: J1 F0 R1 C0 K2 P1 V1 S1 = 7 -> top (override 1: K = 2, the
boundary audit and a daemon-isolation invariant)

## 04.3 Documentation and plan cleanup

Goal: the documentation describes the broker as the only lifetime
mechanism, with the timing table, the new commands and the accepted limit;
no text describes an old mechanism; the handoff is gone.

Context:
- Lines to update are listed in this phase's Assumptions; the content is in
  [design.md](design.md) (states, sockets, wrapper, host, timing).
- `AGENTS.md`: the root `README.md` stays the concise entry point; detailed
  operation, security and troubleshooting go in `sandbox/README.md`;
  `session-guide.md` says what a session provides.

Contracts: none.

Files:
- `README.md`
- `sandbox/README.md`
- `sandbox/image/session-guide.md`
- `sandbox/plans/lifecycle-broker/handoff.md` (delete, if still present)

Work:
1. `README.md`: one sentence: each project's services start with its first
   session and stop shortly after its last; `sandbox-stop` and
   `sandbox-status`.
2. `sandbox/README.md`:
   - commands table: add `sandbox-stop` and `sandbox-status`; replace the
     launch-hold paragraph (~line 109) with the group wait;
   - a new section "Session lifecycle": the broker, its states, what ends a
     group, the socket table (who mounts what, and why the daemon has its
     own), the timing table from design.md, that a launch after the last
     session waits a few seconds for the old group to stop so changed
     settings apply, that a broker update or restart keeps running sessions
     (they reconnect), `sandbox-stop`, `sandbox-status`,
     orphan handling and its limit (plain `docker compose run` sessions are
     not protected), the two launch limits from design.md "Host" with their
     remedy, run `sandbox` again (a passphrase prompt left open past two
     minutes stops the launch; a launch into a running group can fail if
     that group's other sessions all quit while Compose recreates a changed
     service), and troubleshooting (a group that will not stop:
     `sandbox-stop`; `docker compose logs lifecycle`);
   - daemon (~524-545), forwarder (~574) and ssh-agent (~608): replace idle,
     lease and expiry text with "ends with the session group"; ssh keys end
     with the group, so `sandbox-unlock` applies to the running group or one
     started within two minutes, and `sandbox` unlocks again when it had to wait for a group
     to stop;
   - images (~852-864): list `session-lifecycle`; the entrypoint joins the
     broker in sessions instead of starting leases; service images run their
     script under `sandbox-lifecycle run`;
   - image table (~885-890): add `Lifecycle broker | lifecycle-<release ID> |
     lifecycle-latest`.
3. `session-guide.md`: add the `lifecycle` service to the list of session
   services (~24-36) and a row for the `lifecycle` volume to the volume
   table (~45-52: mounted at `/run/sandbox-lifecycle`, read-only, the
   agent's socket to the broker; per project; lives with the project);
   services' lifetime (~40), the `docker-data` row
   (~52: wiped when the group ends), ~240 and ~284-285 (socket clients do
   not keep the daemon running → the daemon ends with the group).
4. Delete `handoff.md` if it still exists.
5. Search the documentation for `lease`, `launch hold`, `launch-hold`,
   `idle`, `until its keys expire`, `start grace`; every remaining hit must
   describe the broker.
6. `git diff --check`.

External inputs: none.

Done when:
- Step 5's search has only broker-related hits.
- The timing table in `sandbox/README.md` equals design.md's.
- `git diff --check` is clean.

Out of scope: `session-rules.md` (done in 03.4); code.

Model basis: J1 F1 R2 C0 K0 P1 V2 S0 = 7 -> middle, override 3 (V = 2, R =
2) -> middle+

## Notes
- 2026-11-20: The host keeps one wait (for a stopping group) instead of a
  lease: the broker's `joinable` answer holds all the timing; the host's
  40 s limit only bounds how long it waits for an exit.
- 2026-11-21 (user): a launch after the last agent has left always waits
  for that group to exit and starts fresh, so changed settings apply; the
  2 s idle window keeps the wait to a few seconds.
- 2026-11-21 (user): `sandbox-stop` uses the broker's explicit `stop`;
  SIGTERM only replaces the broker (members rejoin).
- 2026-11-20: Orphan handling stays in the host functions (design decision
  9): only the launching shell can see its client die.
- 2026-11-21 (user): the host is the last backstop for a container that does
  not stop: its bounded wait force-removes what still runs (design "Forced
  end", layer 5).
- 2026-11-21 (plan review round 3): `sandbox` makes the images present
  before `ssh-unlock` starts the group, so a long pull or build after a
  release cannot use up the broker's startup window; a passphrase prompt
  left open past 120 s is an accepted limit (design.md "Host").
- 2026-11-21 (plan review round 4): image prep moved first in the launch so
  a slow pull cannot land `ssh-unlock` in a group that began stopping; its
  output is shown only on failure; the group wait counts polls so stubbed
  `sleep` tests terminate; the README names both launch limits.
