#!/usr/bin/env bash
set -euo pipefail

# --- Memory constraints for the Rust release build -----------------------
# Snow's Cargo.toml defaults to opt-level=3, and the upstream build
# instructions suggest LTO=fat. Both are the heaviest possible settings
# for LLVM and cause "rustc-LLVM ERROR: out of memory" on the 16 GB
# GitHub Actions runner. These environment variables override the
# profile settings in Snow's Cargo.toml, because Cargo gives environment
# variables higher precedence than profile definitions.
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
export RUSTFLAGS="-C debuginfo=0 -C link-arg=-Wl,--no-keep-memory"
# -------------------------------------------------------------------------

echo "--- Building Snow Macintosh Emulator ---"

# Clone the Snow repository.
# AUDIT FIX: bare `git clone` with no retry aborted the whole image build on
# a transient GitHub failure. Retry inline with exponential backoff; remove
# the partial destination between attempts so git does not refuse to clone
# into an existing directory.
rm -rf /tmp/snow
CLONE_OK=false
for attempt in 1 2 3 4; do
    if git clone --depth 1 https://github.com/twvd/snow.git /tmp/snow; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: snow clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf /tmp/snow
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone snow after 4 attempts." >&2
    exit 1
fi
cd /tmp/snow

# Build in release mode. We deliberately do NOT pass
# CARGO_PROFILE_RELEASE_LTO=fat on the command line anymore, because
# that inline assignment would override the export above and re-enable
# the memory-hungry fat LTO. The exports above are sufficient; they
# also override Snow's opt-level=3 default from its Cargo.toml.
cargo build -r

# The binary is placed in target/release/snowemu
if [ -f "target/release/snowemu" ]; then
    cp "target/release/snowemu" /usr/local/bin/snowemu
    chmod +x /usr/local/bin/snowemu
    echo "Snow installed to /usr/local/bin/snowemu"
else
    echo "Build failed: snowemu binary not found"
    exit 1
fi

# Create a desktop entry for the GUI
mkdir -p /usr/share/applications
cat > /usr/share/applications/snowemu.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Snow
Comment=Classic Macintosh emulator
Exec=/usr/local/bin/snowemu
Icon=computer
Terminal=false
Categories=System;Emulator;
EOF

# Cleanup
cd /
rm -rf /tmp/snow

echo "--- Snow build complete ---"
