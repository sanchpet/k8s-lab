#!/usr/bin/env bash
# Deploy the subject under test: Harbor, the shim in front of it, and the four
# proxy-cache projects.
#
# Run through the task so the kubeconfig and the method's capabilities are in the
# environment:  mise run apply registry-mirror-harbor
set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "$(cd "${SCENARIO_DIR}/../.." && pwd)/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "${SCENARIO_DIR}/_lib.sh"

require_cmd kubectl helm curl jq envsubst
load_env
: "${HARBOR_CHART_VERSION:?HARBOR_CHART_VERSION must be set}"

helm repo add harbor https://helm.goharbor.io >/dev/null 2>&1 || true
helm repo update harbor >/dev/null

# Derive the image tag from the chart instead of pinning it a second time: two pins
# for one version drift apart, and the one that drifts is always the quiet one.
APP_VERSION="$(helm show chart harbor/harbor --version "${HARBOR_CHART_VERSION}" \
  | sed -n 's/^appVersion: *//p' | tr -d '"')"
[ -n "${APP_VERSION}" ] || die "could not read appVersion of harbor chart ${HARBOR_CHART_VERSION}"
log "harbor chart ${HARBOR_CHART_VERSION} -> images v${APP_VERSION}"

# A registry cannot bootstrap through itself. The node's mirror endpoint is the very
# Service this scenario is about to create, so every image it needs has to reach the
# nodes some other way — otherwise each pull first stalls on a dead ClusterIP and
# only then falls through to the upstream.
if [ -n "${LAB_LOAD_IMAGE:-}" ]; then
  harbor_images=""
  for c in nginx-photon harbor-portal harbor-core harbor-jobservice registry-photon \
           harbor-registryctl harbor-db redis-photon harbor-exporter; do
    harbor_images="${harbor_images} docker.io/goharbor/${c}:v${APP_VERSION}"
  done
  # Harbor publishes amd64 only, at every version to date; the shim's nginx is
  # multi-arch and must stay native, or it runs emulated for no reason.
  # shellcheck disable=SC2086  # word splitting is the point
  LAB_IMAGE_PLATFORM=linux/amd64 "${LAB_LOAD_IMAGE}" ${harbor_images}
  "${LAB_LOAD_IMAGE}" "$(sed -n 's/^ *image: *//p' "${SCENARIO_DIR}/registry-shim.yaml.tmpl" | head -1)"
else
  log "WARNING: method exposes no image side-loading — pulls will stall on the dead mirror first"
fi

kubectl create namespace "${HARBOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${MIRROR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

render "${SCENARIO_DIR}/harbor-values.yaml.tmpl" "${SCENARIO_DIR}/harbor-values.rendered.yaml"
helm upgrade --install harbor harbor/harbor \
  --namespace "${HARBOR_NAMESPACE}" \
  --version "${HARBOR_CHART_VERSION}" \
  --values "${SCENARIO_DIR}/harbor-values.rendered.yaml" \
  --wait --timeout 20m

render "${SCENARIO_DIR}/registry-shim.yaml.tmpl" "${SCENARIO_DIR}/registry-shim.rendered.yaml"
kubectl apply -f "${SCENARIO_DIR}/registry-shim.rendered.yaml"
kubectl -n "${MIRROR_NAMESPACE}" rollout status deploy/registry-shim --timeout=5m

# Harbor's configuration lives in a database on an emptyDir, so it is part of the
# deployment, not a one-off setup step.
"${SCENARIO_DIR}/provision-projects.sh"

log "applied — the mirror answers at ${MIRROR_SERVICE}.${MIRROR_NAMESPACE}.svc.${CLUSTER_DOMAIN}:${MIRROR_PORT}"
