FROM node:26-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1 AS node-runtime

# Microsoft now ships PowerShell in its SDK image. Dependabot tracks this
# source; only PowerShell and its .NET runtime reach the agent images.
FROM mcr.microsoft.com/dotnet/sdk:10.0.404-noble-amd64@sha256:a82c44c2efe00953d66a37e90d307c4cfbd1e974b16e3b2a2fc665331946c9af AS powershell-upstream

# Dependabot tracks this source by its full version tag and digest; only the
# Go distribution under /usr/local/go reaches the agent images.
FROM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS go-upstream

FROM python:3.15-slim-bookworm@sha256:96599df822d0e1c6bb700014a05c7f3c8cabc6e0f7ff3c4f9f69cee033b4b5d9 AS python-runtime

# Keep independently updated dependencies out of each other's build cache.
COPY requirements.txt /opt/python-tools/requirements.txt
RUN python3 -m pip install --no-cache-dir -r /opt/python-tools/requirements.txt \
    && python_minor=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")') \
    && ln -sf /usr/local/bin/pycodestyle "/usr/local/bin/pycodestyle-${python_minor}"

FROM node-runtime AS node-tools
COPY package.json /opt/node-tools/package.json
RUN cd /opt/node-tools \
    && npm install --omit=dev \
    && npm cache clean --force

# Each CLI installs in its own stage and layer from its own pinned manifest,
# so an update to one reuses the other's install.
FROM node-runtime AS claude-cli
COPY claude/package.json /opt/claude/package.json
ARG CLAUDE_VERSION=
RUN cd /opt/claude \
    && if [ -n "$CLAUDE_VERSION" ]; then \
        npm install --omit=dev "@anthropic-ai/claude-code@${CLAUDE_VERSION}"; \
    else \
        npm install --omit=dev; \
    fi \
    && npm cache clean --force

FROM node-runtime AS codex-cli
COPY codex/package.json /opt/codex/package.json
ARG CODEX_VERSION=
RUN cd /opt/codex \
    && if [ -n "$CODEX_VERSION" ]; then \
        npm install --omit=dev "@openai/codex@${CODEX_VERSION}"; \
    else \
        npm install --omit=dev; \
    fi \
    && npm cache clean --force

# Supplies the Docker CLI and its compose and buildx plugins to the agent
# images, and the rootless daemon of sessions that allow Docker.
FROM docker:29.9.3-dind-rootless@sha256:707a099b8ddd86306eb28c8b1775264a3ee0135b16dc505b7b48ffb328edf8d0 AS docker-upstream

# Rootless session daemon. Any runtime UID from 500 to 65533 gets a fixed,
# root-owned identity whose group equals the UID, so no per-user build and no
# root step at start are needed. Every identity is named "sandbox", so one
# subordinate-ID line, matched by name, maps the same range for all of them.
FROM docker-upstream AS session-daemon

USER root
RUN set -eu; \
    awk -F: '$3 < 500 || $3 > 65533' /etc/passwd > /tmp/passwd; \
    awk -F: '$3 < 500 || $3 > 65533' /etc/group > /tmp/group; \
    awk 'BEGIN { for (id = 500; id <= 65533; id++) printf "sandbox:x:%d:%d::/home/rootless:/bin/sh\n", id, id }' >> /tmp/passwd; \
    awk 'BEGIN { for (id = 500; id <= 65533; id++) printf "sandbox:x:%d:\n", id }' >> /tmp/group; \
    echo 'sandbox:100000:65536' > /etc/subuid; \
    cp /etc/subuid /etc/subgid; \
    mv /tmp/passwd /etc/passwd; \
    mv /tmp/group /etc/group; \
    chmod 0644 /etc/passwd /etc/group /etc/subuid /etc/subgid; \
    chown -R root:root /home/rootless; \
    chmod 1777 /home/rootless /home/rootless/.local /home/rootless/.local/share \
        /home/rootless/.local/share/docker
# The daemon chmods its data root, so it creates that root itself inside the
# world-writable, sticky data volume.
ENV XDG_DATA_HOME=/home/rootless/.local/share/docker
COPY --chmod=0755 image/sandbox-dockerd /usr/local/bin/sandbox-dockerd
ENTRYPOINT ["/usr/local/bin/sandbox-dockerd"]
USER 1000

# Published port forwarder. It only relays the ports in SANDBOX_PUBLISH_PORTS
# from the host to the session daemon, and exits with the daemon.
FROM alpine/socat:1.8.1.3@sha256:71131702f671a88b3808a70b7330f9679cd9b9933adcafadc191508edfe55bba AS session-forwarder
USER 65534:65534
COPY --chmod=0755 image/sandbox-forward /usr/local/bin/sandbox-forward
ENTRYPOINT ["/usr/local/bin/sandbox-forward"]

# Offline project initializer, independent of both agent images.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS session-init
COPY --chmod=0755 image/sandbox-init-config /usr/local/bin/sandbox-init-config
USER 65534:65534
CMD ["/usr/local/bin/sandbox-init-config"]

# SSH agent sidecar. Only it and its unlock command mount the key folder;
# agents get just the socket. The socket directory is sticky and
# world-writable so that the runtime UID, unknown at build time, can create
# the socket in a fresh volume; the socket is 0600.
# ssh-keygen needs a user entry, so runtime UIDs 500 to 65533 get fixed ones.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS session-ssh-agent
RUN apk add --no-cache openssh-client \
    && install -d -m 1777 /run/ssh-agent \
    && awk -F: '$3 < 500 || $3 > 65533' /etc/passwd > /tmp/passwd \
    && awk 'BEGIN { for (id = 500; id <= 65533; id++) printf "sandbox:x:%d:%d::/tmp:/sbin/nologin\n", id, id }' >> /tmp/passwd \
    && mv /tmp/passwd /etc/passwd \
    && chmod 0644 /etc/passwd
COPY --chmod=0755 image/sandbox-ssh-agent image/sandbox-ssh-unlock /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/sandbox-ssh-agent"]
USER 65534:65534

# Egress proxy, with its configuration built in. It allows the base policy and
# adds a project's policy only once approved; the same image runs the trust
# command.
FROM ubuntu/squid:6.6-24.04_beta@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029 AS session-proxy
COPY --chmod=0644 squid/squid.conf /etc/squid/squid.conf.template
COPY --chmod=0644 squid/base-policy.yaml /etc/squid/base-policy.yaml
COPY --chmod=0755 image/sandbox-policy image/sandbox-proxy image/sandbox-proxy-config \
    image/sandbox-trust /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/sandbox-proxy"]
USER 13:13

# Shared, agent-independent tooling. Each agent target below adds only its own
# CLI, initialization, and runtime user, so the base layers are built once.
FROM node-runtime AS base

ARG GH_CLI_KEYRING_SHA256=6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl --fail --silent --show-error --location \
        --output /tmp/githubcli-archive-keyring.gpg \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && echo "${GH_CLI_KEYRING_SHA256}  /tmp/githubcli-archive-keyring.gpg" | sha256sum --check - \
    && install -Dm 0644 /tmp/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && rm -f /tmp/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bmake \
        composer \
        gcc \
        git \
        git-lfs \
        gh \
        jq \
        libc6-dev \
        libnss-wrapper \
        libxml2-utils \
        netcat-openbsd \
        openssh-client \
        php-cli \
        php-codesniffer \
        php-curl \
        php-intl \
        php-ldap \
        php-mbstring \
        php-sqlite3 \
        php-xml \
        php-zip \
        phpunit \
        procps \
        shellcheck \
        tini \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/php /usr/local/bin/php \
    && ln -sf /usr/bin/phpcs /usr/local/bin/phpcs

RUN ln -s "$(find /usr/lib -name libnss_wrapper.so -print -quit)" /usr/local/lib/libnss_wrapper.so

COPY --from=python-runtime /usr/local /usr/local
COPY --from=docker-upstream /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-upstream /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
COPY --from=powershell-upstream /usr/share/powershell /usr/share/powershell
COPY --from=powershell-upstream /usr/share/dotnet/dotnet /usr/share/dotnet/dotnet
COPY --from=powershell-upstream /usr/share/dotnet/host /usr/share/dotnet/host
COPY --from=powershell-upstream /usr/share/dotnet/shared/Microsoft.NETCore.App /usr/share/dotnet/shared/Microsoft.NETCore.App
COPY --from=powershell-upstream /usr/share/dotnet/LICENSE.txt /usr/share/dotnet/ThirdPartyNotices.txt /usr/share/dotnet/
COPY --from=node-tools /opt/node-tools /opt/node-tools

COPY --chmod=0755 image/sandbox-pwsh /usr/local/libexec/sandbox/pwsh
RUN ln -s /usr/local/libexec/sandbox/pwsh /usr/local/bin/pwsh
ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off

# Start contract: the entrypoint supplies the runtime identity for every
# command; the default command runs /usr/local/libexec/sandbox/init.d/*, then
# the launched agent's own init.d/* and its launcher, both under
# /usr/local/libexec/sandbox/<agent>/. SANDBOX_AGENT (claude or codex), set by
# each Compose service, names the launched agent. sandbox-auth gives both
# agents the same status|login|logout interface over their own auth scripts.
COPY image/sandbox-entrypoint image/sandbox-start image/sandbox-auth \
    image/sandbox-agent-version image/sandbox-initialize-state \
    image/sandbox-check-context7 image/sandbox-policy image/sandbox-docker-lease \
    image/sandbox-init-config image/sandbox-migrate-state image/sandbox-proxy-lease \
    image/sandbox-ssh-hostkey /usr/local/bin/
COPY ssh/90-ssh-proxy.conf /etc/ssh/ssh_config.d/90-ssh-proxy.conf
COPY image/gitconfig /etc/gitconfig
RUN chmod 0755 /usr/local/bin/sandbox-entrypoint /usr/local/bin/sandbox-start /usr/local/bin/sandbox-auth \
        /usr/local/bin/sandbox-agent-version /usr/local/bin/sandbox-initialize-state \
        /usr/local/bin/sandbox-check-context7 /usr/local/bin/sandbox-policy \
        /usr/local/bin/sandbox-docker-lease /usr/local/bin/sandbox-init-config \
        /usr/local/bin/sandbox-migrate-state /usr/local/bin/sandbox-proxy-lease \
        /usr/local/bin/sandbox-ssh-hostkey \
    && chmod 0644 /etc/ssh/ssh_config.d/90-ssh-proxy.conf /etc/gitconfig \
    && mkdir -p /usr/local/libexec/sandbox/init.d /usr/local/share/sandbox
COPY --chmod=0755 image/init.d/ /usr/local/libexec/sandbox/init.d/
COPY --chmod=0755 image/exit.d/ /usr/local/libexec/sandbox/exit.d/
# The guide and rules every session's agent loads, combined into the one file
# the launchers pass; the base egress policy is there for reference.
COPY --chmod=0644 image/session-guide.md image/session-rules.md squid/base-policy.yaml \
    /usr/local/share/sandbox/
RUN cd /usr/local/share/sandbox \
    && { cat session-guide.md; echo; cat session-rules.md; } > session-instructions.md \
    && chmod 0644 session-instructions.md

# Go in its own layer as well. The home is read-only and /tmp is noexec, so
# GOPATH, GOCACHE and GOTMPDIR (where go test and go run execute builds) live
# in the project's cache volume at /cache. The wrapper creates GOTMPDIR. GOTOOLCHAIN=local keeps go from
# fetching other toolchains.
COPY --from=go-upstream /usr/local/go /usr/local/go
COPY --chmod=0755 image/sandbox-go /usr/local/libexec/sandbox/go
RUN ln -s /usr/local/libexec/sandbox/go /usr/local/bin/go \
    && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt
ENV GOPATH=/cache/go \
    GOCACHE=/cache/go/build-cache \
    GOTMPDIR=/cache/go/tmp \
    GOTOOLCHAIN=local

# Installed Go binaries come last on PATH, so they never shadow image tools.
# The home is read-only, so interactive bash keeps its history in /tmp.
ENV PATH="/opt/node-tools/node_modules/.bin:${PATH}:/cache/go/bin" \
    SHELL=/bin/bash \
    HISTFILE=/tmp/.bash_history
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["/usr/local/bin/sandbox-start"]

# Agent image: ghcr.io/<repository>:agent-latest. Both CLIs, so either agent
# can hand work to the other; the claude and codex services differ only in
# SANDBOX_AGENT and their GitHub login folder.
FROM base AS agent

COPY --from=claude-cli /opt/claude /opt/claude
COPY --from=codex-cli /opt/codex /opt/codex

# The image is immutable; updates arrive through a rebuilt image, never in place.
# Telemetry, error reports, and claude.ai MCP connectors are off so that Claude
# Code needs only the API and sign-in hosts on the egress allowlist. Both state
# volumes are mounted at these paths in every session.
# Codex's own bubblewrap sandbox cannot start under Docker's default seccomp
# profile, so a Codex that another agent runs as a builder (phased-delivery's
# codex-build.sh) uses the container as its boundary too.
LABEL sandbox.agents="claude codex"
ENV PATH="/opt/claude/node_modules/.bin:/opt/codex/node_modules/.bin:${PATH}" \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    ENABLE_CLAUDEAI_MCP_SERVERS=false \
    CLAUDE_CONFIG_DIR=/home/agent/.claude \
    CODEX_HOME=/home/agent/.codex \
    CODEX_BUILD_SANDBOX=danger-full-access

COPY --chmod=0755 claude/agent claude/auth /usr/local/libexec/sandbox/claude/
COPY --chmod=0755 claude/init.d/ /usr/local/libexec/sandbox/claude/init.d/
COPY --chmod=0755 codex/agent codex/auth /usr/local/libexec/sandbox/codex/
COPY --chmod=0755 codex/init.d/ /usr/local/libexec/sandbox/codex/init.d/
COPY claude/plugins.txt /usr/local/share/claude/plugins.txt
COPY codex/plugins.txt /usr/local/share/codex/plugins.txt

# The home is read-only; VS Code Dev Containers attach installs its server
# through these links into the project's cache volume (init.d/06-vscode).
# Commands run with docker exec, as attach does, skip the entrypoint's NSS
# records, so every unused UID and GID from 500 to 65533 is named agent with
# its home: attach finds the links, and OpenSSH finds ~/.ssh.
# These are name lookups only; sessions replace them with the entrypoint's.
# /home/claude and /home/codex, the homes of the former per-agent images,
# point here, so absolute paths saved in existing state volumes (such as
# installed plugins) still resolve.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
RUN groupmod --gid "${AGENT_GID}" --new-name agent node \
    && usermod --uid "${AGENT_UID}" --login agent --home /home/agent --shell /bin/bash --move-home node \
    && ln -s /cache/vscode/server /home/agent/.vscode-server \
    && ln -s /cache/vscode/remote-containers /home/agent/.vscode-remote-containers \
    && ln -s /home/agent /home/claude \
    && ln -s /home/agent /home/codex \
    && awk -F: '{ used[$3] = 1 } END { for (id = 500; id <= 65533; id++) if (!(id in used)) printf "agent:x:%d:%d::/home/agent:/bin/bash\n", id, id }' \
        /etc/passwd >> /etc/passwd \
    && awk -F: '{ used[$3] = 1 } END { for (id = 500; id <= 65533; id++) if (!(id in used)) printf "agent:x:%d:\n", id }' \
        /etc/group >> /etc/group \
    && install -d -m 0755 /etc/codex

# Codex's system defaults, below the user's own configuration: plain
# `codex exec` runs with danger-full-access too (codex/config.toml). The
# folder is created above, since COPY --chmod would also apply to it.
COPY --chmod=0644 codex/config.toml /etc/codex/config.toml

ENV HOME=/home/agent
USER agent

# Every caller names its target. Kept as the final stage so that an
# untargeted build fails instead of silently producing an agent image.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS no-target
RUN echo 'Name an image with --target, such as agent.' >&2; exit 1
