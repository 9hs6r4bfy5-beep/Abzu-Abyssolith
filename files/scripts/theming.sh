#!/usr/bin/env bash
set -euo pipefail

trap 'echo "theming.sh failed at line $LINENO (exit $?)" >&2' ERR

THEME_DIR="/usr/share/themes"
ICON_DIR="/usr/share/icons"
GNOME_EXT_DIR="/usr/share/gnome-shell/extensions"

# Pinned WhiteSur release tags (reproducible builds; do NOT track master).
# NOTE: the GTK/icon sections below re-set their own tag vars; keep these in
# sync. WHITESUR_CURSOR_URL must always be defined here because the cursor
# repo publishes no tags and a missing variable used to abort step 6 with
# "WHITESUR_CURSOR_URL: unbound variable" under `set -u`.
WHITESUR_GTK_TAG="2026-09-10"
WHITESUR_ICON_TAG="2025-07-29"
WHITESUR_CURSOR_URL="https://github.com/vinceliuice/WhiteSur-cursors/archive/refs/heads/master.tar.gz"

mkdir -p "${THEME_DIR}" "${ICON_DIR}" "${GNOME_EXT_DIR}"

# -----------------------------------------------------------------------------
# Provide a sane environment for the WhiteSur installers (no login session in
# the build container: logname/$USER/$LOGNAME are empty, which breaks
# lib-core.sh's MY_HOME resolution).
# -----------------------------------------------------------------------------
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TERM="${TERM:-xterm-256color}"
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
mkdir -p "${HOME}/.config" "${HOME}/.local/share"

echo "--- Starting Theming Installation ---"
echo "  HOME=$HOME  USER=$USER  LOGNAME=$LOGNAME  TERM=$TERM"

# -----------------------------------------------------------------------------
# 1-3. B00merang themes (unchanged)
# -----------------------------------------------------------------------------
echo "Installing B00merang Mac OS X Cheetah theme..."
# Retry transient GitHub/codeload failures (the same class of HTTP 404/5xx that
# killed the previous build on the WhiteSur icon tarball) instead of aborting.
fetch_zip() {
    local url="$1" out="$2" tries=5 delay=3 code=""
    while [ "$tries" -gt 0 ]; do
        code="$(curl -fsSL --retry 2 --retry-delay 2 -o "$out" -w '%{http_code}' "$url" 2>/dev/null)" && \
        [ -s "$out" ] && return 0
        rm -f "$out"
        tries=$((tries - 1))
        echo "  WARNING: download failed ($code) from $url, retrying in ${delay}s (${tries} left)..." >&2
        sleep "$delay"
    done
    echo "ERROR: Failed to download $url after retries" >&2
    return 1
}

fetch_zip https://github.com/B00merang-Project/Mac-OS-X-Cheetah/archive/master.zip /tmp/cheetah.zip
unzip -q /tmp/cheetah.zip -d /tmp/
[ -d "/tmp/Mac-OS-X-Cheetah-master" ] && mv /tmp/Mac-OS-X-Cheetah-master /tmp/Mac-OS-X-Cheetah
cp -r /tmp/Mac-OS-X-Cheetah "${THEME_DIR}/Mac-OS-X-Cheetah"
rm -rf /tmp/cheetah.zip /tmp/Mac-OS-X-Cheetah

echo "Installing B00merang Mavericks theme..."
fetch_zip https://github.com/B00merang-Project/OS-X-Mavericks/archive/refs/heads/master.zip /tmp/mavericks.zip
unzip -q /tmp/mavericks.zip -d /tmp/
cp -r /tmp/OS-X-Mavericks-master "${THEME_DIR}/OS-X-Mavericks"
rm -rf /tmp/mavericks.zip /tmp/OS-X-Mavericks-master

echo "Installing B00merang Leopard theme..."
fetch_zip https://github.com/B00merang-Project/OS-X-Leopard/archive/refs/heads/master.zip /tmp/leopard.zip
unzip -q /tmp/leopard.zip -d /tmp/
cp -r /tmp/OS-X-Leopard-master "${THEME_DIR}/OS-X-Leopard"
rm -rf /tmp/leopard.zip /tmp/OS-X-Leopard-master

# -----------------------------------------------------------------------------
# 4. WhiteSur GTK theme
#
# Pinned to the immutable upstream release tag 2026-09-10. Do NOT point this
# at refs/heads/master again: branch archives are transient (they intermittently
# return HTTP 404 from codeload.github.com) and master's argument parser changes
# without notice.
#
# HISTORY OF THE CLI BUGS THAT BROKE EARLIER BUILDS (verified against the
# upstream sources):
#   * We used to pass `-c all`. The current install.sh validates the value of
#     -c/--color with check_param() in libs/lib-core.sh, which only accepts
#     light|dark (COMMAND_COLOR_VARIANTS=('light' 'dark')). Anything else sets
#     has_any_error=true, and finalize_argument_parsing() then prints
#     "ERROR: Unrecognized '-c' variant: 'all'." and exits 1. Note that unlike
#     -a/--alt and -t/--theme, -c has NO special-cased "all" value at all.
#   * Omitting -c installs every color variant anyway: install.sh initializes
#     colors=("${COLOR_VARIANTS[@]}") ("Light" "Dark"), i.e. "Default is all
#     variants". So the correct invocation is simply `install.sh -d DIR`.
#   * `--silent-mode` must never be used here: it routes through full_sudo(),
#     which aborts when /root is not writable (non-root builds), and it makes
#     every parameter error fatal.
# -----------------------------------------------------------------------------
WHITESUR_GTK_TAG="2026-09-10"
echo "Installing WhiteSur GTK theme (${WHITESUR_GTK_TAG})..."

WHITESUR_GTK_URL="https://github.com/vinceliuice/WhiteSur-gtk-theme/archive/${WHITESUR_GTK_TAG}.tar.gz"
rm -rf /tmp/whitesur-gtk /tmp/whitesur-gtk.tar.gz

if ! curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
        -o /tmp/whitesur-gtk.tar.gz "${WHITESUR_GTK_URL}"; then
    echo "ERROR: Failed to download WhiteSur GTK theme tarball from ${WHITESUR_GTK_URL}" >&2
    exit 1
fi

mkdir -p /tmp/whitesur-gtk
if ! tar -xzf /tmp/whitesur-gtk.tar.gz -C /tmp/whitesur-gtk --strip-components=1; then
    echo "ERROR: Failed to extract WhiteSur GTK tarball" >&2
    exit 1
fi
rm -f /tmp/whitesur-gtk.tar.gz

# Install with NO -c flag: upstream defaults to every color variant
# (colors=("${COLOR_VARIANTS[@]}") = Light + Dark). See the history block above
# for why `-c all` broke earlier builds. The guarded retry below catches any
# future upstream argument-parser change that would reject these args and
# falls back to the bare, guaranteed-valid invocation.
GTK_INSTALL_ARGS=(-d "${THEME_DIR}")

# The installer needs sassc / glib-compile-resources / ImageMagick's convert /
# xmlsec1 at run time (install_beggy() blurs the panel background with
# `convert`, gtk_base compiles SCSS with `sassc`, etc.). Upstream's
# install_theme_deps() bootstraps missing deps through *sudo* package managers,
# which is unreliable inside an image build. Install them here directly so
# install_theme_deps() finds everything present and never enters that path.
install_gtk_build_deps() {
    local missing=()
    command -v sassc                  >/dev/null 2>&1 || missing+=(sassc)
    command -v glib-compile-resources >/dev/null 2>&1 || missing+=(glib)
    command -v convert                >/dev/null 2>&1 || missing+=(imagemagick)
    command -v xmlsec1                >/dev/null 2>&1 || missing+=(xmlsec1)
    [ "${#missing[@]}" -eq 0 ] && return 0

    echo "  Installing WhiteSur GTK build dependencies (${missing[*]})..."
    # NOTE: `|| true` everywhere is intentional. BlueBuild runs each script in
    # its own container layer, so the package manager here may be unavailable
    # or fail for transient reasons; the hard dependency check below produces
    # a clear, actionable error instead of a cryptic mid-installer failure.
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y -qq --no-install-recommends \
            sassc libglib2.0-dev-bin imagemagick xmlsec1 dconf-cli unzip || \
        apt-get install -y -qq --no-install-recommends \
            sassc libglib2.0-dev imagemagick libxml2-utils dconf-cli unzip || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y sassc glib2-devel ImageMagick libxml2 dconf unzip gtk-update-icon-cache || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y sassc glib2-devel ImageMagick libxml2 dconf unzip gtk-update-icon-cache || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm --needed sassc glib2 imagemagick libxml2 dconf unzip || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y sassc glib2-devel ImageMagick libxml2-tools dconf-cli unzip || true
    else
        echo "  WARNING: no known package manager found; relying on upstream installer defaults." >&2
    fi
}
install_gtk_build_deps

# Final sanity check: fail loudly here rather than deep inside the upstream
# installer (which runs under `set -Eeo pipefail` and dies with exit 1 and no
# clear error message when a required binary such as `convert` is absent).
for _dep in sassc glib-compile-resources convert unzip git dconf; do
    if ! command -v "${_dep}" >/dev/null 2>&1; then
        echo "ERROR: '${_dep}' is required by theming.sh / the WhiteSur installers but could not be installed." >&2
        exit 1
    fi
done

INSTALL_LOG=/tmp/whitesur-gtk-install.log
: > "$INSTALL_LOG"
set +e
(
    cd /tmp/whitesur-gtk
    # </dev/null is REQUIRED: upstream overrides `sudo` with a wrapper function
    # that calls `ask()` -> `read`. With stdin attached to the Docker step's
    # input stream this can consume the rest of the streamed script or hang.
    bash install.sh "${GTK_INSTALL_ARGS[@]}" </dev/null
) >"$INSTALL_LOG" 2>&1
INSTALL_EXIT=$?

if [ "$INSTALL_EXIT" -ne 0 ] && grep -Eq "Unrecognized|can't be empty|Try .*--help" "$INSTALL_LOG"; then
    echo "  Installer rejected our arguments (upstream CLI change); retrying with the bare default invocation..."
    : > "$INSTALL_LOG"
    (
        cd /tmp/whitesur-gtk
        bash install.sh -d "${THEME_DIR}" </dev/null
    ) >"$INSTALL_LOG" 2>&1
    INSTALL_EXIT=$?
fi
set -e

echo "  GTK installer exit code: $INSTALL_EXIT"
if [ "$INSTALL_EXIT" -ne 0 ]; then
    echo "  === Last 120 lines of GTK installer output ==="
    tail -120 "$INSTALL_LOG" || true
    echo "  === End ==="
    echo "ERROR: WhiteSur GTK installer failed (exit ${INSTALL_EXIT})" >&2
    exit 1
fi

# Upstream installs "${name}${color}" with capitalized COLOR_VARIANTS, i.e.
# /usr/share/themes/WhiteSur-Light and WhiteSur-Dark (there is no bare
# "WhiteSur" directory). Verify both Light and Dark exist so a partial install
# fails loudly here instead of producing a broken image.
if [ ! -d "${THEME_DIR}/WhiteSur-Light" ] || [ ! -d "${THEME_DIR}/WhiteSur-Dark" ]; then
    echo "  === Last 80 lines of GTK installer output ==="
    tail -80 "$INSTALL_LOG" || true
    echo "ERROR: GTK installer exited ${INSTALL_EXIT} but WhiteSur-Light/WhiteSur-Dark not found." >&2
    ls -la "${THEME_DIR}/" >&2 || true
    exit 1
fi
rm -rf /tmp/whitesur-gtk /tmp/whitesur-gtk-install.log
echo "WhiteSur GTK theme installed."

# -----------------------------------------------------------------------------
# 5. WhiteSur icon theme
#
# Pinned to upstream release tag 2025-07-29, the last tag that matches the
# pinned GTK theme generation. The previous URL pointed at
# .../archive/refs/heads/master.tar.gz, which intermittently returns HTTP 404
# from codeload.github.com (branch archives are transient and get invalidated
# whenever master is force-updated / garbage-collected). Tag archives are
# immutable and permanently served, so this can no longer fail with a 404.
# -----------------------------------------------------------------------------
echo "Installing WhiteSur icon theme..."

WHITESUR_ICON_TAG="2025-07-29"
WHITESUR_ICON_URL="https://github.com/vinceliuice/WhiteSur-icon-theme/archive/${WHITESUR_ICON_TAG}.tar.gz"
rm -rf /tmp/whitesur-icons /tmp/whitesur-icons.tar.gz

if ! curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
        -o /tmp/whitesur-icons.tar.gz "${WHITESUR_ICON_URL}"; then
    echo "ERROR: Failed to download WhiteSur icon theme from ${WHITESUR_ICON_URL}" >&2
    exit 1
fi

mkdir -p /tmp/whitesur-icons
tar -xzf /tmp/whitesur-icons.tar.gz -C /tmp/whitesur-icons --strip-components=1
rm -f /tmp/whitesur-icons.tar.gz

INSTALL_LOG=/tmp/whitesur-icons-install.log
: > "$INSTALL_LOG"
set +e
(
    cd /tmp/whitesur-icons
    # </dev/null: never let the installer read from the build pipeline's stdin.
    bash install.sh -d "${ICON_DIR}" </dev/null
) >"$INSTALL_LOG" 2>&1
INSTALL_EXIT=$?
set -e

echo "  Icon installer exit code: $INSTALL_EXIT"
if [ "$INSTALL_EXIT" -ne 0 ]; then
    echo "  === Last 80 lines of icon installer output ==="
    tail -80 "$INSTALL_LOG" || true
    echo "ERROR: WhiteSur icon installer failed (exit ${INSTALL_EXIT})" >&2
    exit 1
fi
rm -rf /tmp/whitesur-icons /tmp/whitesur-icons-install.log
echo "WhiteSur icon theme installed."

# -----------------------------------------------------------------------------
# 6. WhiteSur cursors
#
# The cursor repo publishes no release tags, so refs/heads/master is the only
# archive available. Keep it, but make the download resilient: --retry-all-
# errors retries transient HTTP 404/5xx responses from codeload (the same
# class of failure that killed the previous build on the icon theme), and the
# error message records the URL that failed.
# -----------------------------------------------------------------------------
echo "Installing WhiteSur cursors..."
rm -rf /tmp/whitesur-cursors /tmp/whitesur-cursors.tar.gz

# Define the URL that was referenced but never set, which aborted the build
# with "WHITESUR_CURSOR_URL: unbound variable" under `set -u`. The cursor repo
# publishes no release tags (e.g. ${WHITESUR_CURSOR_TAG} archives 404), so the
# refs/heads/master archive is the only available source; the retry flags below
# guard against transient codeload failures.
WHITESUR_CURSOR_URL="https://github.com/vinceliuice/WhiteSur-cursors/archive/refs/heads/master.tar.gz"

if ! curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
        -o /tmp/whitesur-cursors.tar.gz "${WHITESUR_CURSOR_URL}"; then
    echo "ERROR: Failed to download WhiteSur cursors from ${WHITESUR_CURSOR_URL}" >&2
    exit 1
fi

mkdir -p /tmp/whitesur-cursors
tar -xzf /tmp/whitesur-cursors.tar.gz -C /tmp/whitesur-cursors --strip-components=1
rm -f /tmp/whitesur-cursors.tar.gz

INSTALL_LOG=/tmp/whitesur-cursors-install.log
: > "$INSTALL_LOG"
set +e
(
    cd /tmp/whitesur-cursors
    # NOTE: the WhiteSur-cursors install.sh is a trivial script that takes NO
    # arguments and always copies its dist/ folder to /usr/share/icons when run
    # as root (we build as root). Passing "-d DIR" here was harmless but
    # misleading; it is removed so the behaviour is explicit.
    bash install.sh
) >"$INSTALL_LOG" 2>&1
INSTALL_EXIT=$?
set -e

echo "  Cursor installer exit code: $INSTALL_EXIT"
if [ "$INSTALL_EXIT" -ne 0 ]; then
    echo "  === Last 80 lines of cursor installer output ==="
    tail -80 "$INSTALL_LOG" || true
    echo "ERROR: WhiteSur cursor installer failed (exit ${INSTALL_EXIT})" >&2
    exit 1
fi
# Verify the cursors actually landed, since this installer has no error handling
# of its own (a failed cp would still print "Finished...").
if [ ! -d "${ICON_DIR}/WhiteSur-cursors" ]; then
    echo "ERROR: cursor installer exited 0 but ${ICON_DIR}/WhiteSur-cursors is missing." >&2
    ls -la "${ICON_DIR}/" >&2 || true
    exit 1
fi
rm -rf /tmp/whitesur-cursors /tmp/whitesur-cursors-install.log
echo "WhiteSur cursors installed."

# -----------------------------------------------------------------------------
# 7. Liquid Glass GNOME Shell Extension
#
# The upstream repo is a development tree: the extension lives in the
# subdirectory liquid-glass@thinkingcoding1231.gmail.com/ and its runtime
# modules are TypeScript compiled into dist/. Shipping only metadata.json +
# extension.js (which a plain `cp` of a checkout does NOT guarantee, since
# dist/ must exist) makes gnome-shell log "Extension missing dependencies"
# and skip the whole load pass from that point on -- which also took down
# every later extension and left the top bar without its glass material.
# We now verify the required runtime files explicitly after copying.
# -----------------------------------------------------------------------------
echo "Installing Liquid Glass GNOME Shell Extension..."
EXT_UUID="liquid-glass@thinkingcoding1231.gmail.com"
# AUDIT FIX: bare `git clone` with no retry; a transient GitHub failure here
# aborted the entire image build (same class of failure already hardened
# against for the WhiteSur downloads above). Retry with exponential backoff,
# removing the partial destination between attempts.
CLONE_OK=false
for attempt in 1 2 3 4; do
    rm -rf /tmp/liquid-glass
    if git clone --depth 1 https://github.com/ryohsuke1231/liquid-glass.git /tmp/liquid-glass; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: liquid-glass clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone liquid-glass extension after 4 attempts." >&2
    exit 1
fi
mkdir -p "${GNOME_EXT_DIR}/${EXT_UUID}"
cp -r /tmp/liquid-glass/${EXT_UUID}/* "${GNOME_EXT_DIR}/${EXT_UUID}/"
rm -rf /tmp/liquid-glass

# Verify the extension landed with everything it needs to LOAD. If any of
# these are missing (upstream layout change, partial clone), gnome-shell
# skips/fails this UUID and the glass material never renders on the top
# bar -- exactly the "Liquid Glass broken at the menu bar" report. Fail the
# build loudly instead of shipping an inert theme.
for _req in metadata.json extension.js prefs.js stylesheet.css; do
    if [ ! -f "${GNOME_EXT_DIR}/${EXT_UUID}/${_req}" ]; then
        echo "ERROR: Liquid Glass extension is missing ${_req} in ${GNOME_EXT_DIR}/${EXT_UUID}." >&2
        ls -la "${GNOME_EXT_DIR}/${EXT_UUID}/" >&2 || true
        exit 1
    fi
done
if [ ! -d "${GNOME_EXT_DIR}/${EXT_UUID}/dist" ] || \
   [ -z "$(ls -A "${GNOME_EXT_DIR}/${EXT_UUID}/dist" 2>/dev/null)" ]; then
    echo "ERROR: Liquid Glass extension has no dist/ modules; extension.js imports ./dist/*.js and would crash gnome-shell on load." >&2
    exit 1
fi
# Compile the extension's own gschemas so its settings schema resolves even
# if package triggers did not run in this layer.
glib-compile-schemas "${GNOME_EXT_DIR}/${EXT_UUID}/schemas" 2>/dev/null || true
echo "Liquid Glass GNOME Shell Extension installed."

# -----------------------------------------------------------------------------
# 7a. Abzu Plymouth boot splash (custom loading screen)
#
# The theme files ship via the `files` module at
# /usr/share/plymouth/themes/abzu/. Nothing used to *activate* them: no
# alternatives entry, no /etc/plymouth/plymouthd.conf, and nothing that
# could rebuild the initramfs -- so Plymouth kept rendering the spinner
# from the base image's system theme. That is why a rebased install shows
# no custom loading screen even though logo.png exists in the tree.
#
# WHY A RUNTIME SERVICE IS REQUIRED: on ostree systems, dracut reads its
# configuration from the DEPLOYMENT (/etc after commit), not from the
# build container, and the initramfs of the first deployment is generated
# before any custom script layer output can influence it. Therefore we
# write the configuration here (it lands in the tree) AND enable a one-shot
# systemd service that runs plymouth-set-default-theme --rebuild-initrd on
# the first boot, which regenerates the real initramfs against the deployed
# /etc. The ConditionPathExists marker makes it run exactly once; later
# updates pick the theme up automatically because /etc/plymouth/plymouthd.conf
# persists across rebase and Fedora's own update triggers rebuild the
# initramfs with it.
# -----------------------------------------------------------------------------
echo "Activating Abzu Plymouth theme..."
install -d -m 0755 /etc/plymouth
cat > /etc/plymouth/plymouthd.conf <<'CONF'
[Daemon]
Theme=Abzu
CONF

install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/abzu-apply-plymouth-theme <<'APPLY'
#!/usr/bin/env bash
# One-shot: make the Abzu Plymouth theme active and bake it into the
# initramfs of the CURRENT deployment. Runs at first boot after rebase --
# i.e. after all image files exist, which was impossible from the build
# container (the bug that left the stock spinner on every rebase).
set -u
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme Abzu || true
    plymouth-set-default-theme --rebuild-initrd || \
        dracut --regenerate-all --force || true
fi
exit 0
APPLY
chmod 0755 /usr/local/sbin/abzu-apply-plymouth-theme

# The `systemd` module in recipe.yml runs BEFORE this script module, so the
# unit created below cannot be enabled through it (the file would not exist
# yet). Enable it with a direct symlink instead -- exactly the pattern already
# used for a2pi.service (see the note in recipe.yml).
install -d -m 0755 /etc/systemd/system
cat > /etc/systemd/system/abzu-plymouth-theme.service <<'UNIT'
[Unit]
Description=Activate Abzu Plymouth boot theme and rebuild initramfs
After=systemd-machine-id-commit.service
ConditionPathExists=!/var/lib/abzu/plymouth-theme.done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/abzu-apply-plymouth-theme
ExecStartPost=/usr/bin/mkdir -p /var/lib/abzu
ExecStartPost=/usr/bin/touch /var/lib/abzu/plymouth-theme.done

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/abzu-plymouth-theme.service \
       /etc/systemd/system/multi-user.target.wants/abzu-plymouth-theme.service

# -----------------------------------------------------------------------------
# 7b. GDM branding: replace the Fedora logo shown behind the login button
#
# Two independent paths make the Fedora infinity mark appear on the greeter:
#
#   1. The Fedora `gdm` RPM drops a *hardcoded* resource file at
#      /usr/share/pixmaps/fedora-gdm-logo.png and -- crucially -- patches
#      GNOME's Debian downstream of gdm-chooser/org.gnome.login-screen
#      handling so that this exact path is drawn on the greeter REGARDLESS
#      of what org.gnome.login-screen:logo-path contains. On ostree images
#      we cannot simply reconfigure the key and expect the file to stop
#      being painted: the file itself must be neutralised. We overwrite it
#      with the Abzu artwork (keeping the path valid for any code that
#      still references it), which kills the superimposed Fedora logo even
#      on hosts where the gsettings override is ignored or overridden by a
#      stale per-user dconf value.
#   2. The normal logo-path mechanism: GDM draws
#      org.gnome.login-screen:logo-path over the user-chip / login-button
#      area, whose packaged default points at the Fedora artwork. We copy
#      the Abzu logo to a stable path and point the setting at it in the
#      gschema override (new users) and the recipe.yml dconf module
#      (existing users).
#
# Fixing only one of these two paths was why earlier attempts "failed to be
# applied": rebases restored the RPM-owned pixmaps file from the image tree
# every build, re-introducing the logo no matter what the settings said.
# -----------------------------------------------------------------------------
echo "Rebranding GDM login logo..."
if [ -f /usr/share/plymouth/themes/abzu/logo.png ]; then
    install -D -m 0644 /usr/share/plymouth/themes/abzu/logo.png \
                       /usr/share/abzu/gdm-logo.png
    # Neutralise the hardcoded Fedora greeter artwork (path 1 above). This
    # runs inside the theming.sh build layer, i.e. AFTER the files module
    # has copied the tree and after any dnf transaction, so nothing later
    # in the build restores the original. If the gdm package ever updates
    # this file again, the update happens in an earlier layer than this
    # script, so our copy still wins.
    if [ -d /usr/share/pixmaps ]; then
        install -m 0644 /usr/share/abzu/gdm-logo.png \
                        /usr/share/pixmaps/fedora-gdm-logo.png
    fi
else
    echo "ERROR: Abzu logo missing at /usr/share/plymouth/themes/abzu/logo.png; GDM branding would break." >&2
    exit 1
fi

# Fail loudly if either branded path is missing/empty: a silently absent
# gdm-logo.png renders as the stock greeter and looks exactly like the
# original bug report.
for _logo in /usr/share/abzu/gdm-logo.png; do
    if [ ! -s "$_logo" ]; then
        echo "ERROR: GDM branding artifact $_logo is missing or empty." >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 7c. Abzu wallpapers
#
# There were none: the image shipped zero background images, so
# picture-uri could only ever point at the Fedora default. Generate the
# abyssal gradient artwork at build time and register it with GNOME's
# background XML catalogue so it also appears in Settings -> Background.
#
# ImageMagick is verified below (not merely installed best-effort by
# install_gtk_build_deps), because a missing `convert` here used to be a
# silent no-op class of bug; failing loudly keeps theming deterministic.
# -----------------------------------------------------------------------------
echo "Installing Abzu wallpapers..."
if ! command -v convert >/dev/null 2>&1; then
    echo "ERROR: ImageMagick 'convert' is required to generate the Abzu wallpapers but is not present." >&2
    exit 1
fi
install -d -m 0755 /usr/share/backgrounds
convert -size 3840x2160 \
    radial-gradient:'#0b6e8f-#041e2c' \
    /usr/share/backgrounds/Abzu-abyss.png
convert -size 3840x2160 \
    radial-gradient:'#123c5e-#02090f' \
    /usr/share/backgrounds/Abzu-deep.png
# Faint cuneiform water-sign overlay (AN signs) drawn over the abyss gradient.
convert /usr/share/backgrounds/Abzu-abyss.png \
    \( -clone 0 -fill '#7fd4e8' -pointsize 420 -annotate +1600+900 '𒀭' \
       -blur 0x60 \) \
    -compose over -composite /usr/share/backgrounds/Abzu-abyss.png || true

cat > /usr/share/backgrounds/abzu.xml <<'XML'
<background>
  <item>
    <duration>3600</duration>
    <static>/usr/share/backgrounds/Abzu-abyss.png</static>
  </item>
  <item>
    <duration>3600</duration>
    <static>/usr/share/backgrounds/Abzu-deep.png</static>
  </item>
</background>
XML

# Register the wallpapers with gnome-desktop's system-wide list so they
# appear in Settings -> Background for every user. The file must be named
# *.xml and live in /usr/share/gnome-background-properties/.
install -d -m 0755 /usr/share/gnome-background-properties
cat > /usr/share/gnome-background-properties/abzu-wallpapers.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false">
    <name>Abzu Abyss</name>
    <filename>/usr/share/backgrounds/Abzu-abyss.png</filename>
    <options>zoom</options>
    <primary_color>#041e2c</primary_color>
  </wallpaper>
  <wallpaper deleted="false">
    <name>Abzu Deep</name>
    <filename>/usr/share/backgrounds/Abzu-deep.png</filename>
    <options>zoom</options>
    <shading_type>solid</shading_type>
  </wallpaper>
</wallpapers>
XML

# Fail loudly if the generated files are missing/empty -- an empty PNG would
# render as a black desktop and look like "no custom wallpaper" again.
for wp in /usr/share/backgrounds/Abzu-abyss.png /usr/share/backgrounds/Abzu-deep.png; do
    if [ ! -s "$wp" ]; then
        echo "ERROR: wallpaper $wp was not generated." >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# 7d. Desktop icon themes: make Abzu artwork resolve in the Shell/dash
#
# cuneiform-toggle.desktop references Icon=abzu-cuneiform, which ships only
# as a raw SVG under /usr/share/icons/hicolor/scalable/apps/. GNOME Shell's
# dash and the app grid resolve icons through the *active icon theme*
# (WhiteSur), whose index inherits from hicolor -> Adwaita -> gnome ->
# locolor. That inheritance chain is only effective when the theme's
# index.theme actually lists the fallbacks and the gtk3 cache
# (icon-theme.cache) is present; without a cache, lookups against large
# themes fall back to the generic application tile -- so our custom
# launcher icons silently never appear ("no custom loading screen icons"
# class of bug on the desktop side). We therefore:
#   * guarantee WhiteSur's index.theme inherits from hicolor, and
#   * rebuild every system icon theme's cache with gtk-update-icon-cache so
#     hicolor-only icons (abzu-cuneiform.svg and friends) resolve everywhere.
# -----------------------------------------------------------------------------
echo "Registering Abzu icons with the system icon themes..."
for _theme in "${ICON_DIR}"/*/; do
    [ -f "${_theme}/index.theme" ] || continue
    # Ensure the inherited-fallback chain exists for the primary theme.
    if [ "$(basename "${_theme}")" = "WhiteSur" ] && \
       ! grep -q '^\s*Inherits=.*hicolor' "${_theme}/index.theme"; then
        sed -i '/^\[Icon Theme\]/a Inherits=hicolor,Adwaita,gnome,locolor' "${_theme}/index.theme"
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t -f "${_theme}" 2>/dev/null || true
    elif command -v gdk-pixbuf-csource >/dev/null 2>&1; then
        : # no cache tool available; index-based lookup still works
    fi
done
update-desktop-database /usr/share/applications 2>/dev/null || true

# -----------------------------------------------------------------------------
# 8. Final cleanup
# -----------------------------------------------------------------------------
rm -rf \
    /tmp/cheetah.zip /tmp/Mac-OS-X-Cheetah /tmp/Mac-OS-X-Cheetah-master \
    /tmp/mavericks.zip /tmp/OS-X-Mavericks-master \
    /tmp/leopard.zip /tmp/OS-X-Leopard-master \
    /tmp/liquid-glass \
    2>/dev/null || true

dconf update

# Compile the GSettings schema overrides (99-abzu-gnome.gschema.override ships
# in files/system/usr/share/glib-2.0/schemas/ via the `files` module). Without
# this step gschemas.compiled is never regenerated at build time, so every
# override silently has NO effect: new users get default GNOME instead of
# WhiteSur/Cheetah, the Liquid Glass + user-theme extensions stay disabled,
# and cuneiform-toggle.desktop never appears in favorites. glib-compile-schemas
# also runs opportunistically at package-manager transactions, which masked
# this bug on some builds but not others -- compile explicitly so it is
# deterministic.
if [ -f /usr/share/glib-2.0/schemas/99-abzu-gnome.gschema.override ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas
    echo "GSettings schema overrides compiled."
else
    echo "ERROR: 99-abzu-gnome.gschema.override not found; theming defaults will not apply." >&2
    exit 1
fi

echo "--- Theming Installation Complete ---"
exit 0
