#!/bin/bash
# Tier 2: apt-sourced tools that netclaw lacks and that cannot be copied as
# bare binaries, because they need shared libraries the netclaw image does not
# ship.
#
# Strategy: apt-get install here in the builder, then for each wanted binary
# copy it into /tools/rootfs/usr/bin and walk its `ldd` closure, copying every
# non-core library into /tools/rootfs/usr/lib. Finally rewrite each binary's
# RUNPATH to $ORIGIN/../lib so it finds those libraries at runtime.
#
# Why RUNPATH and not LD_LIBRARY_PATH: a global LD_LIBRARY_PATH would apply to
# *every* process in the netclaw container, including netclawd itself (a .NET
# app), and would silently shadow system libraries. RUNPATH scopes the override
# to exactly these binaries.
#
# Why the glibc exclusion list matters: the dynamic loader (ld-linux) comes from
# the host image. Shipping a second libc.so.6 next to it is the classic way to
# segfault every binary in the container. Both images are Ubuntu 24.04 / glibc
# 2.39, so the system copies are correct anyway.
set -euo pipefail

ROOTFS=/tools/rootfs
BINDIR="$ROOTFS/usr/bin"
LIBDIR="$ROOTFS/usr/lib"
mkdir -p "$BINDIR" "$LIBDIR" "$ROOTFS/usr/share/misc" /tools/bin

echo "==> installing tier-2 packages"
apt-get update
apt-get install -y --no-install-recommends \
    unzip file rsync less xxd git-lfs \
    postgresql-client-16 bind9-dnsutils iproute2 netcat-openbsd tcpdump \
    redis-tools openssh-client libatomic1 libcap2-bin

# Libraries that must always come from the host image, never from /tools.
# Shipping our own copy of any of these alongside the system ld.so breaks
# everything that links against them.
is_core_lib() {
    case "$1" in
        libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|\
        libresolv.so.*|ld-linux*|libnss_*|libutil.so.*)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Copy one binary plus its entire ldd closure.
vendor() {
    local src="$1" name="${2:-}"
    [ -n "$name" ] || name="$(basename "$src")"

    if [ ! -x "$src" ]; then
        echo "    !! $name: $src not found — skipping" >&2
        return 0
    fi

    install -m 0755 "$src" "$BINDIR/$name"

    # `ldd` output lines look like:  libfoo.so.1 => /lib/x86_64-linux-gnu/libfoo.so.1 (0x…)
    local lib base
    while read -r lib; do
        [ -n "$lib" ] || continue
        base="$(basename "$lib")"
        is_core_lib "$base" && continue
        [ -e "$LIBDIR/$base" ] && continue
        cp -L "$lib" "$LIBDIR/$base" 2>/dev/null || true
    done < <(ldd "$src" 2>/dev/null | awk '/=> \//{print $3}')

    # $ORIGIN is resolved by the loader relative to the binary, so this stays
    # correct wherever the volume is mounted.
    patchelf --set-rpath '$ORIGIN/../lib' "$BINDIR/$name" 2>/dev/null || true

    ln -sf "../rootfs/usr/bin/$name" "/tools/bin/$name"
    echo "    ok $name"
}

echo "==> vendoring tier-2 binaries"
for b in unzip file rsync less xxd git-lfs dig ss nc tcpdump redis-cli \
         ssh ssh-keygen ssh-add ssh-agent scp; do
    p="$(command -v "$b" 2>/dev/null || true)"
    [ -n "$p" ] && vendor "$p" "$b" || echo "    !! $b: not on PATH — skipping" >&2
done

# psql: /usr/bin/psql on Debian/Ubuntu is the pg_wrapper perl script, which
# expects the whole postgresql-common layout. Vendor the real client binary.
PSQL_REAL="$(ls -1 /usr/lib/postgresql/*/bin/psql 2>/dev/null | sort -V | tail -1 || true)"
if [ -n "$PSQL_REAL" ]; then
    vendor "$PSQL_REAL" psql
else
    echo "    !! psql: no /usr/lib/postgresql/*/bin/psql — skipping" >&2
fi

# `file` reads its magic database at runtime; without this it reports
# "could not find any valid magic files". nixie.yml sets MAGIC to this path.
if [ -f /usr/share/misc/magic.mgc ]; then
    install -m 0644 /usr/share/misc/magic.mgc "$ROOTFS/usr/share/misc/magic.mgc"
    echo "    ok magic.mgc"
fi

# node needs libatomic.so.1, which netclaw does not ship. Vendor it and point
# the node binary's RUNPATH at our lib dir as well.
for l in /usr/lib/x86_64-linux-gnu/libatomic.so.1*; do
    [ -e "$l" ] && cp -L "$l" "$LIBDIR/$(basename "$l")" && echo "    ok $(basename "$l")"
done
if [ -x /tools/node/bin/node ]; then
    patchelf --set-rpath '/tools/rootfs/usr/lib' /tools/node/bin/node
    echo "    ok node RUNPATH -> /tools/rootfs/usr/lib"
fi

# Give every vendored library a RUNPATH of its own directory.
#
# This is load-bearing and easy to miss: DT_RUNPATH (what modern patchelf and
# linkers emit) applies ONLY to the direct DT_NEEDED entries of the object that
# carries it — unlike the legacy DT_RPATH, it is NOT inherited by transitive
# dependencies. So setting RUNPATH on `dig` alone lets dig find libisc, but when
# libisc in turn needs libedit.so.2 the loader consults libisc's own RUNPATH
# (empty) and the default paths, never dig's. Result: "libedit.so.2: cannot open
# shared object file" even though we vendored it. Stamping $ORIGIN on each
# library closes the chain.
echo "==> setting RUNPATH on vendored libraries"
for so in "$LIBDIR"/*.so*; do
    [ -f "$so" ] || continue
    patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

# tcpdump: let the unprivileged runtime user (uid 1654) actually capture.
#
# nixie.yml grants the container CAP_NET_RAW, but docker's cap_add only gives
# capabilities to root — a non-root process gets an empty capability set, so
# tcpdump fails with "You don't have permission to perform this capture".
# A file capability on the binary fixes that, but two details bite:
#
#  1. Grant ONLY cap_net_raw. A file capability naming a capability outside the
#     container's bounding set (cap_net_admin is NOT in it — we only added
#     NET_RAW) makes execve itself fail with EPERM, for every user including root.
#  2. File capabilities put glibc into secure-execution mode, where $ORIGIN in
#     RUNPATH is NOT expanded. The $ORIGIN/../lib we set above would silently
#     stop resolving and tcpdump would die on "libpcap.so.0.8: cannot open
#     shared object file". An absolute RUNPATH is still honoured, so use one.
#
# The xattr only survives into the volume because entrypoint.sh rsyncs with -X.
if [ -f "$BINDIR/tcpdump" ]; then
    patchelf --set-rpath "/tools/rootfs/usr/lib" "$BINDIR/tcpdump"
    if setcap cap_net_raw+eip "$BINDIR/tcpdump" 2>/dev/null; then
        echo "    ok tcpdump: absolute RUNPATH + $(getcap "$BINDIR/tcpdump" | awk '{print $2}')"
    else
        echo "    !! tcpdump: setcap failed — capture will need a root docker exec" >&2
    fi
fi

echo "==> tier-2 summary"
echo "    binaries: $(ls -1 "$BINDIR" | wc -l)   libs: $(ls -1 "$LIBDIR" | wc -l)"
