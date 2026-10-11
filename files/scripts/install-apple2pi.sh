#!/usr/bin/env bash
set -euo pipefail

echo "--- Building Apple II Pi (with FUSE 3 fusea2pi) ---"

# -----------------------------------------------------------------------------
# Verify that FUSE 3 development headers are present. They are provided by
# the `fuse3-devel` package, which is installed via the dnf module.
# -----------------------------------------------------------------------------
if [ ! -f /usr/include/fuse3/fuse.h ]; then
    echo "ERROR: FUSE 3 header /usr/include/fuse3/fuse.h not found." >&2
    echo "       Ensure 'fuse3-devel' is installed via the dnf module." >&2
    exit 1
fi
echo "  FUSE 3 header found: /usr/include/fuse3/fuse.h"
echo "  pkg-config path: $(which pkg-config 2>/dev/null || echo 'NOT FOUND')"
echo "  fuse3 cflags: $(pkg-config --cflags fuse3 2>/dev/null || echo 'NOT FOUND')"
echo "  fuse3 libs:   $(pkg-config --libs fuse3 2>/dev/null || echo 'NOT FOUND')"
echo "  fuse3 version: $(pkg-config --modversion fuse3 2>/dev/null || echo 'NOT FOUND')"

# -----------------------------------------------------------------------------
# Clone Apple2Pi.
# AUDIT FIX: single-attempt clone -> retry loop with exponential backoff.
# A transient GitHub failure previously aborted the whole image build here.
# -----------------------------------------------------------------------------
rm -rf /tmp/apple2pi
CLONE_OK=false
for attempt in 1 2 3 4; do
    if git clone --depth 1 https://github.com/dschmenk/apple2pi.git /tmp/apple2pi; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: apple2pi clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf /tmp/apple2pi
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone Apple2Pi after 4 attempts." >&2
    exit 1
fi

cd /tmp/apple2pi

# -----------------------------------------------------------------------------
# Replace the upstream fusea2pi.c and Makefile with our FUSE 3 versions.
# These are stored at /tmp/files/apple2pi/ because BlueBuild bind-mounts
# the repository's files/ directory into /tmp/files during the build.
# -----------------------------------------------------------------------------
FUSEA2PI_SRC="/tmp/files/apple2pi/fusea2pi.c"
MAKEFILE_SRC="/tmp/files/apple2pi/Makefile"

if [ ! -f "$FUSEA2PI_SRC" ]; then
    echo "ERROR: Ported fusea2pi.c not found at $FUSEA2PI_SRC" >&2
    exit 1
fi
if [ ! -f "$MAKEFILE_SRC" ]; then
    echo "ERROR: Ported Makefile not found at $MAKEFILE_SRC" >&2
    exit 1
fi

cp "$FUSEA2PI_SRC" /tmp/apple2pi/src/fusea2pi.c
cp "$MAKEFILE_SRC" /tmp/apple2pi/src/Makefile
echo "  Replaced src/fusea2pi.c and src/Makefile with FUSE 3 versions"

# -----------------------------------------------------------------------------
# Build. The Makefile builds all targets, including fusea2pi.
# -----------------------------------------------------------------------------
echo "  Building..."
make -C src

# -----------------------------------------------------------------------------
# Verify that fusea2pi was actually produced and links against FUSE 3.
# -----------------------------------------------------------------------------
if [ ! -x /tmp/apple2pi/src/fusea2pi ]; then
    echo "ERROR: fusea2pi was not produced by the build." >&2
    ls -la /tmp/apple2pi/src/ >&2
    exit 1
fi

echo "  fusea2pi built successfully."
echo "  Linked libraries:"
ldd /tmp/apple2pi/src/fusea2pi | grep -E 'fuse|pthread' || true

# -----------------------------------------------------------------------------
# Install binaries and share files.
# AUDIT FIX: the replacement Makefile now honours PREFIX (default
# /usr/local). Pin it explicitly so an environment-level PREFIX leak from
# another build stage cannot silently redirect the a2pi binaries elsewhere
# and break the a2pi.service unit paths.
# -----------------------------------------------------------------------------
echo "  Installing..."
make -C src install PREFIX=/usr/local

# -----------------------------------------------------------------------------
# Install and enable a2pi.service.
#
# Two symlinks are required:
#   1. /etc/systemd/system/a2pi.service
#      Makes the unit discoverable to systemd.
#   2. /etc/systemd/system/multi-user.target.wants/a2pi.service
#      Enables the unit so it starts at boot. This is exactly what
#      `systemctl enable a2pi.service` would create.
#
# We create these manually because `systemctl` cannot run inside the
# BlueBuild build container (no running systemd).
#
# AUDIT FIX: the previous check only looked for /usr/share/a2pi/a2pi.service
# and merely WARNED when it was missing -- so a silent loss of the service
# (upstream file rename/removal) shipped an image where a2pid never started.
# Search both known locations; if none exists, ship our own fallback unit so
# the feature never silently disappears, and fail loudly if even the
# fallback cannot be written.
# -----------------------------------------------------------------------------
A2PI_UNIT=""
for candidate in /usr/share/a2pi/a2pi.service /usr/lib/systemd/system/a2pi.service \
                 /usr/local/lib/systemd/system/a2pi.service; do
    if [ -f "$candidate" ]; then
        A2PI_UNIT="$candidate"
        break
    fi
done

if [ -z "$A2PI_UNIT" ]; then
    echo "  NOTE: upstream a2pi.service not found in any known location;" >&2
    echo "        writing Abzu fallback unit to /usr/share/a2pi/a2pi.service" >&2
    mkdir -p /usr/share/a2pi
    cat > /usr/share/a2pi/a2pi.service <<'UNIT'
[Unit]
Description=Apple II Pi daemon (a2pid)
After=multi-user.target

[Service]
ExecStart=/usr/local/sbin/a2pid
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
    A2PI_UNIT=/usr/share/a2pi/a2pi.service
fi

ln -sf "$A2PI_UNIT" /etc/systemd/system/a2pi.service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf "$A2PI_UNIT" \
    /etc/systemd/system/multi-user.target.wants/a2pi.service
echo "  Installed /etc/systemd/system/a2pi.service (from $A2PI_UNIT)"
echo "  Enabled  /etc/systemd/system/multi-user.target.wants/a2pi.service"

echo "--- Apple II Pi built and installed (fusea2pi included) ---"
