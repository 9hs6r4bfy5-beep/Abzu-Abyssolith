#!/usr/bin/env bash
set -euo pipefail

echo "--- Installing sumer R package ---"

# -----------------------------------------------------------------------------
# Build-stability hardening (audit fixes):
#
# 1. NETWORK RESILIENCE. cloud.r-project.org redirects to a random CRAN
#    mirror; transient mirror failures (5xx, connection resets) previously
#    aborted the whole ISO build with no retry. We now pre-resolve a list of
#    mirrors and pass them all to install.packages(), which falls back from
#    one to the next automatically, plus an outer retry loop for the case
#    where every mirror hiccups simultaneously.
#
# 2. MEMORY BOUNDS. Ncpus was previously detectCores()-1 with no cap. On
#    large runners this spawns dozens of parallel gcc processes compiling
#    C++ heavy dependencies (Rcpp, BH, ...) and the container gets OOM-killed
#    -- the same class of failure we already had to fix for Hotline and Snow.
#    Cap parallel compilation at 2 jobs.
#
# 3. TIMEOUTS. A hung mirror used to stall the build indefinitely. curl's
#    low-level timeouts are surfaced through R's download.file method.
# -----------------------------------------------------------------------------

CRAN_MIRRORS='c(Cloud = "https://cloud.r-project.org", Vienna = "https://cran.aau.at", Mainz = "https://cran.r-project.org", Austin = "https://cran.r-project.r-panda.ca", Wellington = "https://mirror.sit.vu.nz/cran/")'

MAX_ATTEMPTS=3
ATTEMPT=1
while true; do
    echo "  sumer install attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
    if Rscript --vanilla -e "
        options(
            repos = ${CRAN_MIRRORS},
            warn = 1,
            Ncpus = min(2L, max(1L, parallel::detectCores() - 1L)),
            download.file.method = 'libcurl',
            download.file.extra = c('--retry=3 --retry-delay=5 --connect-timeout=30 --speed-limit=1024 --speed-time=60')
        )
        # Deliberately omit dependencies = TRUE: it would pull every Suggests
        # package of every transitive dependency and require system libraries
        # we do not ship. Depends/Imports/LinkingTo is the correct closure.
        ok <- tryCatch({
            install.packages('sumer',
                             dependencies = c('Depends', 'Imports', 'LinkingTo'),
                             quiet = FALSE)
            TRUE
        }, error = function(e) { message('install.packages error: ', conditionMessage(e)); FALSE })
        if (!ok) quit(status = 1)
    "; then
        break
    fi
    if [ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]; then
        echo "ERROR: sumer installation failed after ${MAX_ATTEMPTS} attempts." >&2
        exit 1
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo "  Attempt failed; retrying in 10s..." >&2
    sleep 10
done

# Verify the package is actually loadable. install.packages() does NOT return
# a non-zero exit code on per-package failure, so loading is the only
# deterministic check.
if ! Rscript --vanilla -e 'library(sumer)' >/dev/null 2>&1; then
    echo "ERROR: sumer is not loadable after install." >&2
    echo "       Re-running install with full dependency output for diagnostics:" >&2
    Rscript --vanilla -e "
        options(repos = ${CRAN_MIRRORS},
                download.file.method = 'libcurl')
        install.packages('sumer', dependencies = c('Depends', 'Imports', 'LinkingTo'))
    " || true
    if ! Rscript --vanilla -e 'library(sumer)' >/dev/null 2>&1; then
        echo "ERROR: sumer still not loadable. Aborting build." >&2
        exit 1
    fi
fi

echo "--- sumer package installed ---"
