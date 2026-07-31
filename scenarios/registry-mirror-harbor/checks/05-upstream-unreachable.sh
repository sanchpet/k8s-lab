#!/usr/bin/env bash
# What happens on a cache miss when the upstream cannot be reached.
#
# Proves two things that matter operationally:
#   1. the miss fails within a bounded time instead of hanging the client, and
#   2. the fleet still pulls, because containerd's second endpoint is the real
#      upstream — a dead mirror degrades throughput, not availability.
#
# The upstream is made unreachable by repointing one proxy-cache project's
# registry endpoint at TEST-NET-3 (RFC 5737, guaranteed unroutable) rather than
# by touching cluster networking, so the blast radius is one project and the
# original URL is restored on every exit path.
#
# registry.k8s.io is used because its endpoint is a plain docker-registry type
# whose URL Harbor lets you edit; the docker-hub type pins its own URL.
#
# Overridable: UPSTREAM_HOST, PROXY_PROJECT, IMAGE_REPO, IMAGE_TAG, MISS_TIMEOUT.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

: "${UPSTREAM_HOST:=registry.k8s.io}"
: "${PROXY_PROJECT:=k8s-proxy}"
: "${IMAGE_REPO:=pause}"
: "${IMAGE_TAG:=3.9}"
: "${MISS_TIMEOUT:=120}"

BLACKHOLE="http://203.0.113.1"
ENDPOINT_NAME="${PROXY_PROJECT}-endpoint"
POD="harbor-upstream-down"
REPO_PATH="${IMAGE_REPO//\//%2F}"

open_harbor

rid="$(harbor_api GET "/registries?page_size=100" \
  | jq -r --arg n "${ENDPOINT_NAME}" '.[]? | select(.name == $n) | .id' | head -1)"
if [[ -z "${rid}" ]]; then
  fail "registry endpoint ${ENDPOINT_NAME} not found; run provision-projects.sh first"
fi
orig_url="$(harbor_api GET "/registries/${rid}" | jq -r '.url')"
say "endpoint ${ENDPOINT_NAME} (id ${rid}) currently points at ${orig_url}"

restore() {
  harbor_api PUT "/registries/${rid}" \
    "$(jq -nc --arg u "${orig_url}" '{url: $u}')" >/dev/null
}
on_cleanup "restore"

harbor_api PUT "/registries/${rid}" "$(jq -nc --arg u "${BLACKHOLE}" '{url: $u}')" >/dev/null
if [[ "${HARBOR_STATUS}" != "200" ]]; then
  fail "repointing ${ENDPOINT_NAME} returned ${HARBOR_STATUS}"
fi
harbor_api DELETE "/projects/${PROXY_PROJECT}/repositories/${REPO_PATH}" >/dev/null
say "endpoint repointed at ${BLACKHOLE} and the cached repository dropped"

# 1. The miss must fail, and fail promptly.
open_mirror
SECONDS=0
reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/manifests/${IMAGE_TAG}" "${MANIFEST_ACCEPT}"
elapsed="${SECONDS}"
if [[ "${REG_STATUS}" == "200" ]]; then
  fail "the mirror served ${IMAGE_REPO}:${IMAGE_TAG} with the upstream blackholed — the cache was not actually cleared"
fi
if [[ "${elapsed}" -ge "${MISS_TIMEOUT}" ]]; then
  fail "the miss took ${elapsed}s (limit ${MISS_TIMEOUT}s); clients would stall rather than fail over"
fi
say "miss returned HTTP ${REG_STATUS} after ${elapsed}s"

# 2. The node must still get the image, from the upstream endpoint containerd
#    was configured with as a fallback.
kubectl delete pod "${POD}" --ignore-not-found --wait=true >/dev/null
on_cleanup "kubectl delete pod ${POD} --ignore-not-found --wait=false"
SECONDS=0
kubectl run "${POD}" \
  --image="${UPSTREAM_HOST}/${IMAGE_REPO}:${IMAGE_TAG}" \
  --image-pull-policy=Always \
  --restart=Never \
  --command -- sleep 60 >/dev/null
if ! kubectl wait --for=condition=Ready "pod/${POD}" --timeout=180s >/dev/null; then
  kubectl describe "pod/${POD}" | sed -n '/Events:/,$p' >&2
  fail "the pull did not fall through to ${UPSTREAM_HOST}; a dead mirror takes the fleet with it"
fi
fallback_time="${SECONDS}"

# A missing repository answers 404 with an error object rather than an empty
# list, so count only a genuine array.
cached="$(harbor_api GET "/projects/${PROXY_PROJECT}/repositories/${REPO_PATH}/artifacts?page_size=10" \
  | jq 'if type == "array" then length else 0 end')"
if [[ "${cached}" != "0" ]]; then
  fail "Harbor cached ${cached} artifact(s) while its upstream was unroutable — the failure was not the one under test"
fi

restore
say "pod Ready in ${fallback_time}s straight from ${UPSTREAM_HOST}; Harbor cached nothing"
pass "an unreachable upstream fails the miss in ${elapsed}s and containerd falls through to ${UPSTREAM_HOST}"
