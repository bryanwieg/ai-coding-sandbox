# Phase 01: Self-updating shell functions

Implement with the implement-in-phases skill; do not build from this file
without it. Model tiers map to models in [models.md](models.md) and
[models-codex.md](models-codex.md).
Status: in progress (stages done: 01.1, 01.3)
Before: `sandbox claude|codex` pulls the latest released images through the
`oci://...-compose:latest` Compose file and `pull --policy missing`. The shell
functions in `sandbox/shell/sandbox.sh` change only when the user reruns
`install.sh`, and the user must then reload every shell.
After: every `sandbox`, `sandbox claude` or `sandbox codex` launch from an
installed copy first fetches `sandbox.sh` from the source it was installed
from, before the `.sandbox/env` init and the image pull. When the fetched file
differs from the installed copy, it is validated and swapped in atomically.
When the installed copy differs from what this shell loaded, the shell
sources it and reruns the launch with the new definitions. That covers an
update made by this launch, by another terminal, or by an `install.sh`
rerun. A failed fetch warns once and the launch continues. Tests cover this
in bash and zsh, and the docs describe it.

## Size

This is not a small plan. It adds a trust boundary: each agent launch fetches
host-side code from the network and runs it unsandboxed. It also adds a
persisted file, `source-url`, that `install.sh` writes and the functions read.

Files:
- `sandbox/shell/sandbox.sh`
- `install.sh`
- `sandbox/tests/test-shell-functions.sh`
- `sandbox/tests/test-install.sh`
- `sandbox/README.md`
- `README.md`
- `AGENTS.md`

Users searched (`grep -rn 'sandbox.sh\|install.sh'` over the repository):
- `install.sh`
- `sandbox/bin/install-shell-functions`, which sources a checkout copy
- `sandbox/bin/audit-sandbox:274`, which sources the checkout copy
- `test-shell-functions.sh`, which sources a checkout copy through
  `install-shell-functions`
- `test-install.sh`, which installs and then only runs `type sandbox-prune`
- `release.yml`, which excludes `sandbox/shell/**`, so the raw file on `main`
  is live as soon as it is pushed
- `check-sandbox:230`, which runs `sh -n` on POSIX scripts only, not on
  `sandbox.sh`

`git ls-files sandbox/shell` lists only `sandbox.sh`, so a checkout has no
`source-url` next to its copy. None of these users launches an agent from an
installed copy, so the updater never acts in them.

## Assumptions

- Verified: in bash 5.3 and zsh 5.9, when a function sources a file that
  redefines it, the function keeps running its old body. A re-invoked call
  runs the new body. A `local` set in the outer call is visible in the inner
  call and is gone once the outer call returns. Checked with a probe script,
  and confirmed independently by the round-1 reviewer.
- Verified: at the top level of a sourced file, `${BASH_SOURCE[0]}` (bash)
  and `${(%):-%x}` (zsh) give the path the file was sourced by. The zsh form
  must go through `eval` so that bash parsing and ShellCheck accept it. The
  path is relative when the `.` command used a relative path. Checked with
  the same probe.
- Verified: `zsh -n FILE` and `bash -n FILE` reject a file with a stray `fi`
  and read no startup files (reviewer probe).
- Verified: `install.sh` installs to
  `dir=${SANDBOX_FUNCTIONS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-coding-sandbox}`.
  Its default `url` is
  `https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/sandbox/shell/sandbox.sh`.
  It writes only `. "$dir/sandbox.sh"` to the startup file, so neither
  override persists (`install.sh:20-24`, `:89`). It validates the download
  with `grep -q '^sandbox() {$'` (`:57`) and swaps it in with `mv -f` (`:62`).
- Verified: `test-install.sh:74` asserts the install folder holds exactly
  `sandbox.sh` after failed downloads. It must change once `source-url`
  exists.
- Verified: the test fixture's stub `docker` compares launch **stdout**
  exactly, and logs every docker call to `$SANDBOX_TEST_LOG`. All updater
  messages therefore go to stderr.
- Verified: `curl -f` with a `file://` URL fails for a missing file. Tests use
  `file://` URLs, as `test-install.sh` does.
- Verified: `. "$var"` triggers ShellCheck SC1090 (reviewer probe) and needs
  a `# shellcheck source=/dev/null` directive.
- Open: copies installed before this change have neither the updater nor a
  `source-url`. They get both from one `install.sh` rerun. The new code
  cannot fix this, so the docs say so.

## Decisions

From the user, 2026-11-21:
- Check on every agent launch: `sandbox`, `sandbox claude` and
  `sandbox codex`, with or without further ARGS, alongside the image
  updates. Other services and the other `sandbox-*` functions do not check.
- Always on, with no opt-out switch.
- A failed check (offline, no curl, bad download) warns once on stderr. The
  launch continues, and a bad download never replaces the installed copy.
- Only an installed copy updates itself. A shell that sourced a checkout
  copy skips the check entirely and makes no network request.

From planning, 2026-11-21, after review round 1:
- The installed copy is identified by a `source-url` file next to it, which
  `install.sh` writes. The updater fetches only from the URL in that file.
  This keeps a fork or custom-folder install on the source and folder the
  user chose. Otherwise the non-persisted `SANDBOX_FUNCTIONS_URL` and
  `SANDBOX_FUNCTIONS_DIR` would silently switch them to upstream or disable
  updates. These two variables stay install-time only.
- Each shell records a checksum of the copy it loaded. The reload decision
  compares the installed copy with that checksum, not with the download, so
  every open terminal picks up an update on its next launch, whoever made it.

## Stages

| Stage | Goal | Tier | Order | Status |
| --- | --- | --- | --- | --- |
| 01.1 | Updater, in-shell reload and the installer's source record | top | first | done |
| 01.2 | Regression tests in bash and zsh | middle+ | after 01.1, parallel with 01.3 | planned |
| 01.3 | Documentation and repository rules | middle+ | after 01.1, parallel with 01.2 | done |

## 01.1 Updater, in-shell reload and the installer's source record

Goal: an agent launch from an installed copy refreshes that copy from its
recorded source, loads any installed copy newer than what the shell has, and
reruns itself with the new definitions. A checkout copy, another service or
a failed fetch leaves the launch as it is today.

Context:
- `sandbox/shell/sandbox.sh` defines `sandbox()`. Its help `case`
  (`-h|--help`) returns before Docker. The `.sandbox/env` auto-init block
  follows it, and the `claude|codex` branch calls `_sandbox_prepare_images`
  (the image pull and build) first.
- Locals in this file use the `sandbox_` prefix.
- `install.sh:51-62` shows the download, check and swap pattern to mirror:
  `mktemp` next to the target, `curl -fsSL`, the `grep -q '^sandbox() {$'`
  check, `chmod 0644`, `mv -f`.
- The probe results under Assumptions settle the reload mechanics.

Contracts:
- **Source record.** `install.sh`, right after `mv -f "$download" "$functions"`,
  writes `$dir/source-url`: the `url` it downloaded from plus a newline.
  It writes through a `mktemp "$dir/.source-url.XXXXXX"` file, then
  `chmod 0644`, then `mv -f`. The temp file's variable is `record`, set to
  empty (`record=`) before the existing `trap` at `install.sh:55`, which
  becomes `trap 'rm -f "$download" "$record"' EXIT HUP INT TERM`. Under
  `set -eu`, an unset `record` would make the trap fail and leave the
  download's temp file behind. A failed download writes nothing, as now.
- **Top-level block** in `sandbox.sh`, right after the header comment and
  before `sandbox()`. It sets two globals:
  - `_sandbox_functions_file`: the absolute path of the file being sourced.
    Under zsh (`[ -n "${ZSH_VERSION:-}" ]`) it comes from
    `eval '_sandbox_functions_file=${(%):-%x}'`, otherwise from
    `${BASH_SOURCE[0]}`. Prefix `$PWD/` when the path is not absolute.
  - `_sandbox_functions_loaded`: `$(cksum < "$_sandbox_functions_file" 2>/dev/null)`,
    or empty if that fails.

  Re-sourcing the file sets both again.
- **`_sandbox_self_update`.** No arguments. It returns 0 only when it
  sourced an installed copy that differs from what the shell had loaded, and
  1 otherwise. All of its output goes to stderr. Declare every local with
  `local` on its own line before assigning it; a one-line `local a=X b=$a`
  expands `$a` too early. The locals are `sandbox_record`, `sandbox_url`,
  `sandbox_functions`, `sandbox_download` and `sandbox_replaced`; never
  `functions`, which zsh reserves. Steps, in order:
  1. `sandbox_functions=$_sandbox_functions_file` and
     `sandbox_record=${sandbox_functions%/*}/source-url`. If
     `sandbox_record` is not a regular file, return 1 silently. This covers
     a checkout copy or an old install. No command or network request runs
     before this test.
  2. `sandbox_replaced=0`. Read the first line of the record into
     `sandbox_url` with `IFS= read -r sandbox_url < "$sandbox_record"`.
  3. Fetch. The fetch fails if the URL is empty, `curl` is missing,
     `mktemp "${sandbox_functions%/*}/.sandbox.sh.XXXXXX"` fails, or
     `curl -fsSL --connect-timeout 5 --max-time 20 "$sandbox_url" -o "$sandbox_download"`
     fails (stderr discarded). On failure, remove any temp file, print
     `sandbox: could not check for shell function updates; continuing with the installed copy.`
     and go to step 6.
  4. If `cmp -s "$sandbox_download" "$sandbox_functions"`, remove the temp
     file and go to step 6.
  5. Validate. The download must contain a line matching `^sandbox() {$`
     and pass the running shell's parse check, `zsh -n` under zsh or
     `"$BASH" -n` under bash, with output discarded.
     - If validation fails, remove the temp file, print
       `sandbox: $sandbox_url is not valid sandbox shell functions; keeping the installed copy.`
       and go to step 6.
     - Otherwise run `chmod 0644` and `mv -f` onto `sandbox_functions`. If
       either fails, remove the temp file, print the step 3 message and go
       to step 6. On success, set `sandbox_replaced=1`.
  6. If `$(cksum < "$sandbox_functions" 2>/dev/null)` equals
     `"$_sandbox_functions_loaded"`, return 1. The shell already has the
     installed copy.
  7. Run `. "$sandbox_functions"` with a `# shellcheck source=/dev/null`
     directive. If it fails, print
     `sandbox: could not load the updated shell functions; open a new terminal to load them.`
     and return 1. The installed copy was validated when it was written, by
     this updater or by `install.sh`, so it is not validated again.
  8. Print one line and return 0:
     - if `sandbox_replaced=1`:
       `sandbox: updated the shell functions from $sandbox_url and loaded them into this shell.`
     - otherwise:
       `sandbox: loaded the shell functions updated since this shell started.`
- **Launch hook.** In `sandbox()`, immediately after the help `case` and
  before the `.sandbox/env` block, insert:
  ```sh
  # Agent launches first update the installed shell functions, alongside
  # the image updates below, and rerun with any newer definitions.
  case "${1:-claude}" in
      claude|codex)
          if [ -z "${_sandbox_update_checked:-}" ] && _sandbox_self_update; then
              local _sandbox_update_checked=1
              sandbox "$@"
              return
          fi
          ;;
  esac
  ```
- **Help and header.** In the header comment, the `sandbox [SERVICE [ARGS...]]`
  entry gains a line: agent launches first update the installed functions.
  The `HELP` text gains one sentence after its first paragraph:
  `Agent launches (claude, codex) first update the installed shell functions and load them into this shell.`

Files: `sandbox/shell/sandbox.sh`, `install.sh`, `sandbox/tests/test-install.sh`
(line-74 assertion only).

Work:
1. In `install.sh`, write the source record, update its header comment to
   mention `source-url`, and extend the `trap` as the contract says. In
   `sandbox/tests/test-install.sh`, change the line-74 folder assertion to
   expect exactly `sandbox.sh` and `source-url`, with no temp file.
2. In `sandbox.sh`, add the top-level block.
3. Add `_sandbox_self_update` after `_sandbox_prepare_images`, with a comment
   explaining why only an installed copy, identified by its `source-url`,
   updates itself.
4. Insert the launch hook in `sandbox()`.
5. Update the header comment and the `HELP` text.
6. Run `shellcheck sandbox/shell/sandbox.sh install.sh`.
7. Run `sh sandbox/tests/test-shell-functions.sh`, which must pass unchanged
   because it sources a checkout copy.
8. Run `sh sandbox/tests/test-install.sh`, which must pass.

External inputs: the downloaded file (network or a `file://` URL). It is
checked once, in step 5, before it replaces anything. The `source-url`
record and the installed copy come from `install.sh` or this updater, so
they are not checked.

Done when:
- ShellCheck is clean on both files, `sh -n install.sh` passes, and
  `test-shell-functions.sh` passes.
- `test-install.sh` passes with the updated folder assertion.
- A manual run shows the update and reload work in bash and zsh, with a
  stub docker: put a copy plus a `source-url` holding `file://<changed copy>`
  in a temp folder, source it, and run `sandbox`. 01.2 automates this.
- With a checkout copy sourced, `_sandbox_self_update` returns 1 at step 1
  and makes no request.

Out of scope:
- `install.sh`'s download logic and messages, apart from the source record.
  Its "open a new terminal" message still applies to a first install.
- `install-shell-functions`, the release workflow and the other `sandbox-*`
  functions.
- Any opt-out switch.

Model basis: J1 F1 R1 C2 K2 P1 V1 S1 = 10 -> override 1 (C = 2: the
`source-url` format is shared between the installer and the functions;
K = 2: a trust boundary, a persisted file, and the shell's function table
replaced while it runs) -> top.

## 01.2 Regression tests

Goal: `test-shell-functions.sh` proves the updater's behavior in bash and,
when installed, zsh. `test-install.sh` proves the installer writes the
source record.

Context:
- In `sandbox/tests/test-shell-functions.sh`, the per-shell loop
  `for shell in bash zsh` defines `run DIR CMD`. It sources `$rc` (the
  checkout copy) with the stub `docker` first on `PATH`.
- `trust`, `launch` and `agent` give the expected stdout of a plain launch:
  `"${trust}${launch}${agent}claude "` after `tr '\n' ' '`.
- `$test_dir/project` has an empty `.sandbox/env`. `$test_dir/empty`
  serves as a refusing home folder via `HOME='$test_dir/empty'`.
- The stub logs each call to `$SANDBOX_TEST_LOG` (`$log`). The image pull
  logs a line containing `pull --quiet --policy missing`.
- `sandbox/tests/test-install.sh` installs from a `file://` URL into
  `$home/.local/share/ai-coding-sandbox/`.
- 01.1's contracts define the messages, the `source-url` format and the
  return values tested.

Contracts: uses 01.1's messages and record format verbatim. Adds no new
interface.

Files: `sandbox/tests/test-shell-functions.sh`, `sandbox/tests/test-install.sh`
(01.1 already changed its line-74 assertion).

Work:
1. `test-install.sh`:
   - After each successful install, assert that `source-url` next to
     `sandbox.sh` holds exactly `$SANDBOX_FUNCTIONS_URL`.
   - Rerun the installer with a second `SANDBOX_FUNCTIONS_URL` (another
     `file://` copy) and assert that `source-url` now holds it, so a fork or
     custom install keeps its own source.
   - Assert that a failed download leaves `source-url` unchanged.
   - Extend the header comment by a clause.
2. `test-shell-functions.sh`, inside the per-shell loop after the existing
   cases. Define `install_copy URL`. It recreates
   `$test_dir/installed-$shell/` holding a copy of
   `$root_dir/shell/sandbox.sh` and a `source-url` with `URL`.
3. Define `run_installed DIR CMD`:
   `(cd DIR && PATH="$test_dir/bin:$PATH" "$shell" -c ". \"$test_dir/installed-$shell/sandbox.sh\"; CMD")`.
4. Build `$test_dir/upstream-changed.sh` with awk: the checkout copy, plus
   two lines inserted as the first lines inside `sandbox() {`:
   `    echo updated-launcher >&2` and
   `    echo updated-launcher >> "$SANDBOX_TEST_LOG"`.
5. Cases. Unless a case says otherwise, each asserts the installed copy's
   final contents (`cmp`) and that the folder holds only `sandbox.sh` and
   `source-url` (no temp file).
   - **Changed upstream, `sandbox && sandbox` in `$test_dir/project`:**
     - stdout is two plain claude launches;
     - stderr has the "updated the shell functions from" line once, and
       `updated-launcher` twice (the first launch's rerun, then the second
       launch with no second update);
     - the copy equals upstream;
     - in `$log`, the first `updated-launcher` line comes before the first
       line containing `pull --quiet --policy missing`.
   - **Changed upstream, `sandbox codex`:** stdout is one plain codex
     launch; `updated-launcher` appears once.
   - **Changed upstream, `sandbox claude bash`:** stdout equals
     `"${trust}${launch}${agent}claude bash "`. This proves the rerun keeps
     its arguments.
   - **Changed upstream, in the refusing home folder** (`$test_dir/empty`
     with `HOME='$test_dir/empty'`): the launch fails with
     `no .sandbox/env here`, but the copy equals upstream and stderr has
     the update line. This shows the update runs before the init block.
   - **Unchanged upstream** (the URL points at the checkout copy): stdout is
     a plain launch, stderr has no `sandbox:` line, and the copy is
     unchanged.
   - **Updated out of band.** Source the installed copy. Then, in the same
     `-c` script and before launching, overwrite the installed copy with
     `upstream-changed.sh` and point the record at it, as another terminal
     or `install.sh` would. Then run `sandbox`.
     - stderr has `loaded the shell functions updated since this shell started.`
       once and `updated-launcher` once.
     - stdout is one plain launch.
   - **Unreachable URL** (`file://$test_dir/missing`): the "could not
     check" line appears once, the launch proceeds, and the copy is
     unchanged.
   - **Unreachable URL plus an out-of-band update:** the "could not check"
     line, then the "loaded ... since this shell started" line.
     `updated-launcher` appears once.
   - **Invalid downloads:** one with no `sandbox() {` line, and one valid
     copy with a lone `fi` appended (a parse error). Each prints the
     "is not valid" line once, the launch proceeds, and the copy is
     unchanged.
   - **Changed upstream, `sandbox trust` and `sandbox --help`:** neither
     changes the copy or prints an update line.
   - **Changed upstream, launched through the existing checkout `run`:**
     no update line is printed. No network request is made: a `curl` stub
     in a bin folder used only by this case logs to a file, and the test
     asserts that file stays empty.
6. Extend the file's header comment with one clause covering this.

External inputs: none.

Done when:
- Both test scripts pass with bash and zsh installed.
- Temporarily removing 01.1's launch hook makes the changed-upstream cases
  fail. Check this once by hand, then restore the hook.

Out of scope: the stub `docker`'s existing cases and the behavior of the
existing tests.

Model basis: J1 F0 R1 C0 K1 P1 V0 S2 = 6 -> override 3 (S = 2: the
hook-removal check depends on a run's result) -> middle+.

## 01.3 Documentation and repository rules

Goal: the READMEs and `AGENTS.md` describe the self-update and its trust
implication.

Context:
- The root `README.md` Quick start ends "Rerunning it updates."
- In `sandbox/README.md`:
  - The shell-functions section (around lines 45-63) says "rerunning it
    updates them" and that the startup file "runs code fetched from this
    repository's `main` branch".
  - Its function table has a `sandbox` row, and the paragraph after the
    table describes a `claude`/`codex` launch (pull, wait, approve,
    unlock).
  - Lines 116-117 tell checkout users to reload with
    `. sandbox/shell/sandbox.sh`. That stays true, because checkout copies
    never update themselves.
- `AGENTS.md` under `## Releases` says "A push to `main` publishes the
  images and the Compose file that every project's sessions load". It also
  asks for a concise root README, with the details in `sandbox/README.md`.

Contracts: describe 01.1 exactly: when it checks, which copy, the recorded
source, the failure behavior and the in-shell reload.

Files: `README.md`, `sandbox/README.md`, `AGENTS.md`.

Work:
1. In `README.md`, replace "Rerunning it updates." with one sentence:
   agent launches keep the installed functions current and load updates
   into the running shell, and rerunning the installer also updates.
2. In `sandbox/README.md`, add a short paragraph after the installer
   paragraph covering these points:
   - The installer records its download URL in `source-url` next to the
     copy.
   - Each `sandbox`, `sandbox claude` or `sandbox codex` launch from that
     copy first downloads `sandbox.sh` from that URL. If the file has
     changed and passes validation, it replaces the copy atomically.
   - Whenever the installed copy differs from what the shell loaded, the
     launch sources it and continues with the new functions, before pulling
     images. That holds whether this launch, another terminal or an
     installer rerun updated it.
   - A copy sourced from a checkout never updates itself and makes no
     request.
   - A failed check warns and launches with the installed copy.
   - Trust: every launch runs host code from that URL without review, as
     the Compose file from `:latest` already shapes each session. Users who
     do not want that can source a checkout copy instead.
   - Copies installed before this feature need one installer rerun.

   Also update the table's `sandbox` row and the post-table launch
   paragraph to mention the update step.
3. In `AGENTS.md` `## Releases`, extend the first bullet: a push to `main`
   also publishes `sandbox/shell/sandbox.sh`, which every installed
   launcher loads on its next agent launch, with no release run. Changes to
   it must therefore keep working with the Compose file and images already
   released.

External inputs: none.

Done when:
- The three files describe the behavior above.
- Nothing in them still says the installed copy needs a rerun or a new
  shell to update. Two notes are exempt and stay: the checkout reload note
  at `sandbox/README.md:116-117`, and the one-time installer rerun for
  copies installed before this feature.
- `git diff --check` is clean.

Out of scope:
- `sandbox/image/session-guide.md` and `session-rules.md`, because this is
  host-side behavior, not what a session provides or allows.
- `install.sh`'s messages.

Model basis: J1 F1 R1 C0 K0 P1 V2 S0 = 6 -> override 3 (V = 2) -> middle+.

## Phase finish

After all stages:
- Run `sandbox/bin/check-sandbox`, both test scripts, `shellcheck` on the
  changed shell files, and `git diff --check`.
- Leave a clean working tree.

## Notes

- Plan start: ee45539
- 2026-11-21: models.md regenerated before the first dispatch; unchanged.

- 2026-11-21: Concern raised: auto-update runs unreviewed host code on every
  launch. That widens what a compromised `main` reaches; today only an
  installer rerun runs new code. The user chose always-on with no opt-out.
  The mitigations are the `source-url` record, which keeps users on the
  source they chose, and the documentation (01.3).
- 2026-11-21: Re-invoking `sandbox` after the reload, instead of continuing
  in the old body, keeps the whole launch on the new definitions. The probe
  showed both shells tolerate redefining the running function.
- 2026-11-21: A Ctrl-C during the download can leave a `.sandbox.sh.XXXXXX`
  temp file, because a function in an interactive shell should not install
  traps. This is accepted: the file is harmless and never sourced.
- 2026-11-21: Pre-existing: `release.yml` excludes `sandbox/shell/**`, so
  shell changes reach users before the same push's images are released.
  01.3 records the compatibility rule this implies in AGENTS.md.
- 2026-11-21, review round 1: these fixes were made:
  - the reload is decided by the loaded checksum, so other terminals and
    installer reruns are covered (blocking);
  - the installed copy and its URL come from the `source-url` record,
    because the environment variables do not persist;
  - the checkout reload note is exempted in 01.3;
  - `check-sandbox` was added at the phase finish;
  - local names, declaration order and the SC1090 directive are fixed;
  - ordering assertions were added in 01.2.
- 2026-11-21, review round 2 (verdict ready): these fixes were made:
  - `record=` is set before the trap, and the line-74 assertion moved into
    01.1 so 01.1 ends with passing tests;
  - 01.2 was re-scored S2 -> middle+;
  - tests were added for no checkout request, ARGS kept on the rerun, and
    `source-url` following a new URL;
  - 01.3 exempts the old-install note.
