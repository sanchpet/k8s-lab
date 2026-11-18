#!/usr/bin/env bash
# Put the victims on one worker and build the descheduler under test.
#
# The pause image is side-loaded through $LAB_LOAD_IMAGE: sixty pods starting at once
# from a cold node would otherwise put the registry's latency into the measurement.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_cmd kubectl envsubst
[ -n "${LAB_LOAD_IMAGE:-}" ] || die "this method cannot side-load images, which this scenario needs"

kubectl get node "${DESCHEDULER_STALE_NODE}" >/dev/null \
  || die "no node ${DESCHEDULER_STALE_NODE}: is the stand the kind-2workers env?"

"${LAB_LOAD_IMAGE}" "${DESCHEDULER_PAUSE_IMAGE}"
build_descheduler "${DESCHEDULER_REPO}" "${DESCHEDULER_VERSION}" >/dev/null

render "${SCENARIO_DIR}/workload.yaml.tmpl" "${SCENARIO_DIR}/workload.rendered.yaml"
kubectl apply -f "${SCENARIO_DIR}/workload.rendered.yaml"
kubectl -n "${DESCHEDULER_STALE_NAMESPACE}" rollout status deploy/victims --timeout=5m

log "applied"
