#!/usr/bin/env bash
set -euo pipefail

# --- Memory constraints for the Rust/Tauri release build -----------------
# The Hotline Tauri crate links OpenSSL, aws-lc, ring, libsodium, tokio,
# reqwest, tauri and rustls into a single crate. LLVM's optimizer on that
# crate exceeds the runner's container memory limit even at opt-level=1,
# aborting with "rustc-LLVM ERROR: out of memory". The following pushes
# memory usage to the absolute minimum.
export CARGO_BUILD_JOBS=1
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256
export CARGO_PROFILE_RELEASE_OPT_LEVEL=0
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=false
export CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=false
export CARGO_PROFILE_RELEASE_INCREMENTAL=false
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_PROFILE_RELEASE_STRIP=symbols
export NODE_OPTIONS=--max-old-space-size=2048
export RUSTFLAGS="-C debuginfo=0 -C link-arg=-Wl,--no-keep-memory"
# -------------------------------------------------------------------------

echo "--- Building Hotline Navigator ---"

# Clone the repository.
# AUDIT FIX: the bare `git clone` had no retry; one transient GitHub failure
# aborted the whole image build. Retry with exponential backoff inline so
# this script stays self-contained (BlueBuild runs each script in its own
# layer; /tmp/files is only guaranteed for the repo files/ tree).
rm -rf /tmp/hotline
CLONE_OK=false
for attempt in 1 2 3 4; do
    if git clone --depth 1 https://github.com/fuzzywalrus/hotline.git /tmp/hotline; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: hotline clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf /tmp/hotline
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone hotline after 4 attempts." >&2
    exit 1
fi

# Build the Tauri application
cd /tmp/hotline/hotline-tauri

# Install Node.js dependencies.
# AUDIT FIX: npm install hits the public registry and was equally unprotected;
# give it retries and bounded concurrency.
npm install --no-audit --no-fund --fetch-retries=5 --fetch-retry-max-delay=30000

# Build the frontend and compile the Rust binary.
# We deliberately use --no-bundle: the script only needs the raw binary
# (which it copies to /usr/local/bin below), not the .deb or .AppImage
# packages. Skipping bundling also avoids failures from linuxdeploy, which
# needs FUSE and doesn't work reliably inside the build container.
npx tauri build --target x86_64-unknown-linux-gnu --no-bundle

# The `--target x86_64-unknown-linux-gnu` flag causes Cargo to place the
# binary under target/x86_64-unknown-linux-gnu/release/, not target/release/.
BIN_SRC=""
for candidate in \
    "src-tauri/target/x86_64-unknown-linux-gnu/release/hotline-tauri" \
    "src-tauri/target/release/hotline-tauri"
do
    if [ -f "$candidate" ]; then
        BIN_SRC="$candidate"
        break
    fi
done

if [ -n "$BIN_SRC" ]; then
    cp "$BIN_SRC" /usr/local/bin/hotline-navigator
    chmod +x /usr/local/bin/hotline-navigator
    echo "Hotline Navigator installed to /usr/local/bin/hotline-navigator (from $BIN_SRC)"
else
    echo "Build failed: binary not found in either expected location"
    echo "Contents of src-tauri/target/ (for debugging):"
    ls -R src-tauri/target/ || true
    exit 1
fi

# Create a desktop entry
mkdir -p /usr/share/applications
cat > /usr/share/applications/hotline-navigator.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Hotline Navigator
Comment=A modern Hotline client
Exec=/usr/local/bin/hotline-navigator
Icon=internet-web-browser
Terminal=false
Categories=Network;Chat;
EOF

# Cleanup
cd /
rm -rf /tmp/hotline

echo "--- Hotline Navigator build complete ---"
