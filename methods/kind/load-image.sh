#!/usr/bin/env bash
# Side-load images straight into the nodes, bypassing every registry.
#
# A scenario that deploys the mirror itself cannot pull its own images through it:
# the mirror does not exist yet, and the node would sit on a dead endpoint until it
# times out before falling through to the upstream. Loading images into the nodes is
# a capability of the method, not of the scenario, so scenarios reach it through
# $LAB_LOAD_IMAGE and never learn that the cluster underneath them is kind.
#
# The archive comes from crane rather than from the host's container store, which
# turns out to matter twice over. A modern local store keeps an image *index*, not an
# image: exporting it by name carries references to manifests of platforms that were
# never fetched, and the node's import dies on the first missing digest. Filtering the
# export by platform fixes that but still leaves the buildx attestation manifest,
# which has no rootfs and fails to unpack. crane fetches exactly one platform's image
# from the registry and writes it as a plain archive, so neither problem arises.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

require_cmd kind crane
load_env
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"

[ $# -gt 0 ] || die "usage: load-image.sh <image> [image...]"

# Default to the node's architecture; only genuinely single-arch images need forcing.
PLATFORM="${LAB_IMAGE_PLATFORM:-linux/$(uname -m | sed 's/^x86_64$/amd64/;s/^aarch64$/arm64/')}"

# crane has no local store, so the lab keeps one: a bring-up should not re-download
# a gigabyte of registry images every time a scenario is re-applied.
CACHE_DIR="$REPO_ROOT/.cache/images"
mkdir -p "$CACHE_DIR"

for image in "$@"; do
  # An archive on disk is taken as given. A scenario that tests something it builds
  # itself has no registry to pull from, and pushing to one only to pull it back
  # would make the stand depend on a network round trip to prove a local change.
  if [ -f "$image" ]; then
    kind load image-archive --name "$CLUSTER_NAME" "$image"
    log "loaded archive $image"
    continue
  fi

  slug=$(printf '%s@%s' "$image" "$PLATFORM" | tr '/:@' '___')
  archive="$CACHE_DIR/$slug.tar"

  if [ ! -s "$archive" ]; then
    log "fetching $image ($PLATFORM)"
    crane pull --platform "$PLATFORM" "$image" "$archive"
  fi

  kind load image-archive --name "$CLUSTER_NAME" "$archive"
  log "loaded $image ($PLATFORM)"
done
