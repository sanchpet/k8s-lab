#!/usr/bin/env bash
# Build the descheduler releases the checks run. Nothing is deployed: the failing
# pass needs only an API server, and the binary runs on the host so that its exit
# status, CPU time and stderr are the checks' own to read.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_cmd kubectl
kubectl get nodes >/dev/null || die "the stand's API server does not answer"

build_descheduler "${DESCHEDULER_REPO}" "${DESCHEDULER_VERSION}" >/dev/null
build_descheduler "${DESCHEDULER_REPO}" "${DESCHEDULER_COMPARE_VERSION}" >/dev/null
if [ -n "${DESCHEDULER_FIX_REF}" ]; then
  build_descheduler "${DESCHEDULER_FIX_REPO:-${DESCHEDULER_REPO}}" "${DESCHEDULER_FIX_REF}" >/dev/null
else
  log "DESCHEDULER_FIX_REF is empty: the fixed-build check will be skipped"
fi

log "applied"
