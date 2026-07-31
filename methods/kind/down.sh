#!/usr/bin/env bash
# Delete the kind cluster of an env. Idempotent: kind exits 0 on an absent cluster.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

ENV_NAME=${1:-onprem-kubeadm}
[ -d "$REPO_ROOT/envs/$ENV_NAME" ] || die "unknown env: $ENV_NAME (see $REPO_ROOT/envs/)"

require_cmd kind
load_env
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"

log "deleting cluster $CLUSTER_NAME"
kind delete cluster --name "$CLUSTER_NAME"
rm -f "$REPO_ROOT/kubeconfig-$CLUSTER_NAME"
