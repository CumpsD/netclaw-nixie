# Nixie

```
   _   _ _      _
  | \ | (_)_  _(_) ___
  |  \| | \ \/ / |/ _ \
  | |\  | |>  <| |  __/
  |_| \_|_/_/\_\_|\___|
```

A template [netclaw](https://netclaw.dev) deployment for an AI agent called
**Nixie**, packaged as a Docker Compose stack.

The upstream netclaw image is deliberately minimal, no `dotnet`, `node`, `rg`,
`unzip`, `ssh`, `psql` or `aws`. This repo provisions a full development
toolchain into it, wires up MCP servers, git identity and commit signing, and
gets you from `git clone` to a working agent with one command.

**Fork it, clone your fork, run `./setup.sh`.** From then on your fork *is* your
configuration: change a version, an approved command, or a workspace repo,
commit it, and the next `docker compose up -d` applies it.

---

## Quick start

```sh
# 1. Fork this repo on GitHub, then clone your fork
git clone git@github.com:<you>/netclaw-nixie.git
cd netclaw-nixie

# 2. Configure
cp .env.example .env
$EDITOR .env          # at minimum: GH_TOKEN, GIT_USER_NAME, GIT_USER_EMAIL

# 3. Bring it up
./setup.sh
```

`setup.sh` is idempotent, re-run it any time as a status check.

First run downloads roughly 3 GB of toolchain and takes several minutes.

### Then

```sh
docker compose exec -it netclaw netclaw chat        # talk to the agent
docker compose exec -T  netclaw netclaw doctor      # diagnostics
docker compose logs -f netclaw                      # follow the daemon
```

---

## Requirements

- Docker with Compose v2
- ~5.5 GB free disk (3 GB tools volume, ~1 GB Chromium image, ~0.3 GB SearXNG)
- A GitHub personal access token

Nothing else, `setup.sh` runs `ssh-keygen` and `openssl` inside containers, so
they are not host prerequisites.

---

## What `setup.sh` does

1. **Preflight**, checks Docker, validates `.env`, creates the bind-mount
   directories, generates a `BROWSERLESS_TOKEN`, a `SEARXNG_SECRET` and an
   ed25519 signing key if they do not exist yet.
2. **Build**, builds the tools image.
3. **Up**, starts the stack.
4. **Health**, waits for netclaw to report healthy.
5. **`netclaw init`**, runs netclaw's first-run wizard.
6. **Seed**, registers the MCP servers, approvals and identity.

Step 5 is not optional. Until it runs, netclaw has no model *and* falls back to
a Public security posture with `shell_execute` disabled, which makes every tool
below unreachable. `setup.sh` deliberately does not configure the provider,
model or posture itself; those are operator decisions and `netclaw init` owns
them.

If a signing key was generated, `setup.sh` prints the public key. Register it on
GitHub **twice**, once as an Authentication key and once as a Signing key; they
are separate entries, and adding only the first leaves commits unverified.

---

## What the agent gets

### Tools

Provisioned into a read-only volume at `/tools`, already on netclaw's `PATH`.

| Category | Tools |
|---|---|
| Languages | `dotnet` (SDK 10 + `paket`, `dotnet-ef`, `dotnet-outdated`, `dotnet-script`, `csharp-ls`), `node`/`npm`/`npx`, `uv` |
| Cloud & infra | `kubectl`, `helm`, `terraform`, `aws`, `sops` |
| Git & GitHub | `gh`, `git-lfs`, `ssh` |
| Search & files | `rg`, `yq`, `file`, `less`, `xxd`, `unzip`, `rsync` |
| Network | `dig`, `ss`, `nc`, `tcpdump`, `psql`, `redis-cli` |
| Agent tooling | `qmd`, `impeccable`, `bru`, `rtk`, `github-mcp-server`, `hugo` |

The base image already supplies `bash`, `git`, `curl`, `jq`, `python3` and
`sqlite3`. `gh` is provisioned anyway and deliberately shadows the image's older
apt build, since `/tools/bin` comes first on `PATH`.

Every version is pinned in `nixie.yml` under `tools-init.build.args`, that file
is the single place to bump one.

### Sidecars

- **Redis** at `redis:6379` (`$REDIS_URL`)
- **Headless Chromium** over CDP at `$BROWSER_WS_ENDPOINT`. There is no local
  browser binary; drive it with `puppeteer-core` via `connect()`, not `launch()`.
- **SearXNG** metasearch at `http://searxng:8080` (`$SEARXNG_URL`), JSON API
  enabled. Reached through the `searxng` MCP server, or plain
  `curl "http://searxng:8080/search?q=…&format=json"`. No search API key, and
  queries never leave the compose network.

### MCP servers

`github`, `qmd`, `searxng` and `atlassian` are registered automatically.
Atlassian needs a one-time interactive OAuth step:

```sh
docker compose exec -it netclaw netclaw mcp auth atlassian
```

Registration is part of the one-time seeding, so a fork seeded *before* the
SearXNG sidecar existed never gets its MCP server automatically. Register it
once by hand (do **not** delete `.nixie-seeded` for this — re-seeding would
also resurrect removed servers and revoked approvals):

```sh
docker compose exec netclaw netclaw mcp add --transport stdio searxng -- mcp-searxng
```

---

## Maintaining your fork

Two kinds of tracked file, with different lifecycles.

**Stack configuration**, read on every start, so editing one and running
`docker compose up -d` applies it:

| File | What it controls |
|---|---|
| `.env` | Secrets and identity. **Gitignored**, never committed |
| `nixie.yml` | Tool versions, image pins, sidecars, env wiring |
| `searxng/settings.yml` | SearXNG result formats and engines |
| `ssh/config`, `ssh/known_hosts` | SSH client config and pinned host keys |
| `ssh/*.pub` | Your deployment's public signing key, once generated |

**Your bot's own config**, seeded once on the first run, then yours:

| File | Seeded from |
|---|---|
| `netclaw/config/netclaw.json` | MCP servers and `AGENT_NAME` |
| `netclaw/config/tool-approvals.json` | `config-init/approvals-seed.json` |
| `netclaw/identity/AGENTS.md` | `config-init/agents-block.md` |
| `netclaw/identity/SOUL.md` | netclaw's default, renamed to `AGENT_NAME` |

Seeding waits for `netclaw init` and only happens once afterwards. Writing
`netclaw.json` any earlier makes the wizard report *"Existing Netclaw install
detected"* and offer a repair menu instead of the first-run flow, because simply
registering an MCP server creates that file. If you bring the stack up with a
bare `docker compose up -d` instead of `setup.sh`, run `netclaw init` and then
`docker compose up -d` once more to pick the seeding up.

If you choose an agent name during `netclaw init`, that name wins over
`AGENT_NAME` — a deliberate answer beats a default.

After that first run `config-init` never touches them again. Manage them with
the netclaw CLI (`netclaw mcp`, `netclaw model`, `netclaw config`) or by hand,
and commit the result, your fork becomes the record of your bot's setup.
Remove an MCP server, revoke an approval, rewrite the persona: nothing gets put
back. Delete `netclaw/.nixie-seeded` to deliberately re-seed.

The rest of `netclaw/`, database, logs, sessions, keys, caches, is ignored, as
is `identity/TOOLING.md`, which is a generated capability report rather than a
setting.

> **How this works.** `config-init` chowns `netclaw/` to uid 1654 so the daemon
> can write it, which would normally lock your account out and break `git` with
> `unable to unlink old ...: Permission denied`. `setup.sh` heads that off with a
> default POSIX ACL granting you `rwX`, applied before the first `up` and
> inherited by everything the daemon creates. It needs a filesystem with ACL
> support (ext4 and friends); `setup.sh` warns if it cannot set one.

### Pulling template updates

```sh
git remote add upstream git@github.com:CumpsD/netclaw-nixie.git
git fetch upstream && git merge upstream/main
```

Conflicts should be confined to `nixie.yml` and the `config-init/` files, the
same ones you customised.

---

## Layout

```
setup.sh                 one-shot bring-up and status check
nixie.yml                the compose stack
.env.example             every setting, documented
tools-init/              builds the /tools payload
config-init/             netclaw config, MCP, git identity, workspaces
searxng/                 SearXNG config (committed, mounted read-only)
ssh/                     ssh client config; your key lands here
netclaw/                 your bot's config (tracked) + runtime state (ignored)
cache/, nuget/           package caches (generated, gitignored)
```

---

## Notes

- **Nothing secret is committed.** No private keys, no tokens. `.env` and the
  private half of the signing key are gitignored; `setup.sh` generates both.
- **`known_hosts` is committed on purpose**, pinning GitHub's public host keys
  means a fresh deploy cannot be seeded with a MITM'd one.
- **Commits are signed** with the generated ssh key, and `config-init` derives
  `allowed_signers` from the public key on every start so it cannot drift.
- **Commit author vs push identity differ**: commits are authored as
  `GIT_USER_NAME <GIT_USER_EMAIL>`, while pushes authenticate as the `GH_TOKEN`
  account. For a "Verified" badge, `GIT_USER_EMAIL` must be a verified address on
  the account holding the signing key.
- **`rtk` is not automatic here.** Its documented auto-rewrite is a Claude Code
  hook; netclaw has no hook system, so the agent must type `rtk` itself. The
  `AGENTS.md` block says so.

## License

MIT, see [LICENSE](LICENSE).
