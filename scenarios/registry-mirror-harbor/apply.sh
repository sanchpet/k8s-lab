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

# Harbor's database records which blobs exist and the registry's storage holds
# them, so the two have to share one lifetime. Running without persistence puts
# both on emptyDir, and an upgrade that recreates only the registry leaves a
# database still claiming blobs that no longer exist. Harbor then answers those
# requests with 200 and an empty body — which the client cannot recover from,
# because a 200 is not a failure it can fall through on.
db_born=$(kubectl -n "${HARBOR_NAMESPACE}" get pod harbor-database-0 -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
reg_born=$(kubectl -n "${HARBOR_NAMESPACE}" get pod -l component=registry -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || true)
#
# Reconcile with a garbage collection rather than by restarting anything. Restarting
# the database is not a cheap repair: PostgreSQL shuts down in smart mode and waits
# for clients that never disconnect, so it hangs until it is killed and then boots
# into crash recovery — and on ephemeral storage it comes back with no schema at all,
# because the migrations run inside core at startup and core is already up. The
# registry then answers every request with UNAUTHORIZED, which points the reader at
# credentials rather than at the missing tables.
if [ -n "$db_born" ] && [ -n "$reg_born" ] && [ "$db_born" != "$reg_born" ]; then
  log "database and registry no longer share a lifetime — reconciling with a garbage collection"
  open_harbor
  harbor_api POST /system/gc/schedule \
    '{"schedule":{"type":"Manual"},"parameters":{"delete_untagged":true}}' >/dev/null
  for _ in $(seq 1 60); do
    status=$(harbor_api GET "/system/gc?page_size=1" | jq -r '.[0].job_status // empty')
    [ "$status" != "Success" ] || break
    sleep 2
  done
  [ "${status:-}" = "Success" ] || die "garbage collection did not succeed (last status: ${status:-none})"
  log "garbage collection done"
fi

render "${SCENARIO_DIR}/registry-shim.yaml.tmpl" "${SCENARIO_DIR}/registry-shim.rendered.yaml"
kubectl apply -f "${SCENARIO_DIR}/registry-shim.rendered.yaml"
kubectl -n "${MIRROR_NAMESPACE}" rollout status deploy/registry-shim --timeout=5m

# Harbor's configuration lives in its own database, so it is part of the deployment
# rather than a one-off setup step — and it is provisioned by a Job in the cluster,
# not by this script reaching in over a tunnel. Running it the way a fleet would is
# the only way to find out what breaks there.
#
# The ConfigMap is built from the same files a local run executes, so the in-cluster
# copy cannot drift from the one that gets debugged.
kubectl create configmap harbor-provision-scripts \
  --namespace "${HARBOR_NAMESPACE}" \
  --from-file="${SCENARIO_DIR}/_lib.sh" \
  --from-file="${SCENARIO_DIR}/provision-projects.sh" \
  --dry-run=client -o yaml | kubectl apply -f -

export HARBOR_SERVICE="${HARBOR_SERVICE:-harbor}"
render "${SCENARIO_DIR}/provision-job.yaml.tmpl" "${SCENARIO_DIR}/provision-job.rendered.yaml"
kubectl -n "${HARBOR_NAMESPACE}" delete job harbor-provision --ignore-not-found
kubectl apply -f "${SCENARIO_DIR}/provision-job.rendered.yaml"

if ! kubectl -n "${HARBOR_NAMESPACE}" wait --for=condition=complete job/harbor-provision --timeout=5m; then
  kubectl -n "${HARBOR_NAMESPACE}" logs job/harbor-provision --tail=50 || true
  die "provisioning job did not complete"
fi
kubectl -n "${HARBOR_NAMESPACE}" logs job/harbor-provision

log "applied — the mirror answers at ${MIRROR_SERVICE}.${MIRROR_NAMESPACE}.svc.${CLUSTER_DOMAIN}:${MIRROR_PORT}"
