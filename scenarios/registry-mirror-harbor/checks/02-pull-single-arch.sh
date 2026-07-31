#!/usr/bin/env bash
# A single-architecture image manifest and its config blob come through the shim
# intact.
#
# Proves: the path-prefix rewriting and the fallback chain deliver a complete,
# byte-correct pull — not merely a 200. The config blob is re-hashed and compared
# against the digest the manifest claims, so a proxy that truncates or rewrites
# the body fails here rather than at container start.
#
# Overridable: IMAGE_REPO, IMAGE_TAG.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

: "${IMAGE_REPO:=library/alpine}"
: "${IMAGE_TAG:=3.20}"

open_mirror

reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/manifests/${IMAGE_TAG}" "${MANIFEST_ACCEPT}"
if [[ "${REG_STATUS}" != "200" ]]; then
  fail "manifest for ${IMAGE_REPO}:${IMAGE_TAG} returned ${REG_STATUS}"
fi

media="$(jq -r '.mediaType // "unset"' "${REG_BODY}")"
say "tag resolved to ${media}"

# Resolve down to one architecture: an index is not a single-arch manifest, and
# the point of this check is the leaf.
if jq -e '.manifests' "${REG_BODY}" >/dev/null 2>&1; then
  digest="$(jq -r '.manifests[]
      | select(.platform.os == "linux" and .platform.architecture == "amd64")
      | .digest' "${REG_BODY}" | head -1)"
  if [[ -z "${digest}" ]]; then
    fail "index carried no linux/amd64 manifest"
  fi
  say "linux/amd64 manifest: ${digest}"
  reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/manifests/${digest}" "${MANIFEST_ACCEPT}"
  if [[ "${REG_STATUS}" != "200" ]]; then
    fail "manifest ${digest} returned ${REG_STATUS}"
  fi
fi

config_digest="$(jq -r '.config.digest // empty' "${REG_BODY}")"
config_size="$(jq -r '.config.size // 0' "${REG_BODY}")"
if [[ -z "${config_digest}" ]]; then
  fail "manifest has no config descriptor"
fi

reg_get "${MIRROR_BASE}" "/v2/${IMAGE_REPO}/blobs/${config_digest}"
if [[ "${REG_STATUS}" != "200" ]]; then
  fail "config blob ${config_digest} returned ${REG_STATUS}"
fi

got="sha256:$(sha256_of "${REG_BODY}")"
size="$(wc -c <"${REG_BODY}" | tr -d ' ')"
if [[ "${got}" != "${config_digest}" ]]; then
  fail "config blob digest mismatch: manifest says ${config_digest}, bytes hash to ${got}"
fi

say "config blob: ${size} bytes (manifest declares ${config_size}), digest verified"
pass "${IMAGE_REPO}:${IMAGE_TAG} single-arch manifest and config blob served through the shim"
