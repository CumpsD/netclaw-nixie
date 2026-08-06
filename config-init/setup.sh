#!/bin/bash
# One-shot netclaw configuration, run before the daemon starts.
#
# Uses the netclaw image purely for its CLI: `netclaw mcp add` is a plain config
# write and needs no running daemon, so this can safely run first and avoid any
# race with netclawd over netclaw.json.
#
# Every step is idempotent. netclaw gates on this service exiting 0
# (service_completed_successfully), so a non-zero exit blocks the agent from
# starting at all — only steps netclaw genuinely cannot run without are fatal.
# Best-effort steps warn and continue.
set -euo pipefail

NETCLAW_HOME="${NETCLAW_HOME:-/home/netclaw/.netclaw}"
UID_GID=1654:1654

log()  { printf '[config-init] %s\n' "$*"; }
warn() { printf '[config-init] WARN: %s\n' "$*" >&2; }

# On a fresh clone of the nixie repo, netclaw/ holds only .gitkeep — the
# database, logs, keys, sessions, config and identity files are all generated at
# runtime. Do not assume any directory exists.
mkdir -p "$NETCLAW_HOME/config" "$NETCLAW_HOME/identity" "$NETCLAW_HOME/workspaces"

# Hand the whole tree to uid 1654 BEFORE calling the netclaw CLI.
#
# The CLI is a self-dropping launcher (upstream ADR-004): invoked as root it
# re-executes as the unprivileged netclaw user. So it always runs as 1654 no
# matter that this container is root, and every path it touches must already be
# writable by 1654 — including the directories mkdir just created as root:root.
#
# netclaw's own entrypoint repairs ownership, but it runs AFTER this service.
# Without this, a fresh clone fails every `netclaw mcp` call with
# "Failed to initialize Netclaw directories ... Access to the path
# '/data/identity/soul' is denied", and MCP registration is silently skipped.
chown "$UID_GID" "$NETCLAW_HOME" "$NETCLAW_HOME/config" \
                 "$NETCLAW_HOME/identity" "$NETCLAW_HOME/workspaces"
if [ "$(stat -c '%u:%g' "$NETCLAW_HOME")" != "$UID_GID" ]; then
    chown -R "$UID_GID" "$NETCLAW_HOME"
fi

# ---------------------------------------------------------------------------
# 1. Bind-mount ownership.
#
# netclaw's own entrypoint repairs only $NETCLAW_HOME, and it short-circuits
# even that when the top-level dir already matches 1654 — so it will never fix
# .cache/.nuget/.ssh, nor any root-owned file we write below. Docker creates a
# missing bind-mount source as root:root, and the daemon runs as uid 1654, so
# without this npm and NuGet fail with EACCES on first write.
# ---------------------------------------------------------------------------
for d in /chown/cache /chown/nuget; do
    [ -d "$d" ] || continue
    if [ "$(stat -c '%u:%g' "$d")" != "$UID_GID" ]; then
        log "chown $d -> $UID_GID"
        chown -R "$UID_GID" "$d"
    fi
done

# ssh permissions, split by sensitivity.
#
# Private keys are locked to the runtime user. The directory stays 0755 and
# the public material 0644 on purpose: ssh/config, ssh/known_hosts and
# ssh/*.pub are git-tracked, and a 0700 directory owned by uid 1654 makes them
# unreadable to the human on the host — `git status` then fails with
# "Permission denied" and reports the tracked files as missing.
#
# ssh's client-side mode check applies to the private key file, not to the
# directory, so 0755 here is safe. (StrictModes' directory check is sshd's.)
if [ -d /chown/ssh ]; then
    chmod 755 /chown/ssh
    find /chown/ssh -type f \
        \( -name '*.pub' -o -name 'known_hosts' -o -name 'config' -o -name '.gitkeep' \) \
        -exec chmod 644 {} + 2>/dev/null || true
    find /chown/ssh -type f \
        ! -name '*.pub' ! -name 'known_hosts' ! -name 'config' ! -name '.gitkeep' \
        -exec chown "$UID_GID" {} + -exec chmod 600 {} + 2>/dev/null || true
    # config needs 1654 as OWNER, not just readability: ssh refuses to start
    # with "Bad owner or permissions on ~/.ssh/config" unless the file is
    # owned by the uid running ssh, or by root. The bind mount keeps the host
    # owner and docker has no idmapped bind mounts, so it is repaired here.
    # Mode stays 644 — the host keeps read access for git; editing it on the
    # host needs sudo from now on.
    #
    # The chmod 644 above is also load-bearing for setup.sh's host ACL: an
    # ACL mask shows up as the group bits of st_mode, and ssh rejects
    # group-write with the same "Bad owner" error. chmod 644 caps the mask
    # to read, so re-running setfacl only breaks ssh until the next start.
    if [ -f /chown/ssh/config ]; then
        chown "$UID_GID" /chown/ssh/config
    fi
    log "ssh: private keys and config owned by $UID_GID, public material left readable"
fi

# ---------------------------------------------------------------------------
# 2. Git identity.
#
# /home/netclaw is plain container layer — only .netclaw is bind-mounted — so
# ~/.gitconfig cannot survive a container recreate. nixie.yml therefore sets
# GIT_CONFIG_GLOBAL to this file, inside the persistent mount. Written only if
# absent, so edits by the agent or by hand survive.
# ---------------------------------------------------------------------------
GITCONFIG="$NETCLAW_HOME/gitconfig"
if [ ! -f "$GITCONFIG" ]; then
    log "seeding $GITCONFIG for ${GIT_USER_NAME:-?} <${GIT_USER_EMAIL:-?}>"
    cat > "$GITCONFIG" <<EOF
# Seeded by config-init. Safe to edit — never overwritten once it exists.
[user]
	name = ${GIT_USER_NAME}
	email = ${GIT_USER_EMAIL}
[credential "https://github.com"]
	helper = !gh auth git-credential
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF
    chown "$UID_GID" "$GITCONFIG"
else
    log "gitconfig already present — leaving alone"
fi

# SSH commit signing. GIT_USER_KEY is the basename of a key inside ~/.ssh.
# Mirrors the private-vs-public split from the dev sandbox entrypoint: with only
# a public key we can set the signing key but must NOT enable auto-signing,
# because `ssh-keygen -Y sign` cannot reach the private half and every commit
# would fail.
if [ -n "${GIT_USER_KEY:-}" ]; then
    key_path="/home/netclaw/.ssh/${GIT_USER_KEY}"
    host_key="/chown/ssh/${GIT_USER_KEY}"
    if [ ! -f "$host_key" ]; then
        warn "GIT_USER_KEY=${GIT_USER_KEY} but ${host_key} not found — signing not configured"
    else
        # allowed_signers is what lets `git log --show-signature` and
        # `git verify-commit` report "Good signature" instead of failing with
        # "gpg.ssh.allowedSignersFile needs to be configured".
        #
        # Rewritten on EVERY run, deliberately outside the gitconfig-seeding
        # branch below. It is derived state — email plus public key — and if it
        # were only written when gitconfig is first created, rotating
        # GIT_USER_KEY or changing GIT_USER_EMAIL would leave a stale file that
        # still verifies against the OLD key. Regenerating unconditionally is
        # cheap and is also why this file is gitignored rather than committed:
        # one source of truth (the .pub), no second copy to drift.
        pub="/chown/ssh/${GIT_USER_KEY%.pub}.pub"
        if [ -f "$pub" ]; then
            want="${GIT_USER_EMAIL} $(cat "$pub")"
            if [ "$(cat /chown/ssh/allowed_signers 2>/dev/null)" != "$want" ]; then
                printf '%s\n' "$want" > /chown/ssh/allowed_signers
                log "ssh: wrote allowed_signers for ${GIT_USER_EMAIL}"
            fi
            chmod 644 /chown/ssh/allowed_signers
        else
            warn "no ${pub} — signature verification will not work"
        fi
    fi

    if [ -f "$host_key" ] && ! grep -q 'signingkey' "$GITCONFIG"; then
        {
            echo '[gpg]'
            echo '	format = ssh'
            echo '[gpg "ssh"]'
            echo '	allowedSignersFile = /home/netclaw/.ssh/allowed_signers'
            echo '[user]'
            echo "	signingkey = ${key_path}"
        } >> "$GITCONFIG"
        if [ "${GIT_USER_KEY}" = "${GIT_USER_KEY%.pub}" ]; then
            # Real private key on disk — sign unconditionally.
            printf '[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' >> "$GITCONFIG"
            log "ssh commit signing enabled with ${key_path}"
        else
            printf '[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' >> "$GITCONFIG"
            warn "public-key-only (${GIT_USER_KEY}) and no ssh-agent — signingkey set, auto-signing off"
        fi
        chown "$UID_GID" "$GITCONFIG"
    fi
fi

# ===========================================================================
# ONE-TIME SEEDING
#
# Everything below this point runs exactly once, on the first start, and is
# then skipped forever. netclaw's config and identity files are the operator's
# to manage from there on — with the netclaw CLI, by hand, or in git, since a
# fork tracks config/netclaw.json, config/tool-approvals.json,
# identity/AGENTS.md and identity/SOUL.md.
#
# Re-applying on every start would fight that: it would re-add an MCP server
# the operator deliberately removed, undo a rename, and re-insert approvals
# that were revoked. The seed is a starting point, not a desired state.
#
# Delete the marker file to deliberately re-seed.
#
# Seeding also waits for `netclaw init`. Writing config/netclaw.json before the
# wizard has run makes it report "Existing Netclaw install detected" and offer a
# repair menu instead of the first-run flow — because merely registering an MCP
# server creates the file. So nothing here touches netclaw config until the
# wizard has left its own marks on it: a Security section and a main model.
#
# setup.sh re-runs this service straight after the wizard, so the wait is
# invisible there; a bare `docker compose up -d` picks it up on the next start.
# ===========================================================================
SEED_MARKER="$NETCLAW_HOME/.nixie-seeded"
NCJSON="$NETCLAW_HOME/config/netclaw.json"

netclaw_initialised() {
    [ -f "$NCJSON" ] || return 1
    jq -e '.Security and (.Models.Roles.Main // empty)' "$NCJSON" >/dev/null 2>&1
}

if [ -f "$SEED_MARKER" ]; then
    log "already seeded on $(cat "$SEED_MARKER" 2>/dev/null || echo 'an earlier run') — leaving config and identity alone"
elif ! netclaw_initialised; then
    log "netclaw is not configured yet — deferring config and identity seeding"
    log "  run: docker compose exec -it netclaw netclaw init"
    log "  (setup.sh does this for you, then re-runs this step)"
else
    log "first run after netclaw init — seeding config and identity"

# ---------------------------------------------------------------------------
# 3. MCP servers.
#
# Contrary to the bundled references/tools.md (which describes older
# fail-closed behaviour), netclaw 0.25.2's `mcp add` grants the Personal
# audience all tools with approval mode Auto, so no interactive
# `netclaw mcp permissions` pass is needed.
#
# Do NOT use `--env` to pass the PAT: it is accepted but not persisted
# (EnvironmentVariables stays null). The stdio child inherits the daemon's
# environment instead, and nixie.yml sets GITHUB_PERSONAL_ACCESS_TOKEN there.
# ---------------------------------------------------------------------------
add_mcp() {
    local name="$1"; shift
    if netclaw mcp get "$name" >/dev/null 2>&1; then
        log "mcp: $name already registered"
    else
        log "mcp: registering $name"
        netclaw mcp add "$@" || warn "mcp: failed to register $name"
    fi
}

add_mcp github    --transport stdio github -- github-mcp-server stdio
add_mcp qmd       --transport stdio qmd -- qmd mcp
add_mcp searxng   --transport stdio searxng -- mcp-searxng
add_mcp atlassian --transport http atlassian https://mcp.atlassian.com/v1/mcp

# ---------------------------------------------------------------------------
# 4. Agent identity name.
#
# Only applied when the wizard left the name unset or at netclaw's default.
# `netclaw init` asks for an agent name, and a name chosen there is a more
# deliberate answer than AGENT_NAME's default in .env — so it wins.
# ---------------------------------------------------------------------------
# EFFECTIVE_NAME is what the deployment actually calls itself, which SOUL.md
# below follows. It is AGENT_NAME only when the wizard did not set a name of
# its own — otherwise netclaw.json and SOUL.md would disagree.
EFFECTIVE_NAME="${AGENT_NAME:-}"
if [ -n "${AGENT_NAME:-}" ] && [ -f "$NCJSON" ]; then
    current="$(jq -r '.Identity.AgentName // ""' "$NCJSON")"
    case "$current" in
        ""|Netclaw)
            log "setting agent name: '${current:-unset}' -> '${AGENT_NAME}'"
            jq --arg n "$AGENT_NAME" '.Identity.AgentName = $n' "$NCJSON" > /tmp/nc.json \
                && cat /tmp/nc.json > "$NCJSON" && rm -f /tmp/nc.json
            ;;
        "$AGENT_NAME") ;;
        *)
            log "agent name '${current}' set during netclaw init — keeping it"
            EFFECTIVE_NAME="$current"
            ;;
    esac
fi

# SOUL.md is handled separately from the netclaw.json rename above.
#
# On a fresh deployment config-init runs BEFORE the daemon has ever started, so
# SOUL.md does not exist yet — the daemon generates it afterwards, with its
# stock "You are Netclaw" text. That means the first seeding pass cannot fix it
# and the second one must, which is why this is not gated on netclaw.json
# needing a change. The seed marker is only written once SOUL.md has actually
# been rewritten, so seeding stays pending until the daemon has produced it.
SOUL="$NETCLAW_HOME/identity/SOUL.md"
if [ -n "${EFFECTIVE_NAME:-}" ] && [ -f "$SOUL" ]; then
    soul_name="$(sed -n 's/^# You are \(.*\)$/\1/p' "$SOUL" | head -1)"
    if [ -n "$soul_name" ] && [ "$soul_name" != "$EFFECTIVE_NAME" ]; then
        sed -i "1,10s/^# You are ${soul_name}$/# You are ${EFFECTIVE_NAME}/" "$SOUL"
        chown "$UID_GID" "$SOUL"
        log "SOUL.md: '${soul_name}' -> '${EFFECTIVE_NAME}'"
    fi
fi

# ---------------------------------------------------------------------------
# 4b. AGENTS.md tooling block.
#
# netclaw generates SOUL.md on first daemon start but never AGENTS.md, so this
# both creates the file and maintains one marker-delimited section of it. The
# section documents things the agent cannot discover on its own: that rtk must
# be typed explicitly here (netclaw has no PreToolUse hook to rewrite commands),
# that /tools is read-only, and that the browser is a CDP endpoint rather than a
# local binary.
# ---------------------------------------------------------------------------
AGENTS="$NETCLAW_HOME/identity/AGENTS.md"
if [ -f /init/agents-block.md ]; then
    result="$(python3 /init/merge-agents.py "$AGENTS" /init/agents-block.md 2>&1)" || true
    chown "$UID_GID" "$AGENTS" 2>/dev/null || true
    log "AGENTS.md tooling block: ${result}"
fi

# ---------------------------------------------------------------------------
# 4c. Search backend.
#
# Points netclaw's built-in web search at the SearXNG sidecar, whose JSON API
# is what this backend consumes. Only seeded while .Search is absent, so an
# operator who switched backends or moved the endpoint keeps that choice on a
# re-seed. The endpoint mirrors SEARXNG_URL in nixie.yml.
# ---------------------------------------------------------------------------
if jq -e '.Search' "$NCJSON" >/dev/null 2>&1; then
    log "search: .Search already configured — keeping it"
else
    log "search: pointing netclaw's web search at the searxng sidecar"
    jq '.Search = {Backend: "searxng", SearXngEndpoint: "http://searxng:8080"}' "$NCJSON" > /tmp/nc.json \
        && cat /tmp/nc.json > "$NCJSON" && rm -f /tmp/nc.json
fi

# ---------------------------------------------------------------------------
# 7. shell_execute approval seed.
#
# A starting set, not a desired state. The daemon appends to this file whenever
# the operator approves a new verb at runtime, so re-applying the seed on every
# start would resurrect verbs that were deliberately revoked. It runs once and
# the file is the deployment's from then on.
#
# Race-free: the daemon owns tool-approvals.json only while running, and it has
# not started yet.
# ---------------------------------------------------------------------------
TA="$NETCLAW_HOME/config/tool-approvals.json"
SEED=/init/approvals-seed.json
if [ -f "$SEED" ]; then
    [ -f "$TA" ] || echo '{"version":2,"audiences":{"personal":{"shell_execute":[]}}}' > "$TA"
    before="$(jq -r '.audiences.personal.shell_execute | length' "$TA" 2>/dev/null || echo 0)"
    jq --slurpfile seed "$SEED" --arg now "$(date -Iseconds)" '
        .version //= 2
        | .audiences //= {}
        | .audiences.personal //= {}
        | .audiences.personal.shell_execute //= []
        | .audiences.personal.shell_execute as $cur
        | ($cur | map(.verb)) as $have
        | .audiences.personal.shell_execute =
            ($cur + [ $seed[0].verbs[]
                      | select(. as $v | ($have | index($v)) | not)
                      | {verb: ., createdAt: $now} ])
    ' "$TA" > /tmp/ta.json && cat /tmp/ta.json > "$TA" && rm -f /tmp/ta.json
    after="$(jq -r '.audiences.personal.shell_execute | length' "$TA")"
    log "approvals: $before -> $after verbs"
fi

    # --- end of one-time seeding -------------------------------------------
    # The marker is written only once SOUL.md exists and carries the agent
    # name. On a brand-new deployment the daemon has not generated SOUL.md yet,
    # so seeding stays pending and completes on the next start rather than
    # being marked done with the name unset.
    if [ -f "$SOUL" ] && ! grep -q '^# You are Netclaw$' "$SOUL"; then
        date -Iseconds > "$SEED_MARKER"
        chown "$UID_GID" "$SEED_MARKER"
        log "seeding complete — config and identity are yours from here"
    else
        log "seeding will finish on the next start (waiting for the daemon to create SOUL.md)"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Workspace bootstrap.
#
# .gitignore excludes netclaw/workspaces/, so a fresh clone of the nixie repo
# has no workspace at all and ExternalSkills.Sources[].Path would point at
# nothing, silently losing the skills those repos provide.
#
# WORKSPACE_REPOS is a whitespace-separated list. Each entry is either:
#     <url>            -> cloned to $WORKSPACE_ROOT/<repo-name-without-.git>
#     <url>=<subdir>   -> cloned to $WORKSPACE_ROOT/<subdir>
# The derived form matches the existing layout, so the common case needs no
# explicit directory. <subdir> may contain slashes if you want deeper nesting.
# Splitting on '=' is safe for scp-style SSH URLs, which use ':' not '='.
#
# Clone only — never auto-pull, which would silently discard agent work in
# progress. Best effort per repo: one unreachable remote must not block the
# agent from starting, and must not stop the other repos from cloning.
# ---------------------------------------------------------------------------
if [ -n "${WORKSPACE_REPOS:-}" ]; then
    WORKSPACE_ROOT="${WORKSPACE_ROOT:-$NETCLAW_HOME/workspaces}"
    mkdir -p "$WORKSPACE_ROOT"

    # ssh transport for git@host:… and ssh:// entries.
    #
    # The netclaw image has no ssh client at all, so those clones die with
    # "error: cannot run ssh: No such file or directory". We borrow the one
    # provisioned into /tools (mounted read-only here) and point it at the key
    # and known_hosts under /chown/ssh, since this container runs as root and
    # HOME is /root — ssh would otherwise look in /root/.ssh and find nothing.
    #
    # Reading the 0600 key owned by 1654 is fine: root bypasses file modes.
    case "$WORKSPACE_REPOS" in
        *ssh://*|*@*:*)
            if [ ! -x /tools/bin/ssh ]; then
                warn "workspace: ssh URLs configured but /tools/bin/ssh is missing"
                warn "  the tools volume is not mounted or not provisioned yet;"
                warn "  ssh clones will fail. https:// URLs are unaffected."
            else
                ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=yes"
                [ -f /chown/ssh/known_hosts ] \
                    && ssh_opts="$ssh_opts -o UserKnownHostsFile=/chown/ssh/known_hosts"
                if [ -n "${GIT_USER_KEY:-}" ] && [ -f "/chown/ssh/${GIT_USER_KEY%.pub}" ]; then
                    ssh_opts="$ssh_opts -i /chown/ssh/${GIT_USER_KEY%.pub} -o IdentitiesOnly=yes"
                else
                    warn "workspace: no usable private key for ssh clones — private repos will fail"
                fi
                export GIT_SSH_COMMAND="/tools/bin/ssh $ssh_opts"
                log "workspace: ssh via /tools/bin/ssh"
            fi
            ;;
    esac

    # Word splitting is the point here, so the expansion is intentionally bare.
    # shellcheck disable=SC2086
    for entry in $WORKSPACE_REPOS; do
        url="${entry%%=*}"
        if [ "$entry" = "$url" ]; then
            name="$(basename "$url" .git)"
        else
            name="${entry#*=}"
        fi
        dest="$WORKSPACE_ROOT/$name"

        if [ -d "$dest/.git" ]; then
            log "workspace: $name already cloned"
            continue
        fi

        log "workspace: cloning $name from $url${WORKSPACE_CLONE_ARGS:+ ($WORKSPACE_CLONE_ARGS)}"
        mkdir -p "$(dirname "$dest")"
        # WORKSPACE_CLONE_ARGS is unquoted on purpose so multiple flags split.
        # shellcheck disable=SC2086
        if GIT_TERMINAL_PROMPT=0 git -c "credential.helper=!f(){ echo username=x-access-token; echo password=${GH_TOKEN:-}; };f" \
                clone --quiet ${WORKSPACE_CLONE_ARGS:-} "$url" "$dest"; then
            log "workspace: $name cloned"
        else
            warn "workspace: clone of $name failed — its skills will be unavailable"
            # Leave no half-created directory behind to confuse the next run.
            rmdir "$dest" 2>/dev/null || true
        fi
    done

    chown -R "$UID_GID" "$WORKSPACE_ROOT"
fi

# ---------------------------------------------------------------------------
# 6. Directory.Build.props for the workspace (from the dev sandbox entrypoint).
# Suppresses NU1510 and disables TreatWarningsAsErrors so a stray warning
# cannot fail a build. Merges into an existing file; bails out if unparseable.
# ---------------------------------------------------------------------------
# Written once at the workspace root so it applies to every cloned repo below
# it, rather than per-repo — MSBuild walks up from the project directory and
# stops at the first Directory.Build.props it finds.
if [ -n "${WORKSPACE_REPOS:-}" ] && [ -d "${WORKSPACE_ROOT:-}" ]; then
    if python3 /init/build-props.py "$WORKSPACE_ROOT/Directory.Build.props"; then
        chown "$UID_GID" "$WORKSPACE_ROOT/Directory.Build.props" 2>/dev/null || true
        log "Directory.Build.props: ensured"
    else
        warn "Directory.Build.props: update failed"
    fi
fi


# ---------------------------------------------------------------------------
# 8. Ownership of everything we may have written as root.
#
# Every name is expanded with :- because TA, AGENTS and SOUL are only assigned
# inside the seeding branch. When seeding is skipped — already done, or waiting
# on `netclaw init` — they are unset, and under `set -u` a bare "$TA" aborts the
# whole script at list expansion, before the [ -n ] guard inside the loop ever
# runs. That took config-init down with "TA: unbound variable" after a
# successful workspace clone.
# ---------------------------------------------------------------------------
for f in "${NCJSON:-}" "${TA:-}" "${GITCONFIG:-}" "${AGENTS:-}" "${SOUL:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && chown "$UID_GID" "$f"
done

# ---------------------------------------------------------------------------
# 9. Fresh-host warnings.
#
# A clone of the nixie repo carries only the five allowlisted netclaw files.
# secrets.json holds the inference provider credentials and is gitignored, so
# on a new host it is absent and netclawd falls back to a no-op chat client
# with only an easily-missed line in the daemon log. Say so plainly instead.
# ---------------------------------------------------------------------------
if [ ! -f "$NETCLAW_HOME/config/secrets.json" ]; then
    warn "config/secrets.json is missing — no inference provider credentials."
    warn "  netclawd will start but register a no-op chat client and answer nothing."
    warn "  Add the provider key with: docker compose exec netclaw netclaw secret set ..."
fi

log "done"
