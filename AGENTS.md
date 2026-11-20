# Sandbox Repository Agent Guidelines

Every sandbox session gets the sandbox's guide and rules from its image
(`sandbox/image/session-guide.md` and `sandbox/image/session-rules.md`). The
rules govern all work in a session: the security boundary, network and data
handling, GitHub, SSH, safe operation and user plugins. This file adds the rules for developing this repository.
Projects below `src/` are independent repositories with their own
instructions; the development rules here do not apply to them.

## Scope

- In a session of this repository, its tracked sandbox framework is the
  scope. The projects below `src/` are ignored by this repository; do not
  modify them unless the user explicitly asks. To work in one, the user
  starts a session in it.
- Do not alter or commit ignored contents, such as the projects, `.sandbox/`
  or files left over from `run-sandbox`, as part of sandbox maintenance.

## Development

- `sandbox/compose.session.yaml` is the only launch path: everything a
  session needs comes from the images and the published Compose file. Keep
  host-side helpers in `sandbox/bin/` and `sandbox/shell/` optional
  conveniences, and do not add a parallel launcher. The one exception in
  location is the root `install.sh`, which stays at the root for a short
  `curl` URL.
- Keep startup lean. Keep exhaustive or environment-dependent verification in
  explicit check and audit commands rather than running it on every start.
- Prefer small POSIX `sh` scripts and standard platform tools. Preserve strict
  error handling, quote paths and arguments, and run ShellCheck for changed
  shell scripts.
- Keep the root `README.md` as the concise entry point and put detailed
  operation, security, authentication and troubleshooting guidance in
  `sandbox/README.md`, updating each only when its contract changes. Update
  `sandbox/image/session-guide.md` when what a session provides or how its
  configuration works changes, and `sandbox/image/session-rules.md` when
  what it allows changes.
- Test image and Compose changes in sessions of this repository, whose
  `.sandbox/env` builds the images from the checkout with
  `sandbox/compose.dev.yaml`.
- Add focused regression coverage for changed behavior. Keep checks
  structural and policy-independent unless a specific security invariant or
  runtime boundary is under test.
- Finish changes with the relevant tests, `sandbox/bin/check-sandbox`,
  `git diff --check` and a clean working tree.

## Changes to the security boundary

- Obtain explicit user approval before changing Dockerfiles, Compose files,
  the proxy or its base policy, network topology, mounts, users, privileges,
  security options, or the session rules.
- Preserve non-root execution, read-only root filesystems, dropped
  capabilities, `no-new-privileges`, internal-only agent networking, the
  proxy as the only service with an uplink and without a published port,
  ports published only by the forwarder, and the SSH key folder mounted only
  by the ssh services. The session daemon's documented exceptions are fixed;
  do not widen them.
- For an approved boundary change, explain the threat impact and add or
  update a focused verification. Run `sandbox/bin/check-sandbox` for every
  configuration change, and `sandbox/bin/audit-sandbox` when networks,
  mounts, privileges or proxy behavior change. GitHub's runners cannot run
  the session daemon, so run the full audit and the daemon and forwarder
  tests locally.

## Releases

- A push to `main` publishes the images and the Compose file that every
  project's sessions load. Push, merge, tag, dispatch a workflow or release
  only on an explicit user request for that action.
- The `automerge` and `automerge-squash` labels merge a pull request and
  release it once its checks pass (`.github/workflows/automerge.yml`).
  Adding one is a merge request: do so only when the user asks for it.
