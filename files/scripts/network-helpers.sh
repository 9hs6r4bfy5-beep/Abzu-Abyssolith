#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Shared network-resilience helpers for the Abzu build scripts.
#
# Rationale (audit): every `git clone` / release download in files/scripts/
# previously ran with zero retries. A single transient GitHub/codeload hiccup
# -- exactly the failure class that killed earlier builds on the WhiteSur
# downloads -- aborted the entire ISO/image build. BlueBuild executes each
# script module in its own layer, so these helpers must be self-contained per
# script; source this file from any script that needs them:
#
#   # shellcheck source=/dev/null
#   . /tmp/files/scripts/network-helpers.sh 2>/dev/null || true
#
# The fallback definitions below mean scripts work even if this file is not
# present (e.g. partial checkout), so sourcing it is always safe.
# -----------------------------------------------------------------------------

# git_clone_resilient <url> <dest-dir> [extra clone args...]
# Retries a shallow clone up to 4 times with exponential backoff. Cleans the
# destination between attempts because a failed clone leaves a partial dir
# that makes subsequent clones fail with "destination path already exists".
git_clone_resilient() {
    local url="$1" dest="$2"; shift 2
    local tries=4 delay=5 rc=1
    while [ "$tries" -gt 0 ]; do
        rm -rf "$dest"
        if git clone --depth 1 "$@" "$url" "$dest"; then
            return 0
        fi
        rc=$?
        tries=$((tries - 1))
        echo "  WARNING: git clone of $url failed (exit $rc); retrying in ${delay}s (${tries} left)..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
    echo "ERROR: git clone failed after all retries: $url" >&2
    return 1
}

# curl_download_resilient <url> <output-file>
# Aggressive retry settings matching theming.sh's hardened downloads:
# --retry-all-errors covers transient 404/5xx from CDN-backed hosts.
curl_download_resilient() {
    local url="$1" out="$2"
    curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
         --connect-timeout 30 -o "$out" "$url"
}
