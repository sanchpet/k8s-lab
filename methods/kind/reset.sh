#!/usr/bin/env bash
# Rebuild the cluster from scratch — the only honest way to retest node-layer config.
set -euo pipefail

ENV_NAME=${1:-onprem-kubeadm}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$HERE/down.sh" "$ENV_NAME"
"$HERE/up.sh" "$ENV_NAME"
