# Sandbox TODO

Open observations about the sandbox, each with a suggested resolution. Items
are grouped by what they block. Check them off, or delete them, as they are
resolved.

## Secrets inside the container

- [ ] **Remaining exposure.**
  Done: SSH private keys never enter an agent container. Only the `ssh-agent`
  and `ssh-unlock` services, which have no network, mount the key folder, and
  they require private key files to be readable only by their owner;
  passphrases are optional. GitHub uses HTTPS through `gh`.
  Each agent has its own state volume, so neither can read the other's
  credentials.
  *Remaining:*
  - The `gh` token is stored in plaintext in each state volume and is
    readable by any process the agent runs. Use a fine-grained token
    limited to the needed repositories, with an expiry.
  - Bind each key to its hosts with `ssh-add -h <host>`, available in
    OpenSSH 8.9 and later. A process could then use the agent only for the
    hosts each key is meant for, not every host in the `ssh` allowlist.
    This needs a small per-key host map, for example a `<key>.hosts` file
    next to each key.
  - A session with SSH can also run `ssh-add -D`, lock the agent, or add
    its own keys. That is a nuisance rather than a key leak, and
    `sandbox-unlock` restores the keys.
  - On OPNsense, use a dedicated non-root user and restrict its key with
    `from="<sandbox egress IP>"`.
  - `audit-sandbox` does not run an SSH-enabled session; the ssh-agent test
    (`tests/test-session-ssh-agent.sh`) covers the sidecar on its own.

  The agents' own login credentials cannot be hidden from the agent itself.
  Revoke them if a compromise is suspected.

## CI and updates

- [ ] **Claude Code release channel.**
  The pin tracks npm `latest`, matching how Codex is tracked. npm also
  publishes a `stable` channel.
  *Resolution:* keep `latest` for parity, or switch to `stable` if
  day-one releases cause churn.

## Images

The untagged `latest` and `sha-*` tags of `ghcr.io/bryanwieg/ai-coding-sandbox`
are no longer published and stop at their last Codex build. They share image
versions with `codex-latest` and `codex-sha-*`, which published Compose files
pin by digest, so deleting those versions would break sessions; GHCR cannot
remove a tag alone. Leave them, or delete each version once it ages out.

## VS Code

- [ ] **Extensions that write to the home fail.**
  The home is read-only, and only `~/.vscode-server` and
  `~/.vscode-remote-containers` link into `/cache`. Copilot Chat logs
  `ENOENT: mkdir '/home/claude/.copilot'` and `mkdir '/home/claude/.cache'`.
  *Resolution:* link `~/.cache` (or set `XDG_CACHE_HOME`) and the
  extension-specific folders into `/cache/vscode`, if those extensions are
  wanted.
