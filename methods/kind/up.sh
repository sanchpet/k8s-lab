#!/usr/bin/env bash
# Bring up (or adopt) the kind cluster for an env. Idempotent.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

ENV_NAME=${1:-onprem-kubeadm}
ENV_DIR="$REPO_ROOT/envs/$ENV_NAME"
[ -d "$ENV_DIR" ] || die "unknown env: $ENV_NAME (see $REPO_ROOT/envs/)"

require_cmd kind docker envsubst
load_env
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
: "${CLUSTER_DOMAIN:?CLUSTER_DOMAIN must be set}"
: "${MIRROR_SERVICE:?MIRROR_SERVICE must be set}"
: "${MIRROR_NAMESPACE:?MIRROR_NAMESPACE must be set}"

render "$ENV_DIR/kind.yaml.tmpl" "$ENV_DIR/kind.rendered.yaml"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "cluster $CLUSTER_NAME already exists — leaving it alone"
else
  log "creating cluster $CLUSTER_NAME from env $ENV_NAME"
  kind create cluster --config "$ENV_DIR/kind.rendered.yaml"
fi

KUBECONFIG_PATH="$REPO_ROOT/kubeconfig-$CLUSTER_NAME"
kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"

# containerd resolves the mirror through the node's own resolver, never cluster DNS,
# so the Service name has to exist in /etc/hosts on every node for the mirror
# endpoint to be reachable by name.
MIRROR_FQDN="${MIRROR_SERVICE}.${MIRROR_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" sh -c \
    "grep -qF ' ${MIRROR_FQDN}' /etc/hosts || echo '${MIRROR_CLUSTER_IP} ${MIRROR_FQDN}' >> /etc/hosts"
done
log "mapped $MIRROR_FQDN -> $MIRROR_CLUSTER_IP on all nodes"

log "kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
