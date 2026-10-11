#!/usr/bin/env bash
set -euo pipefail

echo "--- Installing Intel Software Development Emulator ---"

# --- Configuration -----------------------------------------------------------
SDE_DIR="/opt/intel-sde"

# AUDIT FIX (residual Intel SDE tarball issue):
# The repo ships a pre-placed tarball at
#   files/system/var/opt/intel-sde/sde-external-10.13.1-2026-07-28-lin.tar.xz
# which ublue-os justfiles copies into the image at
#   /var/opt/intel-sde/
# BEFORE this script runs. The previous hardcoded version/date pinned here was
# 9.58.0-2025-06-16, so the download path silently fetched a DIFFERENT SDE
# release than the one every local build installs from the shipped artifact
# (non-reproducible images). The constants below now match the shipped tarball
# exactly; bump all three together when the artifact is updated.
PREPLACED_STAMP="10.13.1-2026-07-28"   # keep in sync with the shipped tarball
PREFERRED_TARBALL="sde-external-${PREPLACED_STAMP}-lin.tar.xz"

# Verified-live upstream URL for the pinned fallback download:
# https://downloadmirror.intel.com/859732/<tarball> serves SDE 9.58.0
# (HTTP 200). No public mirror is known to serve 10.13.1 yet, so if the
# pre-placed artifact is missing we install the newest *verified-downloadable*
# release and print a loud warning instead of failing on dead URLs.
FALLBACK_VERSION="9.58.0"
FALLBACK_DATE="2025-06-16"
FALLBACK_INTEL_URL="https://downloadmirror.intel.com/859732/sde-external-${FALLBACK_VERSION}-${FALLBACK_DATE}-lin.tar.xz"
FALLBACK_MIRROR_URL="https://github.com/rapidfuzz/intel-sde/releases/download/v${FALLBACK_VERSION}/sde-external-${FALLBACK_VERSION}-${FALLBACK_DATE}-lin.tar.xz"

# --- Prefer the pre-placed tarball under /var/opt/intel-sde ------------------
# Ensure the target directory exists BEFORE cd -------------------------------
mkdir -p "${SDE_DIR}"
cd "${SDE_DIR}"

PREFERRED_PATH=""
if [ -f "/var/opt/intel-sde/${PREFERRED_TARBALL}" ]; then
    PREFERRED_PATH="/var/opt/intel-sde/${PREFERRED_TARBALL}"
elif compgen -G "sde-external-*-lin.tar.xz" > /dev/null; then
    # Any pre-staged archive already sitting in the target dir also counts.
    PREFERRED_PATH="$(readlink -f "$(compgen -G "sde-external-*-lin.tar.xz" | head -n1)")"
fi

if [ -n "${PREFERRED_PATH}" ]; then
    # Pin version/date from the actual pre-placed artifact filename:
    # sde-external-<version>-<yyyy>-<mm>-<dd>-<platform>.tar.xz
    # The date itself contains hyphens, so split on '-' positionally rather
    # than with greedy/reluctant suffix removal.
    _core="$(basename "${PREFERRED_PATH}" .tar.xz)"     # e.g. 10.13.1-2026-07-28-lin
    _core="${_core#sde-external-}"                       # drop prefix
    IFS='-' read -r SDE_VERSION _y _m _d _plat <<< "${_core}" || true
    SDE_DATE="${_y}-${_m}-${_d}"
    echo "Using pre-placed SDE tarball: ${PREFERRED_PATH}"
    echo "  (pinned to version ${SDE_VERSION}, date-stamp ${SDE_DATE}, platform ${_plat})"
    # Stage it under its own basename inside SDE_DIR so later steps use one name.
    PREFERRED_TARBALL="$(basename "${PREFERRED_PATH}")"
    if [ ! -f "${PREFERRED_TARBALL}" ] || [ "${PREFERRED_PATH}" != "${PREFERRED_TARBALL}" ]; then
        cp -f "${PREFERRED_PATH}" "${PREFERRED_TARBALL}"
    fi
    rm -rf /var/opt/intel-sde 2>/dev/null || true
else
    # No pre-placed artifact (e.g. partial checkout / CI without files layer):
    # download the newest verified-available pinned release. This intentionally
    # differs from the shipped 10.13.1 artifact until a live 10.x URL exists --
    # warn loudly so the non-reproducibility is visible, never silent.
    SDE_VERSION="${FALLBACK_VERSION}"
    SDE_DATE="${FALLBACK_DATE}"
    SDE_TARBALL="sde-external-${SDE_VERSION}-${SDE_DATE}-lin.tar.xz"

    echo "WARNING: pre-placed SDE artifact (${PREPLACED_STAMP}) not found in the" >&2
    echo "         image; falling back to downloading SDE ${SDE_VERSION}." >&2
    echo "         The resulting image will NOT match builds that use the" >&2
    echo "         shipped tarball. Update the pinned constants once a live" >&2
    echo "         10.x download URL is confirmed." >&2
    echo "Downloading Intel SDE ${SDE_VERSION} (${SDE_DATE})"

    # Attempt 1: Intel's official mirror (downloadmirror numeric IDs are stable
    # per release; 859732 == 9.58.0, verified HTTP 200).
    echo "  Trying Intel mirror: ${FALLBACK_INTEL_URL}"
    if curl -fL --retry 3 --retry-delay 5 \
         -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36" \
         -o "${SDE_TARBALL}.part" "${FALLBACK_INTEL_URL}" && mv -f "${SDE_TARBALL}.part" "${SDE_TARBALL}"; then
        echo "  Downloaded from Intel mirror successfully."
    else
        rm -f "${SDE_TARBALL}.part"
        echo "  Intel mirror failed. Trying GitHub mirror..."
        if curl -fL --retry 3 --retry-delay 5 \
             -o "${SDE_TARBALL}.part" "${FALLBACK_MIRROR_URL}" && mv -f "${SDE_TARBALL}.part" "${SDE_TARBALL}"; then
            echo "  Downloaded from GitHub mirror successfully."
        else
            rm -f "${SDE_TARBALL}.part"
            echo "ERROR: Failed to download Intel SDE from all sources." >&2
            exit 1
        fi
    fi
    PREFERRED_TARBALL="${SDE_TARBALL}"
fi

# --- Integrity check before extraction ---------------------------------------
# A truncated/corrupt download or a mangled LFS pointer would otherwise blow up
# deep inside tar with a confusing error; fail fast with a clear message.
if ! xz -t "${PREFERRED_TARBALL}" 2>/dev/null; then
    echo "ERROR: SDE tarball '${PREFERRED_TARBALL}' is corrupt or incomplete." >&2
    exit 1
fi

# --- Extract, stripping the top-level directory inside the tarball -----------
# Use the exact staged filename (not a wildcard) so we can never pick up an
# unrelated/stale archive that happens to match the glob.
tar -xJf "${PREFERRED_TARBALL}" --strip-components=1

# --- Clean up the tarball(s) -------------------------------------------------
# Remove only archives, never the extracted toolchain. The old `rm -f
# sde-external-*` glob had no `.tar.xz` suffix guard; keep the suffix explicit.
rm -f sde-external-*.tar.xz sde-external-*.tar.xz.part

# --- Restore executable bits --------------------------------------------------
# justfiles/layer copies do not always preserve the archive's exec mode, and a
# non-executable sde binary would silently pass every earlier step only to fail
# at runtime. Force the bits explicitly before symlinking/verifying.
chmod +x "${SDE_DIR}/sde" "${SDE_DIR}/sde64" 2>/dev/null || true

# --- Make sde / sde64 callable from anywhere ---------------------------------
mkdir -p /usr/local/bin
ln -sf "${SDE_DIR}/sde"   /usr/local/bin/sde
ln -sf "${SDE_DIR}/sde64" /usr/local/bin/sde64

# --- Verify ------------------------------------------------------------------
if [ -x "${SDE_DIR}/sde" ] && [ -x "${SDE_DIR}/sde64" ]; then
    echo "Intel SDE ${SDE_VERSION} installed to ${SDE_DIR}/"
else
    echo "ERROR: Intel SDE installation failed (missing executable launcher)" >&2
    exit 1
fi

echo "--- Intel SDE installation complete ---"
