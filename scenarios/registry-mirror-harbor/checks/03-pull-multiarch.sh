#!/usr/bin/env bash
# A multi-architecture manifest list survives the shim.
#
# Proves: the index is returned as an index — same media type, more than one
# platform — and each platform's child manifest is fetchable by digest. This is
# where naive proxies break: they either collapse the Accept header and get a
# single-arch manifest back, or they cache the first platform they saw and serve
# it to every node afterwards, which surfaces much later as an exec format error
# on one node pool.
#
# Overridable: IMAGE_REPO, IMAGE_TAG, PLATFORMS.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

: "${IMAGE_REPO:=library/alpine}"
: "${IMAGE_TAG:=3.20}"
: "${PLATFORMS:=linux/amd64 linux/arm64}"

open_mirror

reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/manifests/${IMAGE_TAG}" "${MANIFEST_ACCEPT}"
if [[ "${REG_STATUS}" != "200" ]]; then
  fail "manifest for ${IMAGE_REPO}:${IMAGE_TAG} returned ${REG_STATUS}"
fi

media="$(jq -r '.mediaType // "unset"' "${REG_BODY}")"
case "${media}" in
  application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json) ;;
  *) fail "expected an index, got ${media} — the shim collapsed the manifest list" ;;
esac

index="$(cat "${REG_BODY}")"
count="$(printf '%s' "${index}" | jq '[.manifests[] | select(.platform.architecture != "unknown")] | length')"
if [[ "${count}" -lt 2 ]]; then
  fail "index lists ${count} real platform(s); nothing multi-arch to verify"
fi
say "index ${media} with ${count} platforms"

for platform in ${PLATFORMS}; do
  os="${platform%%/*}"
  arch="${platform##*/}"
  digest="$(printf '%s' "${index}" | jq -r --arg os "${os}" --arg arch "${arch}" \
    '.manifests[] | select(.platform.os == $os and .platform.architecture == $arch) | .digest' | head -1)"
  if [[ -z "${digest}" ]]; then
    fail "index has no ${platform} entry"
  fi
  reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/manifests/${digest}" "${MANIFEST_ACCEPT}"
  if [[ "${REG_STATUS}" != "200" ]]; then
    fail "${platform} manifest ${digest} returned ${REG_STATUS}"
  fi
  # A proxy that serves one architecture for every request would still answer
  # 200 here, so hash the body: content-addressed storage means the returned
  # bytes must hash to the digest that was requested.
  got="sha256:$(sha256_of "${REG_BODY}")"
  if [[ "${got}" != "${digest}" ]]; then
    fail "${platform}: asked for ${digest}, got bytes hashing to ${got}"
  fi
  say "${platform}: ${digest} verified (config $(jq -r '.config.digest // "none"' "${REG_BODY}"))"
done

pass "manifest list preserved and every requested platform resolves through the shim"
