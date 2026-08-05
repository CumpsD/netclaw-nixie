# syntax=docker/dockerfile:1.7
#
# Builds the /tools payload that gets copied into the `tools` volume and
# mounted read-only at /tools inside the netclaw container.
#
# CRITICAL: everything installs under /tools — the *final runtime path*.
# Several installers bake absolute paths (the AWS CLI writes absolute symlinks,
# dotnet shims reference their own location), so building at a staging path and
# relocating afterwards would leave dangling links. The init container therefore
# mounts the volume at /out, never /tools, and copies /tools/. -> /out/.
#
# Base is ubuntu:24.04 to match the netclaw image exactly (Ubuntu 24.04.4,
# glibc 2.39), so every binary produced here is ABI-compatible over there.
FROM ubuntu:24.04 AS tier1a

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Versions are all supplied from nixie.yml's build.args; the defaults here just
# keep a bare `docker build` working.
ARG BRUNO_VERSION=4.0.0
ARG CSHARP_LS_VERSION=0.26.0
ARG DOTNET_EF_VERSION=10.0.10
ARG DOTNET_EXTRA_RUNTIMES=""
ARG DOTNET_EXTRA_SDKS=""
ARG DOTNET_OUTDATED_TOOL_VERSION=4.8.1
ARG DOTNET_SCRIPT_VERSION=2.0.1
ARG DOTNET_VERSION=10.0.302
ARG GH_VERSION=2.97.0
ARG GITHUB_MCP_VERSION=v1.8.0
ARG HELM_VERSION=v4.2.3
ARG HUGO_VERSION=0.164.0
ARG IMPECCABLE_VERSION=3.5.0
ARG KUBECTL_VERSION=v1.36.3
ARG NODE_VERSION=26.6.0
ARG PAKET_VERSION=10.3.1
ARG QMD_VERSION=2.5.3
ARG RIPGREP_VERSION=15.2.0
ARG SOPS_VERSION=v3.13.3
ARG TERRAFORM_VERSION=1.15.8
ARG YQ_VERSION=v4.53.3

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

# Build-time-only dependencies. None of these end up in /tools except via the
# tier-2 extraction step, which copies binaries and their libs explicitly.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget unzip xz-utils git rsync patchelf file jq

RUN mkdir -p /tools/bin /tools/rootfs/usr/bin /tools/rootfs/usr/lib

# ---------------------------------------------------------------------------
# Tier 1a — single static binaries. Every one of these was verified with `ldd`
# as either statically linked or dependent only on libs netclaw already ships.
# ---------------------------------------------------------------------------
RUN set -eux; \
    # kubectl
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /tools/bin/kubectl; \
    # sops
    curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" \
        -o /tools/bin/sops; \
    # yq (mikefarah, Go). Ubuntu's apt build reports "0.0.0"; this one is real.
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
        -o /tools/bin/yq; \
    chmod +x /tools/bin/kubectl /tools/bin/sops /tools/bin/yq; \
    # helm (tarball)
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz; \
    tar -xzf /tmp/helm.tgz -C /tmp; \
    install -m 0755 /tmp/linux-amd64/helm /tools/bin/helm; \
    # terraform (zip)
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/tf.zip; \
    unzip -q -o /tmp/tf.zip -d /tmp/tf; \
    install -m 0755 /tmp/tf/terraform /tools/bin/terraform; \
    # gh — pinned deliberately: netclaw's apt gh is 2.45.0 and /tools/bin
    # precedes /usr/bin on its PATH, so this one wins.
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        -o /tmp/gh.tgz; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /tools/bin/gh; \
    # ripgrep (musl static)
    curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/rg.tgz; \
    tar -xzf /tmp/rg.tgz -C /tmp; \
    install -m 0755 "/tmp/ripgrep-${RIPGREP_VERSION}-x86_64-unknown-linux-musl/rg" /tools/bin/rg; \
    # hugo extended — .deb, but we only want the binary out of it
    curl -fsSL "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb" \
        -o /tmp/hugo.deb; \
    dpkg-deb -x /tmp/hugo.deb /tmp/hugo; \
    install -m 0755 /tmp/hugo/usr/local/bin/hugo /tools/bin/hugo; \
    rm -rf /tmp/helm.tgz /tmp/linux-amd64 /tmp/tf.zip /tmp/tf /tmp/gh.tgz \
           /tmp/gh_* /tmp/rg.tgz /tmp/ripgrep-* /tmp/hugo.deb /tmp/hugo; \
    /tools/bin/kubectl version --client=true >/dev/null; \
    /tools/bin/helm version --short; \
    /tools/bin/terraform version | head -1; \
    /tools/bin/gh --version | head -1; \
    /tools/bin/rg --version | head -1; \
    /tools/bin/yq --version; \
    /tools/bin/sops --version | head -1; \
    /tools/bin/hugo version | head -c 40; echo

# ---------------------------------------------------------------------------
# github-mcp-server — built from source with CGO disabled, giving a static
# binary. Cheaper and more reproducible than chasing release assets.
# ---------------------------------------------------------------------------
FROM docker.io/library/golang:1.26-alpine AS gh-mcp-builder
ARG GITHUB_MCP_VERSION
ENV CGO_ENABLED=0
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    GOBIN=/out go install \
        github.com/github/github-mcp-server/cmd/github-mcp-server@${GITHUB_MCP_VERSION}

FROM ubuntu:24.04 AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=tier1a /tools /tools
COPY --from=gh-mcp-builder /out/github-mcp-server /tools/bin/github-mcp-server

ARG BRUNO_VERSION
ARG CSHARP_LS_VERSION
ARG DOTNET_EF_VERSION
ARG DOTNET_EXTRA_RUNTIMES
ARG DOTNET_EXTRA_SDKS
ARG DOTNET_OUTDATED_TOOL_VERSION
ARG DOTNET_SCRIPT_VERSION
ARG DOTNET_VERSION
ARG GH_VERSION
ARG GITHUB_MCP_VERSION
ARG HELM_VERSION
ARG HUGO_VERSION
ARG IMPECCABLE_VERSION
ARG KUBECTL_VERSION
ARG NODE_VERSION
ARG PAKET_VERSION
ARG QMD_VERSION
ARG RIPGREP_VERSION
ARG SOPS_VERSION
ARG TERRAFORM_VERSION
ARG YQ_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_ROOT=/tools/dotnet \
    PATH=/tools/bin:/tools/dotnet:/tools/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget unzip xz-utils git rsync patchelf file jq \
        # Runtime deps needed *by this builder* so the verification steps below
        # can actually execute the tools they just installed:
        #   libicu74   .NET segfaults without ICU (SIGSEGV, exit 139)
        #   libatomic1 node fails to load without it (exit 127)
        # netclaw already ships libicu74; libatomic1 it does NOT, which is why
        # provision-tier2.sh also vendors that one into /tools/rootfs/usr/lib.
        libicu74 libssl3 zlib1g libstdc++6 libatomic1

# ---------------------------------------------------------------------------
# Tier 1b — .NET SDK. dotnet-install.sh is relocation-friendly as long as
# DOTNET_ROOT points at the install dir, which nixie.yml sets on the netclaw
# service.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh; \
    chmod +x /tmp/dotnet-install.sh; \
    /tmp/dotnet-install.sh --version "${DOTNET_VERSION}" --install-dir /tools/dotnet --no-path; \
    for v in ${DOTNET_EXTRA_SDKS}; do \
        /tmp/dotnet-install.sh --version "$v" --install-dir /tools/dotnet --no-path; \
    done; \
    for c in ${DOTNET_EXTRA_RUNTIMES}; do \
        /tmp/dotnet-install.sh --channel "$c" --runtime dotnet     --install-dir /tools/dotnet --no-path; \
        /tmp/dotnet-install.sh --channel "$c" --runtime aspnetcore --install-dir /tools/dotnet --no-path; \
    done; \
    rm -f /tmp/dotnet-install.sh; \
    ln -sf ../dotnet/dotnet /tools/bin/dotnet; \
    /tools/dotnet/dotnet --version

# .NET global tools via --tool-path, the explicitly relocatable install mode.
# The generated shims reference their payload with paths relative to the shim
# itself (.store/<tool>/<ver>/...), which is what makes /tools portable.
RUN set -eux; \
    dotnet tool install --tool-path /tools/dotnet-tools paket               --version "${PAKET_VERSION}"; \
    dotnet tool install --tool-path /tools/dotnet-tools dotnet-ef           --version "${DOTNET_EF_VERSION}"; \
    dotnet tool install --tool-path /tools/dotnet-tools dotnet-outdated-tool --version "${DOTNET_OUTDATED_TOOL_VERSION}"; \
    dotnet tool install --tool-path /tools/dotnet-tools dotnet-script       --version "${DOTNET_SCRIPT_VERSION}"; \
    dotnet tool install --tool-path /tools/dotnet-tools csharp-ls           --version "${CSHARP_LS_VERSION}"; \
    for t in paket dotnet-ef dotnet-outdated dotnet-script csharp-ls; do \
        [ -f "/tools/dotnet-tools/$t" ] && ln -sf "../dotnet-tools/$t" "/tools/bin/$t"; \
    done; \
    ls -1 /tools/dotnet-tools

# Verify each tool actually RUNS under the roll-forward policy nixie.yml sets.
# This is the guard on a real decision: paket targets net9.0 and dotnet-ef
# net8.0 even at their latest versions, so with the SDK's default LatestPatch
# they die with "You must install or update .NET". Major lets them run on the
# 10.0 runtime, which is why we do not vendor the 8.0/9.0 runtimes. If a future
# tool bump breaks that assumption, the build fails here instead of the agent
# discovering it at runtime.
RUN set -eux; \
    export DOTNET_ROLL_FORWARD=Major; \
    fail=0; \
    for t in paket dotnet-ef dotnet-outdated dotnet-script csharp-ls; do \
        if out="$("/tools/bin/$t" --version 2>&1 | head -1)" \
           && ! printf '%s' "$out" | grep -q "You must install or update"; then \
            printf '  ok   %-16s %s\n' "$t" "$out"; \
        else \
            printf '  FAIL %-16s %s\n' "$t" "$out"; fail=1; \
        fi; \
    done; \
    [ "$fail" = 0 ] || { echo "A dotnet tool cannot run under DOTNET_ROLL_FORWARD=Major."; \
        echo "Either pin an older tool version or set DOTNET_EXTRA_RUNTIMES in nixie.yml."; exit 1; }

# ---------------------------------------------------------------------------
# Tier 1c — Node from the official tarball (fully self-contained and designed
# to be relocatable), plus the npm globals. npm resolves global modules from
# realpath(execPath)/../.., so /tools/node/{bin,lib/node_modules} works and the
# /tools/bin symlinks resolve correctly.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        -o /tmp/node.tar.xz; \
    mkdir -p /tools/node; \
    tar -xJf /tmp/node.tar.xz -C /tools/node --strip-components=1; \
    rm -f /tmp/node.tar.xz; \
    /tools/node/bin/npm install -g --prefix /tools/node \
        "@tobilu/qmd@${QMD_VERSION}" \
        "impeccable@${IMPECCABLE_VERSION}" \
        "@usebruno/cli@${BRUNO_VERSION}"; \
    for b in node npm npx qmd impeccable bru; do \
        [ -e "/tools/node/bin/$b" ] && ln -sf "../node/bin/$b" "/tools/bin/$b"; \
    done; \
    /tools/node/bin/node --version

# ---------------------------------------------------------------------------
# Tier 1d — installers that write into $HOME. We point HOME at /tools so the
# payload lands at its final path, then lift the binaries into /tools/bin.
#   uv  — Astral's Python tooling
#   rtk — token-saving CLI proxy
# ---------------------------------------------------------------------------
RUN set -eux; \
    export HOME=/tools/home; mkdir -p "$HOME"; \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/tools/bin sh; \
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; \
    for b in rtk uv uvx; do \
        [ -f "$HOME/.local/bin/$b" ] && install -m 0755 "$HOME/.local/bin/$b" "/tools/bin/$b" || true; \
    done; \
    rm -rf /tools/home; \
    /tools/bin/uv --version; \
    /tools/bin/rtk --version || echo "WARN: rtk did not report a version"

# ---------------------------------------------------------------------------
# AWS CLI v2.
#
# The host is `awscli.amazonaws.com` — note it is NOT `awscliv2.amazonaws.com`,
# which is only the name of the downloaded *file*. That hostname is NXDOMAIN on
# public resolvers, so getting it wrong fails at DNS with a misleading
# "unreachable network" look. See:
#   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
#
# Installed to its final runtime path (-i /tools/aws-cli) because the installer
# writes absolute symlinks; installing elsewhere and moving would dangle them.
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL --max-time 120 https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
        -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install -i /tools/aws-cli -b /tools/bin; \
    rm -rf /tmp/awscliv2.zip /tmp/aws; \
    /tools/bin/aws --version

# ---------------------------------------------------------------------------
# Tier 2 — apt-sourced binaries that cannot simply be copied, because they need
# shared libraries netclaw does not ship. provision-tier2.sh copies each binary
# plus its ldd closure (minus core glibc) into /tools/rootfs and rewrites the
# RUNPATH so they find their libs without a global LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
COPY provision-tier2.sh /usr/local/bin/provision-tier2.sh
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    chmod +x /usr/local/bin/provision-tier2.sh && /usr/local/bin/provision-tier2.sh

# ---------------------------------------------------------------------------
# Build stamp. The init container compares this against the copy already in the
# volume; a difference forces a re-provision.
#
# It hashes BOTH the version args AND the build recipe itself. Versions alone
# are not enough: fixing a bug in this Dockerfile (a wrong download URL, say)
# changes no argument, so the stamp would be unchanged, tools-init would report
# "up to date", and the fix would never reach the volume. That failure is
# silent and looks exactly like success — the same trap a hand-bumped revision
# counter has, just one level up.
#
# The recipe is copied into the image (not just hashed) so the provisioned
# volume carries a record of exactly what produced it.
# ---------------------------------------------------------------------------
COPY Dockerfile provision-tier2.sh entrypoint.sh /tools/.recipe/
RUN { printf '%s\n' \
        "${BRUNO_VERSION} ${CSHARP_LS_VERSION} ${DOTNET_EF_VERSION}" \
        "${DOTNET_EXTRA_RUNTIMES} ${DOTNET_EXTRA_SDKS}" \
        "${DOTNET_OUTDATED_TOOL_VERSION} ${DOTNET_SCRIPT_VERSION} ${DOTNET_VERSION}" \
        "${GH_VERSION} ${GITHUB_MCP_VERSION} ${HELM_VERSION} ${HUGO_VERSION}" \
        "${IMPECCABLE_VERSION} ${KUBECTL_VERSION} ${NODE_VERSION} ${PAKET_VERSION}" \
        "${QMD_VERSION} ${RIPGREP_VERSION} ${SOPS_VERSION} ${TERRAFORM_VERSION} ${YQ_VERSION}"; \
      cat /tools/.recipe/Dockerfile /tools/.recipe/provision-tier2.sh /tools/.recipe/entrypoint.sh; \
    } | sha256sum | cut -c1-16 > /tools/.stamp \
 && echo "tools stamp: $(cat /tools/.stamp)"

COPY entrypoint.sh /usr/local/bin/tools-init-entrypoint
RUN chmod +x /usr/local/bin/tools-init-entrypoint

ENTRYPOINT ["/usr/local/bin/tools-init-entrypoint"]
