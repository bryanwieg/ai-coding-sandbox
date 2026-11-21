# Phase 01: The sandbox-lifecycle program

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md).
Status: planned
Before: no lifecycle code exists on this branch; services end themselves
through idle counting and leases (see [design.md](design.md#problem)).
After: `sandbox/lifecycle/` holds the complete `sandbox-lifecycle` Go program
(broker `serve`, wrapper `run`, `ready`, `status`) with unit tests, run by
`sandbox/tests/test-lifecycle.sh` in CI. No image or Compose file uses it
yet, so session behavior is unchanged.

## Assumptions
- Verified: the Dockerfile's `go-upstream` stage is
  `golang:1.27.4-bookworm@sha256:4fa7c968…` (`sandbox/Dockerfile` line 7), and
  the host has no Go, so tests run in that image
  (reference `tests/test-lifecycle.sh` on `fix/last-agent-review-fixes`).
- Verified: the CI `check` job lists host-side tests in
  `.github/workflows/sandbox-image.yml` ("Check sandbox configuration and host
  tools" step), where the reference commit 732a640 added
  `sh sandbox/tests/test-lifecycle.sh`; that job's runner has Docker.
- Verified: `sandbox/.dockerignore` excludes only `.ssh/`, so
  `sandbox/lifecycle/` reaches the build context (used in phase 02).
- Verified: the Go standard library alone covers Unix sockets, process
  groups (`syscall.SysProcAttr{Setpgid, Pdeathsig}`), `wait4` and
  pseudo-terminals (open `/dev/ptmx`, `ioctl` `TIOCSPTLCK`/`TIOCGPTN` via
  `syscall.Syscall`), so the module has no dependencies and builds offline.
- Open: the agent role's terminal behavior (Ctrl-C, Ctrl-Z and `fg` in an
  interactive bash child, kill -9 of the wrapper) is proven here only by
  pty-driven Go tests in a plain container; real Claude and Codex TUIs are
  checked in phase 02 (stage 02.3 and the phase's user inspection). If a
  check fails there, the fix goes into `run.go` here, as a revision of this
  phase (design decision 4: no fallback mechanism).

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 01.1 | Package, contracts, CLI and test runner, with stub bodies | top | first | planned |
| 01.2 | Broker: states, sockets, pools, control socket, drain | top | after 01.1, parallel with 01.3 | planned |
| 01.3 | Wrapper: join, rejoin, child supervision, both roles | top | after 01.1, parallel with 01.2 | planned |

## 01.1 Package, contracts, CLI and test runner

Goal: `sandbox/lifecycle/` is a dependency-free Go module whose code states
every contract of [design.md](design.md) as constants, types and documented
function signatures, with stub bodies, and `sandbox/tests/test-lifecycle.sh`
builds, vets and tests it in CI.

Context:
- Design: [Broker](design.md#broker-lifecycle-service),
  [Client wire protocol](design.md#client-wire-protocol),
  [Control protocol](design.md#control-protocol),
  [Wrapper](design.md#wrapper-sandbox-lifecycle-run-name----command),
  [Timing](design.md#timing-go-constants-in-sandboxlifecycleprotocolgo-one-doc-table).
- Reference only (do not copy its structure; its protocol differs): PR #11's
  `sandbox/lifecycle/main.go` on branch `fix/last-agent-review-fixes`
  (`git show fix/last-agent-review-fixes:sandbox/lifecycle/main.go`), whose
  `listen`, `admit` and `rejoin` show the socket handling, and
  `sandbox/tests/test-lifecycle.sh` there, which this stage's runner adapts.

Contracts (write these into the code as given; later stages and phases use
them unchanged):
- Module `sandbox/lifecycle/go.mod`: `module sandbox-lifecycle`, `go 1.27`,
  no requirements. Package `main`. Files: `main.go` (CLI dispatch),
  `protocol.go` (constants, names, wire and control formats), `broker.go`
  (`serve`), `control.go` (control server handler and `ready`/`status`
  clients), `run.go` (wrapper).
- `protocol.go` constants (exact values):
  `startupWindow = 120 * time.Second`, `idleWindow = 2 * time.Second`,
  `joinMargin = 5 * time.Second`, `drainLimit = 25 * time.Second`,
  `rejoinWindow = 30 * time.Second`, `admissionRetry = 10 * time.Second`,
  `retryInterval = 250 * time.Millisecond`,
  `joinTimeout = 2 * time.Second`, `hardExitMargin = 2 * time.Second`;
  `clientSocket = "/run/sandbox-lifecycle/lifecycle.sock"`,
  `brokerDir = "/run/sandbox-lifecycle"`,
  `controlSocket = "/tmp/sandbox-lifecycle-control.sock"`;
  message bytes `msgAdmit = 'A'`, `msgRefuse = 'R'`, `msgStop = 'S'`;
  `maxJoinLine = 64`; exit codes `exitRefused = 75`, `exitUsage = 2`.
- `type role int` with `roleAgent`, `roleService`; `type member struct {
  name string; role role; grace time.Duration }`; table `members` mapping
  name -> member: `claude`, `codex` (agent, 10 s), `egress-proxy`,
  `publish`, `ssh-agent` (service, 5 s), `docker` (service, 22 s).
- `type socketSpec struct { subdir string; names []string; pool int }` and
  `sockets = []socketSpec{{"agents", {"claude","codex"}, 64},
  {"services", {"egress-proxy","publish","ssh-agent"}, 16},
  {"daemon", {"docker"}, 4}}`; each listens at
  `brokerDir/<subdir>/lifecycle.sock`.
- `type state int`: `stateStarting`, `stateActive`, `stateIdle`,
  `stateDraining`, with `String()` returning `starting|active|idle|draining`.
- Wire helpers: `formatJoin(name string) string` returns `"join " + name +
  "\n"`; `parseJoin(line string) (string, error)` accepts exactly
  `join <name>` where name matches `^[a-z][a-z0-9-]{0,31}$`, else error.
- Control: request lines `ready`, `status`, `stop`; `type status struct { state
  state; joinable bool; remaining time.Duration; agents, services []string }`
  and `(status) format() string` producing exactly the five `key=value` lines
  of [Control protocol](design.md#control-protocol) (remaining as whole
  seconds rounded up, `joinable=yes|no`, names space-separated, empty value
  when none), each ending in `\n`.
- Testable configuration: `type brokerConfig struct { dir, control string;
  startup, idle, margin, drain time.Duration }` with
  `defaultBrokerConfig()` from the constants; `func serve(ctx
  context.Context, cfg brokerConfig) error`. `type runConfig struct {
  socket string; retry, interval, joinTimeout, rejoin, hardExit
  time.Duration; signal func(pid int, sig syscall.Signal) error }` with
  `defaultRunConfig()` (`hardExit` = `hardExitMargin`, `signal` =
  `syscall.Kill`; tests replace `signal` to simulate a child that cannot be
  killed); `func run(ctx context.Context, cfg runConfig, m
  member, name string, argv []string) int` returning the process exit code.
  `func requestControl(path, line string) (string, error)`.
- CLI (`main.go`), errors to stderr prefixed `sandbox-lifecycle: `:
  `sandbox-lifecycle serve` (no further arguments); `sandbox-lifecycle run
  NAME -- COMMAND [ARGS...]` (NAME must be in `members`, `--` required,
  COMMAND required); `sandbox-lifecycle ready`; `sandbox-lifecycle status`;
  `sandbox-lifecycle stop`. Any other form prints a usage line naming all
  five and exits 2. `serve` exits 0 after a drain or a SIGTERM/SIGINT and 1
  on an error; `ready` exits 0 on `ok` else 1; `status` prints the reply and
  exits 0, or 1 when unreachable; `stop` exits 0 on `ok`, 1 when
  unreachable, without waiting for the drain.
- Signal wiring (`main.go`): `serve` gets
  `signal.NotifyContext(context.Background(), syscall.SIGTERM,
  syscall.SIGINT)`; `run` gets `context.Background()` and owns its signals
  itself (01.3), so Ctrl-C never cancels an agent's wrapper. In `run`, a
  done `ctx` is a test hook only: it acts as a requested stop.

Files:
- `sandbox/lifecycle/go.mod`, `main.go`, `protocol.go`, `broker.go`,
  `control.go`, `run.go`, `protocol_test.go`
- `sandbox/tests/test-lifecycle.sh`
- `.github/workflows/sandbox-image.yml`

Work:
1. Write `go.mod` and the five source files with the contracts above.
   Bodies of `serve`, the control server handler (`ready`, `status`,
   `stop`) and `run` are stubs:
   `serve` returns `errors.New("not implemented")`, `run` returns 1. The CLI
   dispatch, `parseJoin`/`formatJoin`, `status.format` and
   `requestControl` are complete.
2. `protocol_test.go`: table tests for `parseJoin` (valid; missing prefix;
   uppercase; 33-character name; trailing space; empty), `formatJoin`
   round trip, `status.format` for each state, and the CLI's usage errors
   (call the dispatch function with argument slices; it must not call
   `os.Exit` itself, `main` does).
3. `sandbox/tests/test-lifecycle.sh` (POSIX sh, `set -eu`): reads the
   `go-upstream` image from the Dockerfile with the reference's `awk`, runs
   it with `--network none`, the module mounted read-only, copies it to a
   writable temp folder, sets `GOTOOLCHAIN=local GOFLAGS=-mod=mod`, fails if
   `gofmt -l .` prints anything, runs `go vet ./...`,
   `CGO_ENABLED=0 go build -o /tmp/sandbox-lifecycle .` and
   `go test -race -count=1 ./...`, and prints
   `Lifecycle tests passed.` Pass `--tmpfs /tmp:exec` so `go test` can run
   its binaries.
4. Add `sh sandbox/tests/test-lifecycle.sh` to the `check` job's "Check
   sandbox configuration and host tools" step, after
   `test-shell-functions.sh`.

External inputs: none in this stage (validation of join lines is
`parseJoin`, defined here and used at the boundary in 01.2).

Done when:
- `sh sandbox/tests/test-lifecycle.sh` passes, with gofmt and vet clean.
- `go build` of the module (inside the test runner) succeeds with
  `CGO_ENABLED=0`.
- ShellCheck reports nothing for `sandbox/tests/test-lifecycle.sh`.
- The constants and tables match [design.md](design.md#timing-go-constants-in-sandboxlifecycleprotocolgo-one-doc-table)
  exactly.

Out of scope: real broker and wrapper logic (01.2, 01.3); Dockerfile,
Compose and images (phase 02); any timing knob read from the environment
(none exists by design).

Model basis: J1 F2 R1 C2 K1 P1 V0 S0 = 8 -> top (override 1: C = 2)

## 01.2 Broker: states, sockets, pools, control socket, drain

Goal: `serve` implements the broker of [design.md](design.md#broker-lifecycle-service)
exactly, proven by unit tests with millisecond durations in a temp folder.

Context:
- Contracts from 01.1 in `protocol.go`, `broker.go`, `control.go`.
- Reference for socket mechanics only: PR #11 `serve`, `accept`,
  `waitForClose`, `drain` in `fix/last-agent-review-fixes:sandbox/lifecycle/main.go`
  (that broker admitted without a `join` line and had no states; do not
  copy its behavior).

Contracts: as defined in 01.1; no new ones. Behavior:
- On start: `MkdirAll` each `cfg.dir/<subdir>` (0755), remove a stale
  socket file, listen, `chmod 0666` each socket; listen on `cfg.control`
  with mode 0600 (remove a stale file first). Listener failure returns an
  error (exit 1; Compose restarts the broker).
- Admission per connection (in its own goroutine): read one line of at most
  `maxJoinLine` bytes within `joinTimeout`; refuse with `R` and close when
  the line fails `parseJoin`, the name is not in that socket's `names`, the
  socket's pool is full, or the state is `draining`. Otherwise write `A`
  (write deadline `joinTimeout`), record the member, and block reading: any
  byte, EOF or error removes it.
- States: start `starting` with deadline `now + startup`. An agent joining
  sets `active` and clears the deadline. The last agent leaving sets `idle`
  with deadline `now + idle`. Reaching a deadline, or a control `stop`,
  enters `draining`: admit no one (the role listeners stay open until `serve`
  returns and answer every join with `R`, so a late client exits 75 with the
  "group is stopping" message rather than "cannot reach"), write `S` to every
  member (agents and services; write deadline `joinTimeout`), wait until no
  members remain or `drain` passes; if any remain, log
  `sandbox-lifecycle: did not stop in time: NAME ...` with their names
  (design "Forced end", layer 4); then close the listeners and return nil.
- `ctx` done (SIGTERM or SIGINT, wired in `main.go` with
  `signal.NotifyContext`; this is Docker or Compose stopping or recreating
  the container) is not a drain: close every listener and member connection
  at once without sending `S`, remove the socket files, and return nil.
  Members then rejoin a replacement broker (design decision 11).
- Services never end or prolong an `active` or `idle` group; agents alone
  count. One exception, in `starting` only: a member admitted on the
  `services` socket (not `daemon`) moves the deadline to
  `max(deadline, now + startup)` (design decision 5).
- Control server: one goroutine per control connection; read one line
  within `joinTimeout`; `ready` -> `ok\n` or `draining\n`; `status` ->
  `status.format()` with `joinable` true only when `active`, or `starting`
  with at least `cfg.margin` before its deadline (`idle` and `draining` are
  never joinable); `stop` -> `ok\n`, then drain (also `ok` when already
  draining); anything else -> close. The
  control listener stays open during draining so health checks see
  `draining`.
- Log to stderr: each state change, and each join and leave with name.
- All shared state behind one mutex; a buffered wake channel signals the
  main loop on joins and leaves.

Files:
- `sandbox/lifecycle/broker.go`, `sandbox/lifecycle/control.go`,
  `sandbox/lifecycle/broker_test.go`

Work:
1. Implement `serve` and the control handler as above.
2. `broker_test.go` (each test uses `t.TempDir()`, durations of tens of
   milliseconds, and helper `join(t, path, name) (net.Conn, byte)`):
   - starting drains after `startup` with no agent; a service member
     receives `S`, and `serve` returns after it disconnects;
   - in `starting`, a services-socket join moves the deadline to `now +
     startup` (the broker outlives the original deadline); a daemon-socket
     join does not; in `idle`, a services-socket join changes nothing;
   - an agent joining keeps the broker past `startup`; leaving starts
     `idle`; a new agent within `idle` returns it to `active`;
   - idle expiry drains; members get `S`;
   - control `stop` drains at once and sends `S` to agents too;
   - `ctx` cancel returns at once: members see EOF without `S`, the socket
     files are gone;
   - drain returns after `drain` even when a member never disconnects, and
     logs that member's name;
   - refusals: malformed line, `codex` on the services socket, `docker` on
     the services socket, `egress-proxy` on the daemon socket, a full pool
     (fill the daemon pool's 4), a join during draining; each gets `R`;
   - a client sending a byte after `A` is removed;
   - control: `ready` is `ok` until draining, then `draining`; `status`
     shows names in join order; `joinable` is `yes` while `active` and while
     `starting` outside `margin`, and `no` while `starting` within
     `margin`, while `idle`, and while draining;
   - restart: a second `serve` on the same folder after the first returned
     replaces stale socket files.
3. Run `sh sandbox/tests/test-lifecycle.sh` (race detector on).

External inputs: the join line from any client on the three role sockets
(possibly a compromised agent or a container on the session daemon): length
bound, read deadline, `parseJoin`, per-socket name list and pool limit. The
control socket is reachable only through `docker compose exec` into the
broker container; its requests get no further checks beyond the line read
deadline and exact matching.

Done when:
- `sh sandbox/tests/test-lifecycle.sh` passes with all tests above.
- `serve` returns nil only after a drain or a `ctx` cancel; listener setup
  errors are returned.
- No timing value appears outside `protocol.go` except in tests.

Out of scope: the wrapper (01.3); CLI and contract changes (if one is needed,
revise 01.1 and its peers); images.

Model basis: J1 F1 R1 C1 K2 P1 V0 S0 = 7 -> top (override 1: K = 2, trust
boundary and concurrency)

## 01.3 Wrapper: join, rejoin, child supervision, both roles

Goal: `run` implements the wrapper of
[design.md](design.md#wrapper-sandbox-lifecycle-run-name----command) for
both roles, proven by unit tests, including pty tests of the agent role.

Context:
- Contracts from 01.1: `run`, `runConfig`, `member`, `members`,
  `formatJoin`, message bytes, exit codes.
- The agent image's current start contract this must preserve: tini is PID
  1 (`init: true` in `sandbox/compose.session.yaml` `x-agent-service`), then
  `sandbox-entrypoint`, then `sandbox-start`, which runs the agent as a
  background child with the terminal passed through, traps TERM
  (`SANDBOX_EXIT_REASON=stop`) and HUP, and traps INT and QUIT with `:`
  (`sandbox/image/sandbox-start`). The wrapper sits between the entrypoint
  and `sandbox-start` from phase 02.
- Service containers have no `init` (the daemon sets `init: false`; the
  others leave the default), so the wrapper is their PID 1.

Contracts: as defined in 01.1. Behavior:
- Join: dial `cfg.socket`, send `formatJoin(name)`, read one byte within
  `cfg.joinTimeout`. Retry dial or timeout errors every `cfg.interval` until
  `cfg.retry` passes, then print `sandbox-lifecycle: cannot reach the
  lifecycle broker at <path>` and return 1. `R` prints the refusal message
  of the design and returns `exitRefused` without starting the child.
- Child: `os.StartProcess`-level start (or `exec.Cmd` with
  `SysProcAttr`) inheriting stdin, stdout, stderr and environment, with
  `Pdeathsig: syscall.SIGKILL`, from a goroutine that called
  `runtime.LockOSThread()` and keeps it locked for the child's life.
  Service role also sets `Setpgid: true`. A start failure prints the error
  and returns 127.
- Reaping: one loop calls `syscall.Wait4(-1, …)`; it records the main
  child's status when its PID returns and discards others (PID 1 reaping).
  Do not also call `cmd.Wait`.
- Signals: `signal.Notify` for SIGTERM, SIGHUP and, in the agent role,
  SIGINT, SIGQUIT, SIGTSTP. Service role: SIGTERM, SIGINT and SIGHUP start a
  requested stop. Agent role: SIGTERM and SIGHUP are forwarded to the child
  (SIGTERM also marks the stop requested and starts the grace timer); SIGINT,
  SIGQUIT and SIGTSTP are received and dropped. The wrapper never reads or
  writes the terminal except its own error lines on stderr.
- Broker watch: read the connection. `S` -> requested stop. EOF or error
  without `S` -> rejoin (same join, retry every `cfg.interval` for up to
  `cfg.rejoin`); success continues; `R` during rejoin -> requested stop;
  window passed -> print `sandbox-lifecycle: lost the lifecycle broker` and
  stop, final status 1.
- Stop: SIGTERM to the child; after `m.grace`, SIGKILL to the child's
  process group (service) or the child (agent). All signals go through
  `cfg.signal`.
- Hard exit (design "Forced end", layer 2): when a stop begins, start a
  timer of `m.grace + cfg.hardExit`; if the main child has not been reaped
  when it fires, print `sandbox-lifecycle: NAME did not stop in time;
  forcing exit.` and return 1 at once (do not wait any longer). Its exit as
  PID 1 (service containers) or as tini's child (agents) ends the rest of
  the container (layer 3).
- Child exit: close the broker connection (leaving), and in the service role
  SIGKILL the child's process group (ignore ESRCH). Return: lost broker -> 1;
  child exited with code c -> c; killed by signal s -> 0 if the stop was
  requested and the role is service, else 128+s.

Files:
- `sandbox/lifecycle/run.go`, `sandbox/lifecycle/run_test.go`,
  `sandbox/lifecycle/pty_test.go`

Work:
1. Implement `run` as above.
2. `run_test.go`, using a fake broker built in the test (a listener that
   reads the join line and answers as the test needs; do not depend on
   01.2's `serve`) and children such as `sh -c 'trap "exit 0" TERM; sleep
   30 & wait'`:
   - no listener: returns 1 after `retry`; a listener appearing within
     `retry` is joined;
   - `R`: returns 75, child never started (marker file absent);
   - service: `S` -> child gets SIGTERM, wrapper returns 0; a child ignoring
     TERM is killed after grace, with a grandchild in its group also gone;
     returns 0;
   - service: child exiting 3 on its own returns 3 and closes the broker
     connection;
   - hard exit, inside the helper subprocess (`TestHelperWrapper`, since
     `run` returns while its reaper still waits for the child): with
     `cfg.signal` replaced by a function that records calls and kills
     nothing, `S` makes the helper exit 1 within `grace + hardExit` (plus a
     small tolerance), having sent SIGTERM then SIGKILL; the test then kills
     the orphaned child itself;
   - lost broker, new listener within `rejoin`: child keeps running;
     no listener: child stopped, returns 1;
   - agent: SIGTERM to the wrapper reaches the child; SIGINT to the wrapper
     does not end the wrapper;
   - Pdeathsig: run the test binary itself as a helper wrapper process
     (`os.Args[0]` with `-test.run=TestHelperWrapper` and an env flag),
     SIGKILL it, and check within 1 s that its child is gone or a zombie
     (state `Z` in `/proc/PID/stat`: it is reparented to the runner's PID 1,
     which may not reap it at once).
   `run` reaps with `Wait4(-1)`, which can take any child of the test
   process: tests that call `run` in-process must not use `t.Parallel` and
   must not have other children running; the Pdeathsig and pty tests run
   `run` only inside the helper subprocess.
3. `pty_test.go` (skip with `t.Skip` when `/dev/ptmx` cannot be opened):
   open a pty with stdlib syscalls; start the helper wrapper in agent role
   on the pty slave with `Setsid` and `Setctty`, child `bash --norc -i`:
   - Ctrl-C (`\x03`) at a `sleep 30` returns to the prompt and the wrapper
     still runs;
   - `sleep 30` then Ctrl-Z (`\x1a`) prints a stopped job; `fg` resumes it;
     Ctrl-C ends it;
   - `exit 7` makes the wrapper exit 7;
   - a non-interactive child (`sh -c 'read x; echo got:$x'`) reads piped
     input written to the pty.
   bash is present in the `golang:*-bookworm` image the runner uses.
4. Run `sh sandbox/tests/test-lifecycle.sh`.

External inputs: the broker's bytes over the client socket (a broker the
wrapper does not control if it was replaced): only `A`, `R`, `S` have
meaning; any other byte is treated as a lost broker (rejoin).

Done when:
- `sh sandbox/tests/test-lifecycle.sh` passes with the tests above, race
  detector on.
- The wrapper never calls `cmd.Wait` alongside `Wait4(-1)`.
- No timing value appears outside `protocol.go` except in tests.

Out of scope: wiring into images or the entrypoint (phase 02); broker logic
(01.2); real Claude or Codex TUI checks (phase 02).

Model basis: J1 F1 R1 C1 K2 P2 V0 S1 = 9 -> top (K = 2: signals,
concurrency, process supervision; P = 2: no pty or supervision code in the
repository)

## Notes
- 2026-11-20: Option B (socket clients) chosen over a Docker-API monitor
  (would need the host Docker socket, root on the host) and a shared PID
  namespace (would let agents reach ssh-agent through `/proc`). User's call.
- 2026-11-20: No host leases; startup order from Compose health checks and
  a 120 s startup window (user suggested relying on depends/health). Removes
  PR #11's `lease`/`lease-keep` modes and the draft's control `lease`
  command.
- 2026-11-21 (plan review round 1, user decision): a launch never rejoins an
  `idle` group. The reviewer showed that a relaunch with changed settings
  recreates the daemon, which outlasts any short idle window, so the group
  drained mid-launch. The user quits mostly to change configuration and
  wants it applied without a long wait: `joinable` is `yes` only while
  `active` (or early `starting`), the host waits for an idle group to exit,
  and the idle window drops from 10 s to 2 s to keep that wait short.
- 2026-11-21 (plan review round 1, user decision): SIGTERM no longer drains.
  Recreating the broker (a release changing its image) would otherwise stop
  every running session of the project. Stopping is the explicit control
  `stop`; SIGTERM exits quietly and members rejoin the replacement.
- 2026-11-20: Concern raised and settled: in the draft, a 30 s host lease
  moved the broker out of `starting` and could drain a cold launch while
  Compose waited ~65 s for the daemon. Dropping leases removes the case.
- 2026-11-20: Join line carries the member's name: used for per-socket
  admission (so a daemon-side container cannot pose as an agent) and for
  `status` and logs; it never changes a lifetime decision.
- 2026-11-20: Timing lives only in `protocol.go`; there are no environment
  knobs, so tests use `brokerConfig`/`runConfig` with short durations.
- 2026-11-21 (user): every container must end when the broker signals a
  stop, even if it hangs. Added the wrapper's hard exit (01.3) and the
  broker's log of members that never left (01.2); see design "Forced end".
- 2026-11-21 (plan review round 2, user): a cold launch could drain
  mid-start when an SSH passphrase prompt used most of the 120 s startup
  window. A services-socket join in `starting` now resets the window;
  daemon-socket joins do not (daemon workloads must not extend a lifetime).
