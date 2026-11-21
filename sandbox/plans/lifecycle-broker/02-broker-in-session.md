# Phase 02: The broker in the session group

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md).
Status: planned
Before: phase 01 built `sandbox-lifecycle` (all contracts in
`sandbox/lifecycle/protocol.go`); no image contains it.
After: a released `lifecycle` image; every session image carries the binary;
`compose.session.yaml` runs the `lifecycle` service first, mounts each role's
socket, and orders startup through its health check; agents join it in
sessions. Services still end themselves the old way (phase 03 switches
them), so sessions behave as before, and `sandbox-status`-style queries
(`docker compose exec lifecycle sandbox-lifecycle status`) already show the
agents. The user inspects real Claude and Codex sessions (checklist in
02.3).

## Dev session of this checkout

The work moved from a worktree to the main checkout (branch
`lifecycle-broker`, 2026-11-21), whose `.sandbox/` already selects
`COMPOSE_FILE=sandbox/compose.session.yaml,sandbox/compose.dev.yaml` and
is trusted. Its `COMPOSE_PROJECT_NAME` is `ai-coding-sandbox-session`, the
user's own session group, so every "dev session of this repository" step
in this plan runs with `COMPOSE_PROJECT_NAME=ai-coding-sandbox-lifecycle`
exported in the shell (it overrides the env file); never edit or commit
`.sandbox/`. `audit-sandbox` already uses its own project name.

## Assumptions
- Verified: release matrix entries are `{target, name}` pairs in
  `.github/workflows/release.yml` (`images` job, `matrix.include`, lines
  76-82); each image's digest reaches `pin-session-images` through
  `release-data/$NAME.digest` ("Record the version" step), so a new entry
  needs no other workflow change.
- Verified: `sandbox/bin/pin-session-images` accepts only the names in its
  `case` (agent, docker-daemon, proxy, forwarder, ssh-agent) and fails unless
  every `image:` line is pinned; `sandbox/tests/test-pin-session-images.sh`
  passes all names.
- Verified: `sandbox/bin/check-sandbox` compares the dev overlay to the
  session file after stripping `build`, `image` and `pull_policy`, so every
  session service must have an overlay entry, and checks the exact service
  key list.
- Verified: Compose v5.5.1 renders a volume's subpath as `.volume.subpath`
  in `config --format json` (the existing `docker-certs` mount,
  `check-sandbox`: `[.read_only, .volume.subpath] == [[true, "client"]]`).
- Verified: Docker 29.8.1 here mounts a volume subpath read-only with
  `--mount type=volume,…,readonly,volume-subpath=agents` (probe on
  2026-11-20).
- Verified: two agent-image tests run `sandbox-entrypoint` with
  `SANDBOX_SESSION=1`: `test-session-state.sh`'s `entrypoint()` cases and
  every `hook()` call in `test-session-init.sh` (lines 42-53: `"$image" sh
  …/init.d/$name`, no `--entrypoint`, `SANDBOX_AGENT=codex`), so both need a
  broker from 02.3 on. `test-session-agent-launch.sh` and
  `test-session-exit.sh` override the entrypoint, and the CI smoke tests run
  without `SANDBOX_SESSION`. (Corrected after plan review round 1.)
- Open: a fresh named volume is populated from the `scratch` image's
  `/run/sandbox-lifecycle` directories, keeping owner 13:13, when the broker
  is the first container to mount it. Check in 02.3 when the test helper
  first starts a broker (`ls -lnd` of the mounted folder). If it is wrong,
  the volume root is root-owned 0755 and the broker (uid 13) cannot create
  its directories: it fails to start, so every session fails at once. The
  fix would then be in the image (02.1): an empty volume takes the image's
  directories only on first mount, so the broker must be the first container
  to mount it, which Compose's `depends_on` guarantees.
- Open: a volume mounted at `/run/sandbox-lifecycle` on top of the proxy's
  and daemon's tmpfs `/run` is visible inside them. Check in 02.2 with a
  real `docker compose up` of the dev overlay (`ls /run/sandbox-lifecycle` in
  both). If it is not, mount the client socket at `/run/lifecycle` instead,
  which changes `clientSocket` in 01.1 and the design (revise those first).

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 02.1 | Broker image, binary in every session image, release matrix | top | first | planned |
| 02.2 | `lifecycle` service and mounts in Compose, enforced by check-sandbox | top | after 02.1 | planned |
| 02.3 | Agents join the broker in sessions; shared test helper | top | after 02.2 | planned |

## 02.1 Broker image, binary in every session image, release matrix

Goal: the Dockerfile builds `sandbox-lifecycle` once and ships it as the
`session-lifecycle` image and inside the agent, proxy, daemon, forwarder and
ssh-agent images; releases publish and pin a `lifecycle` image.

Context:
- `sandbox/Dockerfile`: `go-upstream` stage (line 7); `session-daemon`,
  `session-forwarder`, `session-ssh-agent`, `session-proxy`, `base` and
  `agent` stages; `no-target` must stay last.
- PR #11's Dockerfile diff on `fix/last-agent-review-fixes` shows a
  `lifecycle` build stage and copies into each image (reference only; this
  plan names it `lifecycle-build` and adds a release image).
- Phase 01: module in `sandbox/lifecycle/` (`go.mod`, no dependencies);
  broker directories `brokerDir/<subdir>` for `agents`, `services`,
  `daemon`.

Contracts:
- Stage `lifecycle-build` `FROM go-upstream`: `COPY lifecycle/ /src/`;
  `RUN cd /src && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-mod=mod go build
  -trimpath -ldflags='-s -w' -o /out/sandbox-lifecycle . && install -d -m
  0755 /out/run/sandbox-lifecycle/agents /out/run/sandbox-lifecycle/services
  /out/run/sandbox-lifecycle/daemon`. Place it right after `go-upstream`.
- Stage `session-lifecycle` `FROM scratch`:
  `COPY --from=lifecycle-build --chmod=0755 /out/sandbox-lifecycle /usr/local/bin/sandbox-lifecycle`;
  `COPY --from=lifecycle-build --chown=13:13 /out/run/ /run/`;
  `USER 13:13`; `ENTRYPOINT ["/usr/local/bin/sandbox-lifecycle", "serve"]`.
  Place it after `session-forwarder`, with a comment saying what it is.
- In `session-daemon`, `session-forwarder`, `session-ssh-agent`,
  `session-proxy` and `base`: `COPY --from=lifecycle-build --chmod=0755
  /out/sandbox-lifecycle /usr/local/bin/sandbox-lifecycle`. Entrypoints do
  not change in this stage.
- Release image name `lifecycle` (tags `lifecycle-<release ID>`,
  `lifecycle-latest`); `pin-session-images` accepts `lifecycle=DIGEST`.

Files:
- `sandbox/Dockerfile`
- `.github/workflows/release.yml`
- `sandbox/bin/pin-session-images`
- `sandbox/tests/test-pin-session-images.sh`

Work:
1. Add the two stages and the five `COPY` lines. In `base`, put the copy
   before the `COPY image/sandbox-entrypoint …` block.
2. Add `{target: session-lifecycle, name: lifecycle}` to the `images` job's
   matrix, after `ssh-agent`.
3. Add `lifecycle` to `pin-session-images`' `case` and to its header
   comment's list.
4. In `test-pin-session-images.sh`, add `lifecycle="$(digest 7)"` to the
   argument list and a `grep -Fq "ai-coding-sandbox@$(digest 7)"` check.
   Until 02.2 adds the service, the digest is unused; the test still passes
   since every `image:` line is pinned.
5. Build each target locally: `docker build --target X sandbox` for
   `session-lifecycle`, `session-proxy`, `session-daemon`,
   `session-forwarder`, `session-ssh-agent`, `agent`.

External inputs: none.

Done when:
- All six targets build; `docker run --rm --entrypoint
  /usr/local/bin/sandbox-lifecycle IMAGE` prints the usage line and exits 2
  for each image but `session-lifecycle`.
- `session-lifecycle` serves on an anonymous volume, which also exercises
  the copy of its 13:13 directories into a fresh volume: `docker run -d
  --read-only --tmpfs /tmp:uid=13,gid=13,mode=0700 -v /run/sandbox-lifecycle
  IMAGE`, then `docker exec … sandbox-lifecycle
  status` shows `state=starting`, and `docker stop` ends it with status 0
  within a few seconds.
- `docker image inspect` of `session-lifecycle` shows user `13:13` and the
  entrypoint above; `docker create` + `docker cp` (or `docker export`) shows
  `/run/sandbox-lifecycle/{agents,services,daemon}` owned 13:13.
- `sh sandbox/tests/test-pin-session-images.sh` and
  `sandbox/bin/check-sandbox` pass; ShellCheck is clean for the changed
  scripts.

Out of scope: Compose (02.2), entrypoints and service scripts (02.3, phase
03), README image tables (phase 04).

Model basis: J0 F1 R1 C2 K1 P1 V1 S0 = 7 -> top (override 1: C = 2, it
changes the `pin-session-images` interface and the released image set that
`release.yml` and the Compose file consume; K1: release.yml is untested)

## 02.2 `lifecycle` service and mounts in Compose, enforced by check-sandbox

Goal: `compose.session.yaml` defines the `lifecycle` service and volume, each
client mounts exactly its role's socket subdirectory read-only, every session
service and agent starts after the broker is healthy, and `check-sandbox`
enforces all of it.

Context:
- [design.md: Broker](design.md#broker-lifecycle-service) (service settings,
  socket table) and [Timing](design.md#timing-go-constants-in-sandboxlifecycleprotocolgo-one-doc-table)
  (`stop_grace_period` values).
- `sandbox/compose.session.yaml`: anchors `x-agent-service` (agent
  settings), `&agent-depends-on` (on `claude`), `&agent-volumes`,
  `x-hardened`; services `egress-proxy`, `docker`, `publish`, `ssh-agent`;
  top-level `volumes`.
- `sandbox/compose.dev.yaml`: one entry per service with `build: {context:
  ., target: …}`, `image: ai-coding-sandbox-dev:…`.
- `sandbox/bin/check-sandbox`: the first `jq -e` program (service key list,
  per-service invariants, `network_mode == "none"` rule by name regex).
  jq 1.8.1 binds `as $v` over the whole preceding `and` chain: bind new
  variables at the top of the expression, before the first `and`.
- `sandbox/bin/audit-sandbox`: builds images explicitly before sessions
  (`docker compose … build --quiet claude claude-state-init codex
  codex-state-init $session_services`) and runs sessions with `--pull never`,
  so the `lifecycle` image must be in that build list.

Contracts:
- Service:

  ```yaml
  lifecycle:
    <<: *hardened
    image: ghcr.io/bryanwieg/ai-coding-sandbox:lifecycle-latest
    user: "13:13"
    network_mode: none
    restart: on-failure
    tmpfs:
      - /tmp:uid=13,gid=13,mode=0700
    volumes:
      - {type: volume, source: lifecycle, target: /run/sandbox-lifecycle}
    healthcheck:
      test: ["CMD", "/usr/local/bin/sandbox-lifecycle", "ready"]
      interval: 1s
      timeout: 2s
      retries: 10
      start_period: 1s
  ```

  with a comment: it owns the group's lifetime; every other session service
  and agent depends on it; it has no network and no dependencies.
- Volume `lifecycle:` (per project, not external).
- Client mounts, all `{type: volume, source: lifecycle, target:
  /run/sandbox-lifecycle, read_only: true, volume: {subpath: S}}`: `S =
  agents` in `&agent-volumes`; `services` in `egress-proxy`, `publish`,
  `ssh-agent`; `daemon` in `docker`. Comment on the daemon's: its
  containers can bind-mount its paths, so it gets a socket of its own.
- `depends_on` gains `lifecycle: {condition: service_healthy}` in
  `&agent-depends-on`, `egress-proxy`, `docker`, `publish`, `ssh-agent`
  (`publish` and `ssh-agent` get a `depends_on` block if they lack one).
- `stop_grace_period: 15s` in `x-agent-service`; `25s` in `docker`.
- Dev overlay: `lifecycle: {<<: *dev, image: ai-coding-sandbox-dev:lifecycle,
  build: {context: ., target: session-lifecycle}}`.

Files:
- `sandbox/compose.session.yaml`
- `sandbox/compose.dev.yaml`
- `sandbox/bin/check-sandbox`
- `sandbox/bin/audit-sandbox` (build list only)

Work:
1. Add the service, volume, mounts, dependencies and grace periods. Update
   the file's header comment to name the `lifecycle` service, and the
   service comments that describe old lifetimes: `docker` ("it stops itself
   once no agent holds a connection", lines ~267-268) and `ssh-agent` ("It
   lives until its keys expire", line ~352) now end with the session group
   (the behavior arrives in phase 03; the comment states the design).
2. Add the overlay entry.
3. `check-sandbox`: add `"lifecycle"` to the sorted service key list; add
   `lifecycle` to the `network_mode == "none"` regex; then, with variables
   bound at the top, require:
   - `lifecycle`: user `13:13`, `restart == "on-failure"`, no ports, no
     `depends_on`, healthcheck test equal to the contract, its only volume
     the read-write `lifecycle` mount at `/run/sandbox-lifecycle`;
   - the set of `[service, (.volume.subpath // null), (.read_only //
     false)]` over every mount whose source is `lifecycle` (Compose omits
     both keys on the broker's own mount) equals exactly
     `[claude, agents, true]`, `[codex, agents, true]`,
     `[docker, daemon, true]`, `[egress-proxy, services, true]`,
     `[lifecycle, null, false]`, `[publish, services, true]`,
     `[ssh-agent, services, true]` (so no other service, and no other
     subpath, reaches a socket);
   - `lifecycle`, `egress-proxy`, `docker`, `publish` and `ssh-agent` have
     no `init: true`, so from phase 03 the wrapper is PID 1 there and its
     exit ends every process in the container (design "Forced end", layer
     3); claude and codex keep `init: true`;
   - `depends_on.lifecycle.condition == "service_healthy"` for claude,
     codex, egress-proxy, docker, publish, ssh-agent;
   - `stop_grace_period` 25s/15s/15s for docker/claude/codex, and none on
     lifecycle (it exits at once on SIGTERM)
     (match the rendered form; print it once with `docker compose config
     --format json` to confirm).
   Comment the new checks (why: the daemon's workloads must not reach the
   services' or agents' socket).
4. In `audit-sandbox`: add `lifecycle` to the build command (before
   `$session_services`), and have `session()` first wait for a group that
   is not joinable, the same rule the host gets in 04.1: if `docker compose
   --env-file .sandbox/env exec -T lifecycle sandbox-lifecycle status`
   succeeds and does not print `joinable=yes`, poll every second until
   `docker compose --env-file .sandbox/env ps -q --status running lifecycle
   $session_services` prints nothing, for at most 40 s; at the bound, record
   a failure naming the services still running (the audit reports a stuck
   container; it does not force it, unlike the host). The audit runs sessions back to back,
   some with changed settings (direct daemon egress recreates the daemon);
   from phase 03 on, a session started while the previous group winds down
   would otherwise race its drain. Write the wait inline in `session()`, not
   in a helper function: `sandbox/tests/test-audit-session.sh` extracts only
   `session()` with `sed` and `eval` and runs it against a project without
   a `lifecycle` service (a failing `exec` there means no wait).
5. Verify the open assumption on tmpfs `/run`: with the dev session settings (see "Dev session of this checkout"),
   `COMPOSE_PROJECT_NAME=ai-coding-sandbox-lifecycle`, `docker compose --env-file .sandbox/env --profile docker
   up -d lifecycle egress-proxy docker`, then `docker compose exec` into
   `egress-proxy` and `docker` and `ls -l /run/sandbox-lifecycle` (expect
   `lifecycle.sock` once the broker listens); then `docker compose down`.
   Record the result in this phase's Notes.

External inputs: none.

Done when:
- `sandbox/bin/check-sandbox` passes, and fails when (try each, then
  revert) a service other than those listed mounts the volume, the daemon
  mounts `services`, or an agent mount is writable.
- `sh sandbox/tests/test-pin-session-images.sh` passes (the lifecycle image
  is now pinned), and `sh sandbox/tests/test-audit-session.sh` passes.
- `sandbox/bin/audit-sandbox --no-docker` passes; the full
  `sandbox/bin/audit-sandbox` passes locally (boundary change: new service
  and mounts). The broker drains on its own 120 s after start since no agent
  joins yet; the audit's final stop check waits 150 s, so it still passes.
- Step 5's result is recorded.

Out of scope: entrypoints (02.3, phase 03); host functions; documentation
(phase 04); removing any old mechanism.

Model basis: J1 F1 R1 C1 K2 P1 V1 S1 = 8 -> top (override 1: K = 2,
security boundary and mounts)

## 02.3 Agents join the broker in sessions; shared test helper

Goal: in a session (`SANDBOX_SESSION=1`) the agent image's entrypoint runs
its command under `sandbox-lifecycle run "$SANDBOX_AGENT" --`, so the broker
counts each agent container; a shared test helper starts a broker for image
tests.

Context:
- `sandbox/image/sandbox-entrypoint`: identity setup, then session leases
  (`sandbox-proxy-lease`, `sandbox-docker-lease`, wait for them), then
  `exec "$@"`. The leases stay until phase 03 retires the services' idle
  counting; this stage only changes the final `exec`.
- Wrapper contract (01.1/01.3): `sandbox-lifecycle run NAME -- COMMAND...`;
  `claude`/`codex` are agent names; exit 75 when the group is stopping, 1
  when no broker answers within 10 s; agent role keeps the child in its
  process group and forwards SIGTERM/SIGHUP.
- Existing helpers to follow: `sandbox/tests/test-session-ssh-agent.sh`
  (`prefix=…-$$`, label-based cleanup, `pass`/`fail`, image built with
  `docker build --quiet --target … --tag …`).
- `sandbox/tests/test-session-state.sh` `entrypoint()` helper and its four
  lease cases (search `entrypoint()`).

Contracts:
- Entrypoint tail:

  ```sh
  # In a session the agent's lifetime is part of the project's session
  # group: the lifecycle broker counts this container until the command ends.
  if [ "${SANDBOX_SESSION:-}" = 1 ]; then
      exec sandbox-lifecycle run "${SANDBOX_AGENT:-}" -- "$@"
  fi
  exec "$@"
  ```

- `sandbox/tests/lifecycle-helper.sh`, sourced (POSIX sh; callers set
  `sandbox_dir` and `prefix`, and their cleanup removes containers and
  volumes labeled `$prefix`):
  - `lifecycle_image=ai-coding-sandbox-session-lifecycle:test`
  - `lifecycle_build`: `docker build --quiet --target session-lifecycle
    --tag "$lifecycle_image" "$sandbox_dir" >/dev/null`
  - `lifecycle_start NAME`: creates volume `NAME-lifecycle` labeled
    `$prefix`; runs `docker run -d --name NAME --label "$prefix" --network
    none --read-only --cap-drop ALL --security-opt no-new-privileges --user
    13:13 --tmpfs /tmp:uid=13,gid=13,mode=0700 -v
    NAME-lifecycle:/run/sandbox-lifecycle "$lifecycle_image"`; waits up to
    10 s for `docker exec NAME /usr/local/bin/sandbox-lifecycle ready`;
    returns 1 if it never becomes ready.
  - `lifecycle_mount NAME SUBDIR`: prints `--mount
    type=volume,src=NAME-lifecycle,dst=/run/sandbox-lifecycle,readonly,volume-subpath=SUBDIR`.
  - `lifecycle_status NAME`: `docker exec NAME /usr/local/bin/sandbox-lifecycle status`.
  - `lifecycle_field NAME KEY`: prints the value of `KEY=` from the status.
  - `lifecycle_hold NAME IMAGE`: keeps broker NAME active for a long test
    (it would otherwise drain 120 s after start): runs container `NAME-hold`
    labeled `$prefix`, `--network none --read-only --user 1000:1000`, with
    `$(lifecycle_mount NAME agents)`, `--entrypoint
    /usr/local/bin/sandbox-lifecycle IMAGE run claude -- sleep 86400`, then
    waits up to 5 s until `lifecycle_field NAME state` is `active`. IMAGE is
    any session image that contains the binary and `sleep` (the image under
    test).
  - `lifecycle_release NAME`: `docker rm -f NAME-hold` (the broker then goes
    `idle` and drains 2 s later).
  - `lifecycle_drain NAME`: `docker exec NAME /usr/local/bin/sandbox-lifecycle
    stop` (the broker drains every member at once), then waits up to 30 s
    for the container to exit. `docker stop` is not a drain: the broker then
    exits without telling members to stop, and they rejoin for 30 s.

Files:
- `sandbox/image/sandbox-entrypoint`
- `sandbox/tests/lifecycle-helper.sh`
- `sandbox/tests/test-session-state.sh`
- `sandbox/tests/test-session-init.sh`

Work:
1. Change the entrypoint's final `exec` as above; update its header comment
   (leases remain "until the services move to the broker" is not needed in
   the comment; describe what the code does).
2. Write the helper.
3. In `test-session-state.sh`: source the helper and build the broker
   image. Use two brokers: a held one (`lifecycle_start H`, `lifecycle_hold
   H "$image"`) that stays `active` for the whole file, and a fresh one for
   the join case below, since a broker drains 2 s after its last agent and
   120 s after start without one. Have `entrypoint()` add
   `$(lifecycle_mount H agents) -e SANDBOX_AGENT=claude`, and add
   `entrypoint_bare()` with the same options minus the mount, for the cases
   that need no broker. Add cases:
   - in a session the entrypoint joins: on a fresh broker J, a container
     running `sleep 4` shows in `lifecycle_field J agents` as `claude` and
     `state` is `active`; within 1 s after it exits, `state` is `idle`
     (it drains 2 s later);
   - a session without a reachable broker (no mount) exits 1 within 15 s
     with `cannot reach the lifecycle broker` on stderr;
   - outside a session (no `SANDBOX_SESSION`), the image runs a command
     with no broker and no mount;
   - the command's exit status passes through (`sh -c 'exit 7'` -> 7).
   Check the open volume-ownership assumption with `docker run --rm
   $(lifecycle_mount H agents) --entrypoint ls IMAGE -lnd
   /run/sandbox-lifecycle` (owner 13) and record it in Notes.
4. In `test-session-init.sh`: source the helper, start one held broker for
   the file, and have `hook()` add `$(lifecycle_mount H agents)` (it already
   sets `SANDBOX_AGENT=codex` and `SANDBOX_SESSION=1`). Keep its hooks
   running through the entrypoint, which supplies their identity; do not
   switch them to `--entrypoint`. Cleanup removes the broker's containers
   and volume by label.
5. Run `sh sandbox/tests/test-session-state.sh`,
   `sh sandbox/tests/test-session-init.sh`, and the other agent-image tests
   CI runs (`test-session-agent-launch.sh`, `test-session-exit.sh`) to
   confirm they pass.
6. Run, and record in Notes, the non-interactive checks in this checkout's
   dev session (see "Dev session of this checkout"): `echo hi | docker compose --env-file .sandbox/env run
   --rm -T claude sh -c cat` prints `hi`; `docker compose … run --rm -T
   claude sh -c 'exit 5'` exits 5; a session's exit hooks still run
   (`sandbox-start` prints the `exit.d` branch report after `sandbox claude`
   exits normally); `docker exec <run container> kill -9 <wrapper PID>`
   ends the agent and the container.

External inputs: none new (the wrapper handles the broker's bytes).

Done when:
- The four new `test-session-state.sh` cases and the existing ones pass.
- `test-session-init.sh` passes with its hooks joining the held broker.
- `test-session-agent-launch.sh` and `test-session-exit.sh` pass unchanged.
- Step 6's results are recorded in Notes.
- ShellCheck is clean for the four files.

Out of scope: removing the leases (phase 03, stage 03.4); service
entrypoints; the host functions.

Model basis: J1 F1 R1 C1 K1 P1 V1 S2 = 8 -> middle, override 3 (S = 2:
steps 3-6 act on what runs show) -> middle+. Raised to top (a choice above
the score): it changes the start path of every session, and terminal and
signal behavior across tini, entrypoint, wrapper and `sandbox-start` is
where weaker models fail quietly.

### User inspection at the end of this phase

In this checkout's dev session (see "Dev session of this checkout"), run
and confirm:
1. `sandbox` (Claude): the TUI draws, resizing the terminal redraws it,
   Ctrl-C behaves as in Claude, `/exit` ends the session and the exit hooks
   run.
2. `sandbox codex`: the same for Codex.
3. `sandbox claude bash`: `sleep 30`, Ctrl-Z, `jobs`, `fg`, Ctrl-C; `exit`.
4. While a session runs, `docker compose --env-file .sandbox/env exec
   lifecycle sandbox-lifecycle status` lists the agent.

If any of 1-3 fails, revise 01.3 (the wrapper's agent role) before phase 03.

## Notes
- 2026-11-20: The agent image joins only when `SANDBOX_SESSION=1`, the
  existing marker for session-only behavior (`init.d/00-session`,
  `exit.d/*`, the launchers, `sandbox/README.md` "Scripts that only make
  sense in a session check `SANDBOX_SESSION=1`"). Service images always join
  (design decision 6). No `SANDBOX_LIFECYCLE` variable.
- 2026-11-20: One `lifecycle` volume with subpaths instead of PR #11's three
  volumes: one name, the same isolation, the pattern the `docker-certs`
  volume already uses.
- 2026-11-20: Stage order keeps every commit working: the broker and agent
  joins arrive while the services still end themselves; phase 03 then
  switches the services and only its last stage removes the leases.
- Plan start (phase 02): de02d9e
- 2026-11-21: work moved to the main checkout; the dev-session steps use
  `COMPOSE_PROJECT_NAME=ai-coding-sandbox-lifecycle` from the shell instead
  of a copied `.sandbox/`. As in phase 01, every stage goes to Codex (user:
  Claude usage nearly exhausted); the orchestrator runs Docker-based checks.
