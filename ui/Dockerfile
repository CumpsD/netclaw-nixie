# syntax=docker/dockerfile:1.7
#
# Builds the UNOFFICIAL netclaw management UI (codymullins/netclaw-ui): a
# Blazor Server app that talks to the daemon control plane on 127.0.0.1:5199
# and reads/writes config files under the shared /home/netclaw/.netclaw mount.
#
# Upstream ships no Dockerfile or image, so this clones a pinned revision
# (UI_REVISION, supplied from nixie.yml like every other version) and
# publishes ONLY src/Netclaw.Web — the Aspire AppHost and test projects are
# dev-time conveniences, deliberately not built.
#
# uid matters: the UI must read netclaw.json/secrets.json and write
# config/tool-approvals.json in a tree that config-init and the netclaw
# entrypoint chown to uid/gid 1654. The aspnet base image's non-root `app`
# user is uid/gid 1654 (APP_UID) — the same value netclaw uses. Asserted at
# build time below rather than assumed.

ARG DOTNET_SDK_TAG=10.0.203
ARG DOTNET_ASPNET_TAG=10.0.10

# ---- build stage -----------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build

# Full commit SHA to build. The defaults only keep a bare `docker build`
# working; the values that matter live in nixie.yml's build.args. The netclaw
# submodule revision is pinned by the UI commit itself (gitlink), not by us.
ARG UI_REPO=https://github.com/codymullins/netclaw-ui.git
ARG UI_REVISION=edc8cddc219800c6fbc709454d0f47df200a2c2f

# Refit 10.1.6's author-signing certificate was revoked after publication, and
# the SDK's default package-signature verification turns that into a fatal
# NU3012 during restore. The package itself is unchanged (same content hash the
# ecosystem has always had) — a revoked author cert months after publish is a
# CA lifecycle event, not evidence of tampering — so verification is disabled
# for this build rather than abandoning the pin. Remove when the UI moves to a
# Refit release signed with a valid certificate.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_NUGET_SIGNATURE_VERIFICATION=false

WORKDIR /src
RUN set -eux; \
    git clone "$UI_REPO" .; \
    git checkout --detach "$UI_REVISION"; \
    # .gitmodules records the submodule over SSH (git@github.com:...); a build
    # container has no SSH identity, so rewrite to anonymous https first.
    git config --global url."https://github.com/".insteadOf "git@github.com:"; \
    git submodule update --init --recursive

# The pinned SDK tag satisfies the repo's global.json (10.0.203, rollForward
# major) exactly. Framework-dependent publish; the aspnet stage supplies the
# runtime.
#
# TreatWarningsAsErrors is the UI repo's CI gate, not ours: we build a pinned
# third-party revision as consumers, and time-based warnings (NuGetAudit
# advisories published after the pin, new analyzer rules in a newer SDK) must
# not brick a previously-good build. Overridden to false so those surface as
# warnings in the build log instead. Concretely today: the fork's
# Netclaw.Configuration pins System.Security.Cryptography.Xml 10.0.8, which
# has known advisories (NU1903) — fixed by bumping UI_REVISION once upstream
# moves, not by anything in this file.
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish src/Netclaw.Web -c Release -o /app \
      -p:TreatWarningsAsErrors=false

# ---- runtime stage ---------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_ASPNET_TAG}

# curl exists solely for the compose healthcheck — aspnet images ship neither
# curl nor wget.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

# Fail the BUILD, not the deployment, if the base image's `app` user ever
# stops being 1654:1654 — a mismatch would only surface at runtime as
# unreadable netclaw.json / unwritable tool-approvals.json.
RUN [ "$(id -u app)" = "1654" ] && [ "$(id -g app)" = "1654" ] \
 || { echo "ERROR: aspnet 'app' user is no longer uid/gid 1654"; exit 1; }

COPY --from=build /app /app

# HOME must be writable: the UI persists ~/.netclaw-ui/daemon-override.json
# and ASP.NET DataProtection keys under it. /home/app is owned by `app` in
# the base image. Deliberately ephemeral (container layer, no volume): the
# override file is outranked by NETCLAW_DAEMON_ENDPOINT anyway, and losing
# DataProtection keys on recreate only invalidates in-flight antiforgery
# tokens (a page reload).
ENV HOME=/home/app \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

USER app
WORKDIR /app
EXPOSE 5198

# AssemblyName in Netclaw.Web.csproj is netclaw-web.
ENTRYPOINT ["dotnet", "/app/netclaw-web.dll"]
