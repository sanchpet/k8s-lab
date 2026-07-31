#!/usr/bin/env bash
# Losing one Harbor core replica does not interrupt the mirror.
#
# Proves: the token service and the API survive the loss of a single core pod,
# so a rolling upgrade or a node drain is not an outage. Core is the only Harbor
# component that can be scaled on this stand — the registry keeps its cache in an
# emptyDir, so a second registry replica would hold a different cache and losing
# the one there is empties it entirely (see README, "Statelessness").
#
# The cache is warmed first: a request that misses would go to the upstream and
# measure the internet rather than the replica loss.
#
# Overridable: IMAGE_REPO, IMAGE_TAG, PROBE_SECONDS, MAX_FAILURES.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

: "${IMAGE_REPO:=library/alpine}"
: "${IMAGE_TAG:=3.20}"
: "${PROBE_SECONDS:=45}"
# Endpoint removal is not instantaneous, so one request may already be in flight
# to the pod that is going away. More than that means the loss is not absorbed.
: "${MAX_FAILURES:=1}"

CORE_SELECTOR="app=harbor,component=core"
MANIFEST_PATH="/v2/${IMAGE_REPO}/manifests/${IMAGE_TAG}"

ready_cores() {
  kubectl -n "${HARBOR_NAMESPACE}" get pods -l "${CORE_SELECTOR}" -o json \
    | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

replicas="$(ready_cores)"
if [[ "${replicas}" -lt 2 ]]; then
  fail "only ${replicas} ready core pod(s); set core.replicas: 2 in harbor-values.yaml.tmpl for this check to mean anything"
fi
say "${replicas} core replicas ready"

open_mirror

reg_get "${MIRROR_BASE}" "${MANIFEST_PATH}" "${MANIFEST_ACCEPT}"
if [[ "${REG_STATUS}" != "200" ]]; then
  fail "warm-up request returned ${REG_STATUS}; cannot separate replica loss from a cache miss"
fi
say "cache warm for ${IMAGE_REPO}:${IMAGE_TAG}"

victim="$(kubectl -n "${HARBOR_NAMESPACE}" get pods -l "${CORE_SELECTOR}" \
  -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${HARBOR_NAMESPACE}" delete "pod/${victim}" --wait=false >/dev/null
say "deleted core pod ${victim}"

attempts=0
failures=0
SECONDS=0
while [[ "${SECONDS}" -lt "${PROBE_SECONDS}" ]]; do
  attempts=$((attempts + 1))
  reg_get "${MIRROR_BASE}" "${MANIFEST_PATH}" "${MANIFEST_ACCEPT}"
  if [[ "${REG_STATUS}" != "200" ]]; then
    failures=$((failures + 1))
    say "request ${attempts} at t+${SECONDS}s returned ${REG_STATUS}"
  fi
  sleep 2
done

say "${attempts} requests over ${PROBE_SECONDS}s, ${failures} failed"

if ! kubectl -n "${HARBOR_NAMESPACE}" wait --for=condition=Ready pod \
  -l "${CORE_SELECTOR}" --timeout=180s >/dev/null; then
  fail "core did not return to full readiness after the deletion"
fi
say "core back to $(ready_cores) ready replicas"

if [[ "${failures}" -gt "${MAX_FAILURES}" ]]; then
  fail "${failures} failed requests during the replica loss (tolerance ${MAX_FAILURES})"
fi

pass "mirror stayed available through the loss of core pod ${victim} (${failures}/${attempts} failed)"
