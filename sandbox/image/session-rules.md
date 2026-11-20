# Sandbox Session Rules

These rules govern every session in this sandbox. They come from the sandbox
image, follow the session guide above, and apply in addition to the
project's own instructions; where they conflict, these rules win.

## Workspace

- The working directory is the selected project. It is the only writable
  location besides `/tmp`, `/cache` and the agent's own state.
- The optional reference folder is read-only: other projects may be read
  for context, never modified.
- `.sandbox/` in the project is read-only configuration owned by the user.
  Do not try to change it, its effects, or its permissions.
- `.sandbox/env` and `.sandbox/agent.env` hold the user's secrets. Never
  read either file in another project. Use this project's secrets only
  through the environment variables the sandbox provides.

## Security boundary

- Treat the container as the security boundary. Do not attempt to escape it,
  weaken it, or replace it with another sandboxing mechanism.
- Do not enable privileged mode, add Linux capabilities, disable
  `no-new-privileges`, relax seccomp, use host networking, mount host paths,
  or access the host Docker daemon or any Docker socket.
- Exception: when `DOCKER_HOST` is set, Docker may be used, but only against
  that session daemon. Without `DOCKER_HOST`, do not run Docker. Do not use the
  daemon to probe the host or other containers, and do not try to widen its
  privileges.
- Exception: containers on the session daemon may bind-mount that daemon's
  own socket, `SANDBOX_DOCKER_SOCKET`. Mount no other path of the daemon's
  container besides the project, such as its certificates or data, and do
  not hand the socket to images you would not let run Docker yourself.
- Do not stop or interfere with the sandbox's own processes and services: the
  egress proxy and its lease (`sandbox-proxy-lease`), the session daemon and
  its lease (`sandbox-docker-lease`), the port forwarder, and the ssh-agent.
- Do not create tunnels, VPNs, reverse proxies, remote shells, or listeners
  that expose a service outside its intended Docker network. Exception: the
  ports the user set in the `SANDBOX_PUBLISH_*` slots are forwarded to the host from
  the session daemon. Only the user sets them; do not try to add, change, or
  reach around them.
- Do not probe host paths, host services, or other containers.

## Network and data handling

- Use the configured egress proxy. Do not clear, override, or bypass proxy
  settings, and do not add alternative DNS or network routes. Containers'
  direct route under `SANDBOX_DAEMON_EGRESS=direct` is for the workloads that
  need it, not a way around the proxy for this session's own traffic.
- Internet access is deny-by-default: the sandbox's base allowlist plus the
  project's egress policy once the user approved it. When a task needs another
  destination, including documentation or source code to read, ask the user
  to add it to `.sandbox/egress-policy.yaml` and approve it, naming the exact
  host; never work around the allowlist, and never present guesses as the
  content of a page you could not read.
- Never send workspace contents, credentials, tokens, configuration, or logs
  to an external service unless the user explicitly authorizes that exact
  destination and data flow.
- Read secrets only to use them for their purpose. Never print, log, commit,
  copy, embed in images or files, or add to Compose files any secret.

## GitHub

- GitHub is reachable over HTTPS through the proxy for task-scoped Git
  operations. Git authenticates with the GitHub CLI's stored token. No other
  Git host is approved unless the user's egress policy adds it.

## SSH

- SSH is available only when the user enabled it and unlocked keys; only to
  destinations and ports in the egress policy's `ssh` list; and only through
  `SSH_AUTH_SOCK`.
  Do not look for, copy, or create private keys, and do not add, remove, or
  lock identities in the agent.
- Never bypass host key checking: no `StrictHostKeyChecking=no` or
  `accept-new`, no other `UserKnownHostsFile`, `KnownHostsCommand` or
  `HostKeyAlias`, and no other way around `known_hosts`. When a host's key
  is unknown, run `sandbox-ssh-hostkey <host>` (it never logs in), give the
  user the exact line and fingerprint it prints for
  `.sandbox/ssh/known_hosts`, and wait for them to add it. When it reports
  a changed key, stop and tell the user; do not connect.
- Connect only to the machine the user's request is about. Do not reach
  another machine through it without the user's explicit permission for
  that request: no `-J`/`ProxyJump` or `ProxyCommand` through a host, no
  agent forwarding (`-A`), no `-L`/`-R`/`-D` forwards, and no `ssh`, `scp`,
  `rsync` or other remote access run on a remote machine. Permission for
  one request or one hop does not carry over to the next.
- Treat SSH access as access to real infrastructure. Prefer read-only
  inspection. Request explicit approval before changing configuration,
  restarting services, or doing anything disruptive on a remote machine.

## Safe operation

- Create temporary repositories and disposable clones in a unique directory
  under `/tmp`, with automatic cleanup. Remove generated repositories before
  finishing; if failure evidence must remain, report its path and cleanup
  command.
- Prefer local, reversible work. A push, tag, release, or other remote state
  change requires an explicit user request for that action. Do not publish
  incidental local work.
- If a task conflicts with these rules, stop and ask for explicit approval;
  do not work around the restriction.

## User plugins

- The plugins installed from the `ai-coding-plugins` marketplace are the
  user's own. Their skills are the user's preferred workflows: use one
  whenever a request matches its description.
