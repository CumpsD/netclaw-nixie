#!/bin/bash
# Copies the /tools payload baked into this image into the `tools` volume,
# which compose mounts here at /out and mounts read-only at /tools inside the
# netclaw container.
#
# The volume is mounted at /out rather than /tools on purpose: the image builds
# everything at its final runtime path (/tools) so that absolute paths baked by
# installers stay valid. Mounting the volume over /tools would shadow the
# payload we are trying to copy.
set -euo pipefail

SRC=/tools
DST=/out

want="$(cat "$SRC/.stamp" 2>/dev/null || echo unknown)"
have="$(cat "$DST/.stamp" 2>/dev/null || echo none)"

# TOOLS_REVISION is a manual override for forcing a re-copy without changing
# any version. Normal upgrades are caught by the stamp, which is derived from
# every version arg at build time — a hand-bumped counter would silently skip
# the copy after a version bump and leave stale tools in the volume.
force="${TOOLS_REVISION:-}"

if [ -n "$force" ]; then
    echo "[tools-init] TOOLS_REVISION=$force set — forcing re-provision"
elif [ "$want" = "$have" ] && [ "$want" != "unknown" ]; then
    echo "[tools-init] tools up to date (stamp $want) — nothing to do"
    exit 0
else
    echo "[tools-init] provisioning tools: $have -> $want"
fi

# --delete matters: a plain copy only ever adds, so a tool dropped from the
# Dockerfile would linger in the volume forever and keep resolving on PATH.
#
# -X preserves extended attributes, which is what carries tcpdump's
# cap_net_raw file capability. Without it the copy silently strips the xattr
# and tcpdump fails at runtime for the non-root agent user with a permission
# error that looks like a missing cap_add.
rsync -aX --delete "$SRC/" "$DST/"

# netclaw runs as uid/gid 1654. Its entrypoint deliberately does not recursive-
# chown /tools (it expects a large read-only toolset), so ownership is ours.
chown -R 1654:1654 "$DST"

# Re-apply tcpdump's file capability on the destination.
#
# The image carries it, and rsync is invoked with -X, but the security.capability
# xattr still does not make it into the volume — so set it here, where we are
# root and can. Without it the agent (uid 1654) gets "You don't have permission
# to perform this capture", because docker's cap_add grants CAP_NET_RAW to root
# only, never to an unprivileged user.
#
# cap_net_raw ONLY: naming a capability outside the container's bounding set
# (cap_net_admin is not in it) makes execve fail with EPERM for every user.
if [ -f "$DST/rootfs/usr/bin/tcpdump" ] && command -v setcap >/dev/null 2>&1; then
    if setcap cap_net_raw+eip "$DST/rootfs/usr/bin/tcpdump" 2>/dev/null; then
        echo "[tools-init] tcpdump: cap_net_raw granted"
    else
        echo "[tools-init] WARN: setcap on tcpdump failed — capture needs a root exec" >&2
    fi
fi

echo "[tools-init] provisioned $(du -sh "$DST" | cut -f1) (stamp $want)"
echo "[tools-init] $(find "$DST/bin" -maxdepth 1 -mindepth 1 | wc -l) entries in /tools/bin"
