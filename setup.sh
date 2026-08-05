#!/usr/bin/env bash
# One-shot bring-up for the Nixie deployment.
#
#   ./setup.sh
#
# Brings the stack up and runs netclaw's first-run wizard. Safe to re-run: it
# detects what is already done and skips it, so it doubles as a status check.
#
# Deliberately does NOT configure the provider, model or security posture
# itself — that is `netclaw init`'s job, and those are operator decisions.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---- presentation ----------------------------------------------------------
# Colour only when attached to a terminal, so piping to a file or CI log stays
# readable. NO_COLOR is honoured (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
    RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[36m'
else
    B=''; DIM=''; R=''; RED=''; GRN=''; YEL=''; BLU=''
fi

STEP=0
step()  { STEP=$((STEP+1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$BLU" "$STEP" "$TOTAL" "$R" "$B" "$1" "$R"; }
ok()    { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
warn()  { printf '  %s!%s %s\n' "$YEL" "$R" "$1"; }
fail()  { printf '  %s✗%s %s\n' "$RED" "$R" "$1"; }
info()  { printf '    %s%s%s\n' "$DIM" "$1" "$R"; }
die()   { printf '\n%s✗ %s%s\n\n' "$RED" "$1" "$R" >&2; exit 1; }
TOTAL=5

# Quoted heredoc: the art is full of backslashes, and unquoted they would be
# eaten as escapes.
printf '\n%s' "$BLU"
cat <<'BANNER'
   _   _ _      _
  | \ | (_)_  _(_) ___
  |  \| | \ \/ / |/ _ \
  | |\  | |>  <| |  __/
  |_| \_|_/_/\_\_|\___|
BANNER
printf '%s' "$R"
printf '  %snetclaw agent deployment%s\n' "$DIM" "$R"

# ---- 1. preflight ----------------------------------------------------------
step "Preflight"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
docker compose version >/dev/null 2>&1 || die "docker compose v2 not available."
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running, are you in the docker group?)."
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') and compose available"

if [ ! -f .env ]; then
    cp .env.example .env
    chmod 600 .env
    fail "no .env found — created one from .env.example"
    info "Edit it before continuing. At minimum set GH_TOKEN, GIT_USER_NAME, GIT_USER_EMAIL."
    exit 1
fi
ok ".env present"

# Read values without sourcing, so a stray command in .env cannot execute.
envval() { sed -n "s/^$1=//p" .env | tail -1; }
missing=()
for v in GH_TOKEN GIT_USER_NAME GIT_USER_EMAIL; do
    [ -n "$(envval "$v")" ] || missing+=("$v")
done
[ ${#missing[@]} -eq 0 ] || die ".env is missing values for: ${missing[*]}"

case "$(envval GH_TOKEN)" in
    *xxxxxxxxxx*|github_pat_xxx*) die "GH_TOKEN in .env is still the placeholder from .env.example." ;;
esac
ok ".env has the required values"

# Shared secret for the headless-Chromium sidecar. Generated per deployment
# rather than shipped in the template, so no two forks share a token. The
# service publishes no host port, so this only gates the compose network, but a
# token committed to a public repo is not a token.
if [ -z "$(envval BROWSERLESS_TOKEN)" ]; then
    if command -v openssl >/dev/null 2>&1; then
        tok="$(openssl rand -hex 24)"
    else
        tok="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
    fi
    # Replace an empty assignment if present, otherwise append.
    if grep -q '^BROWSERLESS_TOKEN=' .env; then
        sed -i "s|^BROWSERLESS_TOKEN=.*|BROWSERLESS_TOKEN=$tok|" .env
    else
        printf '\nBROWSERLESS_TOKEN=%s\n' "$tok" >> .env
    fi
    ok "generated BROWSERLESS_TOKEN into .env"
else
    ok "BROWSERLESS_TOKEN present"
fi

# Bind-mount sources. Docker would create them on first `up`, but as root:root;
# making them here keeps them host-owned from the start.
mkdir -p cache nuget netclaw ssh
ok "bind-mount directories present"

# Default ACL granting the host user rwX on everything under these trees.
#
# config-init chowns them to uid 1654 so the daemon can write. Without an ACL
# that locks this account out, and git fails on the tracked files inside with
# "unable to unlink old 'netclaw/config/netclaw.json': Permission denied".
#
# Applied here, before the first `up`, while the directories are still ours: a
# default ACL survives the later chown and is inherited by every file the
# daemon creates afterwards.
if command -v setfacl >/dev/null 2>&1 \
   && setfacl -R -m "u:$(id -u):rwX" -d -m "u:$(id -u):rwX" cache nuget netclaw ssh 2>/dev/null; then
    ok "host access to container-owned directories granted (ACL)"
else
    warn "could not set an ACL on the bind mounts"
    info "The stack still works, but once config-init chowns netclaw/ to uid 1654"
    info "this account loses write access to it, so git operations touching"
    info "netclaw/config/*.json or netclaw/identity/*.md will fail, and reading"
    info "logs will need sudo."
    info "Install 'acl', or ensure the filesystem is mounted with ACL support."
fi

# ---- signing key -----------------------------------------------------------
# No key material is committed — it is per-deployment — so generate one on
# first run. Only when GIT_USER_KEY names a *private* key: a name ending in
# .pub is the agent-forwarding flow, where the private half deliberately lives
# outside the container and there is nothing to generate.
key="$(envval GIT_USER_KEY)"
NEW_KEY=0
if [ -z "$key" ]; then
    info "GIT_USER_KEY unset — commit signing disabled"
elif [ "$key" != "${key%.pub}" ]; then
    [ -f "ssh/$key" ] && ok "using public key ssh/$key (agent-forwarding flow)" \
                      || warn "GIT_USER_KEY=$key but ssh/$key is missing"
elif [ -f "ssh/$key" ]; then
    ok "signing key ssh/$key present"
elif [ -f "ssh/$key.pub" ]; then
    # A private key cannot be recovered from its public half, and generating a
    # new pair would silently orphan whatever is already registered on GitHub —
    # so stop and let a human decide which case this is.
    printf '\n%s✗ ssh/%s.pub is present but the private key ssh/%s is not.%s\n\n' "$RED" "$key" "$key" "$R"
    cat <<EOF
    If you just cloned this repo, that public key belongs to another
    deployment and is of no use to you. Delete it and re-run to get your own:

        rm ssh/$key.pub && ./setup.sh

    If this is your deployment and the private key went missing, restore it
    from a backup. Generating a new one invalidates the key GitHub has, and
    every signature made with it.

EOF
    exit 1
else
    warn "no signing key yet — generating ssh/$key"
    # Generated in a container rather than with the host's ssh-keygen so that
    # ssh-keygen is not a host prerequisite. Ownership of the results is split
    # deliberately: the private key must be owned by uid 1654 because ssh
    # refuses a key it does not own, while the .pub is tracked by git and stays
    # owned by the host user — chowning it away would make every later
    # checkout fail with "unable to unlink ... Permission denied".
    docker run --rm -v "$PWD/ssh:/s" \
        -e C="$(envval GIT_USER_EMAIL)" -e K="$key" -e HOSTUID="$(id -u):$(id -g)" \
        ubuntu:24.04 bash -c '
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq openssh-client >/dev/null 2>&1
            ssh-keygen -t ed25519 -a 100 -N "" -C "$C" -f "/s/$K" -q
            chown 1654:1654 "/s/$K";       chmod 600 "/s/$K"
            chown "$HOSTUID"  "/s/$K.pub"; chmod 644 "/s/$K.pub"' \
        || die "key generation failed"
    ok "generated ssh/$key ($(ssh-keygen -lf "ssh/$key.pub" 2>/dev/null | awk '{print $2}'))"
    NEW_KEY=1
fi

# ---- 2. build --------------------------------------------------------------
step "Building the tools image"
if docker image inspect nixie-tools-init:latest >/dev/null 2>&1; then
    info "image exists; rebuilding only if the recipe changed"
else
    warn "first build downloads ~3GB of toolchain — this takes several minutes"
fi
docker compose build tools-init
ok "tools image ready"

# ---- 3. up -----------------------------------------------------------------
step "Starting the stack"
info "first run also clones the workspace repos, which can take a few minutes"
docker compose up -d
ok "containers started"

# ---- 4. wait for health ----------------------------------------------------
step "Waiting for netclaw to become healthy"
deadline=$((SECONDS + 300))
while :; do
    state="$(docker inspect -f '{{.State.Health.Status}}' netclaw 2>/dev/null || echo missing)"
    case "$state" in
        healthy) ok "netclaw is healthy"; break ;;
        missing) die "the netclaw container is not running — check: docker compose logs" ;;
    esac
    [ $SECONDS -lt $deadline ] || die "netclaw did not become healthy within 5 minutes. Check: docker compose logs netclaw"
    sleep 3
done

# ---- 5. first-run wizard ---------------------------------------------------
step "netclaw configuration"

# Ask netclaw itself rather than parsing netclaw.json, which is owned by uid
# 1654 and may not be readable from the host.
doctor="$(docker compose exec -T netclaw netclaw doctor 2>&1 || true)"

needs_init=0
grep -q '\[FAIL\] Security Policy' <<<"$doctor" && needs_init=1
grep -q '\[WARN\] Chat Client'     <<<"$doctor" && needs_init=1

if [ "$needs_init" -eq 0 ]; then
    ok "provider, model and security posture already configured"
else
    warn "netclaw needs its first-run setup"
    info "Without it the agent has no model AND shell_execute stays disabled,"
    info "which means none of the tools in /tools are usable."
    if [ -t 0 ] && [ -t 1 ]; then
        printf '\n%s  Starting the wizard — it asks for a provider, an API key and a model.%s\n\n' "$DIM" "$R"
        docker compose exec -it netclaw netclaw init
        doctor="$(docker compose exec -T netclaw netclaw doctor 2>&1 || true)"
    else
        warn "not an interactive terminal — run this yourself:"
        printf '\n      docker compose exec -it netclaw netclaw init\n'
    fi
fi

# ---- summary ---------------------------------------------------------------
fails=$(grep -c '^\[FAIL\]' <<<"$doctor" || true)
warns=$(grep -c '^\[WARN\]' <<<"$doctor" || true)

printf '\n%s%s%s\n' "$B" "── Status ─────────────────────────────────────────────" "$R"
if [ "$fails" -eq 0 ]; then
    ok "netclaw doctor: no failures ($warns warning(s))"
else
    fail "netclaw doctor: $fails failure(s), $warns warning(s)"
    grep -E '^\[(FAIL|WARN)\]' <<<"$doctor" | sed 's/^/    /'
fi

if [ "$NEW_KEY" -eq 1 ]; then
    printf '\n%s%s%s\n' "$B" "── Add this key to GitHub ─────────────────────────────" "$R"
    printf '    %s%s%s\n\n' "$GRN" "$(cat "ssh/$key.pub")" "$R"
    cat <<'EOF'
    Register it TWICE at https://github.com/settings/keys — once as an
    Authentication key and once as a Signing key. They are separate entries;
    adding only the first leaves commits showing as Unverified.

    For the "Verified" badge, GIT_USER_EMAIL must also be a verified address
    on that GitHub account.

    Until the Authentication key is added, cloning private repos over ssh
    fails with "Permission denied (publickey)".

    The public half is tracked by git; the private half is not. Commit it to
    record which key this deployment signs with:

        git add ssh/*.pub && git commit -m "chore: add deployment signing key"

EOF
fi

printf '\n%s%s%s\n' "$B" "── Next ───────────────────────────────────────────────" "$R"
cat <<EOF
    Chat with the agent      docker compose exec -it netclaw netclaw chat
    One-shot prompt          docker compose exec -T  netclaw netclaw chat -p "hello"
    Full diagnostics         docker compose exec -T  netclaw netclaw doctor
    Authorise Atlassian      docker compose exec -it netclaw netclaw mcp auth atlassian
    Follow the logs          docker compose logs -f netclaw

EOF
