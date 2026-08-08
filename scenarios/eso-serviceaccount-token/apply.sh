#!/usr/bin/env bash
# Install ESO from a locally built image and ask it to issue a ServiceAccount token.
#
# The image is loaded through $LAB_LOAD_IMAGE rather than pushed anywhere: the whole
# point is to test a build that exists only in a working tree, and a registry round
# trip would prove nothing except that the registry works.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"

require_tools kubectl helm envsubst
: "${ESO_CHART_DIR:?ESO_CHART_DIR must point at the chart of the build under test}"
: "${ESO_IMAGE_ARCHIVE:?ESO_IMAGE_ARCHIVE must point at a docker-save archive of that build}"
: "${ESO_IMAGE_REPOSITORY:?ESO_IMAGE_REPOSITORY must be set}"
: "${ESO_IMAGE_TAG:?ESO_IMAGE_TAG must be set}"
[ -d "${ESO_CHART_DIR}" ] || die "no chart at ${ESO_CHART_DIR}"
[ -s "${ESO_IMAGE_ARCHIVE}" ] || die "no image archive at ${ESO_IMAGE_ARCHIVE}"
[ -n "${LAB_LOAD_IMAGE:-}" ] || die "this method cannot side-load images, which this scenario needs"

log "loading ${ESO_IMAGE_REPOSITORY}:${ESO_IMAGE_TAG} into the cluster"
"${LAB_LOAD_IMAGE}" "${ESO_IMAGE_ARCHIVE}"

# Never pull: the tag exists only inside the nodes.
log "installing external-secrets from ${ESO_CHART_DIR}"
helm upgrade --install external-secrets "${ESO_CHART_DIR}" \
  --namespace "${ESO_NAMESPACE}" --create-namespace \
  --set "image.repository=${ESO_IMAGE_REPOSITORY}" \
  --set "image.tag=${ESO_IMAGE_TAG}" \
  --set "image.pullPolicy=Never" \
  --set "webhook.image.repository=${ESO_IMAGE_REPOSITORY}" \
  --set "webhook.image.tag=${ESO_IMAGE_TAG}" \
  --set "webhook.image.pullPolicy=Never" \
  --set "certController.image.repository=${ESO_IMAGE_REPOSITORY}" \
  --set "certController.image.tag=${ESO_IMAGE_TAG}" \
  --set "certController.image.pullPolicy=Never" \
  --wait --timeout 5m

render "${SCENARIO_DIR}/workload.yaml.tmpl" "${SCENARIO_DIR}/workload.rendered.yaml"
kubectl apply -f "${SCENARIO_DIR}/workload.rendered.yaml"

log "waiting for the ExternalSecret to report a value"
kubectl -n "${ESO_DEMO_NAMESPACE}" wait --for=condition=Ready \
  "externalsecret/${ESO_DEMO_SA}" --timeout=3m

log "applied"
