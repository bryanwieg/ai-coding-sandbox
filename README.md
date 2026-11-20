# AI Coding Sandbox

Runs a coding agent, Codex or Claude Code, in an isolated Docker Compose
session for one project at a time. The agent can change only that project,
optionally reads a reference folder of your choice, reaches the Internet only
through an allowlisting proxy, and gets its own rootless Docker daemon instead of the
host's. A project needs only Docker with Compose 2.30 or newer and a
`.sandbox/` folder; the images and the Compose file are published from this
repository.

```text
ai-coding-sandbox/
├── AGENTS.md     # Rules for agents developing this repository
├── CLAUDE.md     # Imports AGENTS.md for Claude Code
├── sandbox/      # Images, Compose file, host tools, tests and documentation
└── src/          # Optional, ignored place for your own project checkouts
```

## Quick start

To install or update, run this in the bash or zsh terminal you use:

```sh
curl -fsSL https://raw.githubusercontent.com/bryanwieg/ai-coding-sandbox/main/install.sh | sh
```

It downloads the shell functions (no clone needed), creates the shared state
volumes, and sources the functions once from that shell's startup file
(`~/.zshrc` or `~/.bashrc`). Open a new terminal, or run the `.` command it
prints, to load them. Rerunning it updates.

Then, from a project's root folder:

```sh
sandbox-init       # once: create .sandbox/ (settings, egress policy, SSH);
                   # in a Git repo, sandbox does this and stages it for you
sandbox            # approve egress, unlock SSH if enabled, start Claude Code
sandbox codex      # or Codex
sandbox-trust      # review and approve egress; applies to running sessions at once
sandbox-unlock     # manually unlock or reload SSH keys, when needed
sandbox-prune      # remove superseded sandbox images; runs after each session
```

`sandbox` prepares approval and SSH through Compose, then runs
`docker compose --env-file .sandbox/env run --rm claude`. The functions are
optional; direct Compose launches require manual approval and unlocking.
Each agent signs itself and GitHub in on first use.
Sign-ins, sessions, memory and plugins are shared by all projects; each
project has its own proxy and Docker daemon, which stop once no session uses
them.

## Documentation

[`sandbox/README.md`](sandbox/README.md) covers project settings, the egress
policy, Docker and published ports, SSH, authentication, plugins, migrating
from the retired `run-sandbox` launcher, troubleshooting, releases, and
developing the sandbox. Agents in a session get the sandbox's guide and rules
from the image: [`sandbox/image/session-guide.md`](sandbox/image/session-guide.md)
and [`sandbox/image/session-rules.md`](sandbox/image/session-rules.md).

## Verify changes

```sh
sandbox/bin/check-sandbox      # structural checks, before every commit
sandbox/bin/audit-sandbox      # runtime audit, after boundary changes
```
