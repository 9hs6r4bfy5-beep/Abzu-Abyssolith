#!/usr/bin/env bash
set -euo pipefail

echo "--- Installing icloud-linux ---"

# Clone the repository to a system-wide location.
# AUDIT FIX: bare `git clone` into /usr/local/share/icloud-linux with no
# retry AND no pre-clean. A transient GitHub failure aborted the whole image
# build, and because git refuses to clone into an existing non-empty path, a
# partially-cloned directory would also make any re-run of this layer fail
# deterministically. Clean first, then retry with backoff.
rm -rf /usr/local/share/icloud-linux
CLONE_OK=false
for attempt in 1 2 3 4; do
    if git clone --depth 1 https://github.com/IsmaeelAkram/icloud-linux.git /usr/local/share/icloud-linux; then
        CLONE_OK=true
        break
    fi
    echo "  WARNING: icloud-linux clone failed (attempt ${attempt}/4), retrying in $((attempt * 5))s..." >&2
    rm -rf /usr/local/share/icloud-linux
    sleep $((attempt * 5))
done
if [ "$CLONE_OK" != true ]; then
    echo "ERROR: Failed to clone icloud-linux after 4 attempts." >&2
    exit 1
fi

# Verify the helper actually exists before chmod'ing it -- upstream renamed
# files in the past and a missing icloudctl here would otherwise produce a
# confusing "No such file or directory" from chmod at the end of the log.
if [ ! -f /usr/local/share/icloud-linux/icloudctl ]; then
    echo "ERROR: icloudctl not found in cloned repo; upstream layout changed." >&2
    ls -la /usr/local/share/icloud-linux >&2 || true
    exit 1
fi

# Make the icloudctl helper executable
chmod +x /usr/local/share/icloud-linux/icloudctl

# Create a symlink so it's available on PATH
ln -sf /usr/local/share/icloud-linux/icloudctl /usr/local/bin/icloudctl

echo "--- icloud-linux installed. Run 'icloudctl quickstart ~/iCloud' after first login. ---"
