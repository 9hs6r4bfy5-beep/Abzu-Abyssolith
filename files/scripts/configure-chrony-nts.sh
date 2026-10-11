#!/usr/bin/env bash
set -euo pipefail

echo "--- Applying Abzu chrony NTS configuration ---"

# -----------------------------------------------------------------------------
# AUDIT FIX: files/system/etc/chrony.conf.d/00-abzu-nts.conf ships the NTS
# server line, but Fedora's chronyd reads ONLY /etc/chrony.conf. Drop-in
# directories are honoured only when the main config explicitly `include`s
# them. Until now nothing ever added that include, so the NTS hardening was
# completely inert on shipped images (chrony kept using the default pool).
#
# This script is idempotent and safe to run at build time; it is also wired
# as a first-boot oneshot service so rebases onto newer base images (which
# may re-ship an unmodified /etc/chrony.conf) get re-patched.
# -----------------------------------------------------------------------------

CHRONY_CONF=/etc/chrony.conf
DROPIN_DIR=/etc/chrony.conf.d
INCLUDE_LINE="include ${DROPIN_DIR}/*.conf"

if [ ! -d "$DROPIN_DIR" ]; then
    echo "ERROR: $DROPIN_DIR missing; Abzu drop-ins were not copied by the files module." >&2
    exit 1
fi

if [ ! -f "$CHRONY_CONF" ]; then
    # Immutable image without chrony installed? Create a minimal main config
    # so the drop-ins still take effect if chrony is layered later.
    cat > "$CHRONY_CONF" <<EOF
# Abzu-managed chrony main configuration.
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
${INCLUDE_LINE}
EOF
    echo "  Created $CHRONY_CONF with include directive."
elif grep -qF "$INCLUDE_LINE" "$CHRONY_CONF"; then
    echo "  Include directive already present; nothing to do."
else
    # Append (never overwrite) so distro defaults stay intact and the
    # drop-ins win where they overlap (chrony applies configs in order).
    printf '\n# Added by Abzu: activate drop-in configuration directory.\n%s\n' \
        "$INCLUDE_LINE" >> "$CHRONY_CONF"
    echo "  Appended include directive to $CHRONY_CONF."
fi

# Enable chronyd (systemctl unavailable during image build; use a symlink,
# same pattern as install-apple2pi.sh).
if [ -f /usr/lib/systemd/system/chronyd.service ]; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/chronyd.service \
        /etc/systemd/system/multi-user.target.wants/chronyd.service
    echo "  Enabled chronyd.service."
fi

echo "--- Abzu chrony NTS configuration applied ---"
