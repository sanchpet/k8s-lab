#!/usr/bin/env bash
# The pull actually went through Harbor.
#
# This is the check the whole scenario turns on. containerd is configured with
# the real upstream as its second endpoint, so a Pod that reaches Running proves
# only that the image exists somewhere on the internet — the mirror may have been
# skipped entirely. The client's exit code is not evidence.
#
# Method: delete the repository from the proxy-cache project, pull the image on a
# node (imagePullPolicy: Always, so containerd resolves the manifest over the
# network even if the layers are already on disk), then ask Harbor whether the
# artifact came back. If it did, Harbor served the request; if the pull fell
# through to the upstream, Harbor's project is still empty and this fails.
#
# Overridable: IMAGE_REPO, IMAGE_TAG, PROXY_PROJECT, PROBE_NAMESPACE.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

: "${IMAGE_REPO:=library/alpine}"
: "${IMAGE_TAG:=3.20}"
: "${PROXY_PROJECT:=dockerhub-proxy}"
: "${PROBE_NAMESPACE:=default}"

POD="harbor-provenance"
REPO_PATH="${IMAGE_REPO//\//%2F}"

open_harbor

# A missing repository answers 404 with an error object, not an empty list, so
# count only when the body is actually an array — otherwise Harbor's error
# payload counts as an artifact and the check passes on nothing.
artifacts() {
  harbor_api GET "/projects/${PROXY_PROJECT}/repositories/${REPO_PATH}/artifacts?page_size=50"
}
artifact_count() {
  jq 'if type == "array" then length else 0 end'
}

# Start from a known-empty cache so "the artifact is present" can only mean
# Harbor fetched it during this run.
harbor_api DELETE "/projects/${PROXY_PROJECT}/repositories/${REPO_PATH}" >/dev/null
say "cleared ${PROXY_PROJECT}/${IMAGE_REPO} from Harbor (status ${HARBOR_STATUS})"

before="$(artifacts | artifact_count)"
if [[ "${before}" != "0" ]]; then
  fail "repository still holds ${before} artifact(s) after deletion; the baseline is not clean"
fi

kubectl -n "${PROBE_NAMESPACE}" delete pod "${POD}" --ignore-not-found --wait=true >/dev/null
on_cleanup "kubectl -n ${PROBE_NAMESPACE} delete pod ${POD} --ignore-not-found --wait=false"

kubectl -n "${PROBE_NAMESPACE}" run "${POD}" \
  --image="docker.io/${IMAGE_REPO}:${IMAGE_TAG}" \
  --image-pull-policy=Always \
  --restart=Never \
  --command -- sleep 60 >/dev/null

if ! kubectl -n "${PROBE_NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=180s >/dev/null; then
  kubectl -n "${PROBE_NAMESPACE}" describe "pod/${POD}" | sed -n '/Events:/,$p' >&2
  fail "pod ${POD} never became Ready; the image did not pull at all"
fi

node="$(kubectl -n "${PROBE_NAMESPACE}" get "pod/${POD}" -o jsonpath='{.spec.nodeName}')"
say "pulled ${IMAGE_REPO}:${IMAGE_TAG} on node ${node}"

after="$(artifacts)"
if [[ "${HARBOR_STATUS}" != "200" ]]; then
  fail "listing artifacts returned ${HARBOR_STATUS}: Harbor has no record of ${PROXY_PROJECT}/${IMAGE_REPO}, so the pull bypassed it"
fi
count="$(printf '%s' "${after}" | artifact_count)"
if [[ "${count}" -lt 1 ]]; then
  fail "Harbor's ${PROXY_PROJECT}/${IMAGE_REPO} is still empty — the pull bypassed the mirror and went straight upstream"
fi

say "Harbor artifacts now: ${count}"
printf '%s' "${after}" | jq -r '.[] | "  digest \(.digest)  pushed \(.push_time)  pulls \(.pull_count // 0)  tags \([.tags[]?.name] | join(","))"'
pass "the image is present in Harbor's ${PROXY_PROJECT} after the pull — Harbor served it"
