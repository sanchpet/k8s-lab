#!/usr/bin/env bash
# Shared plumbing for this scenario: environment, PASS/FAIL reporting and the
# wrapper around the measuring driver. Sourced, never executed.

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/descheduler.sh
. "${REPO_ROOT}/scripts/lib/descheduler.sh"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # .env is gitignored; only .env.example is in the repo
  . "${REPO_ROOT}/.env"
  set +a
fi

: "${CLUSTER_NAME:=onprem}"
: "${DESCHEDULER_REPO:=https://github.com/kubernetes-sigs/descheduler.git}"
: "${DESCHEDULER_VERSION:=v0.37.0}"
: "${DESCHEDULER_STALE_REPLICAS:=60}"
: "${DESCHEDULER_PAUSE_IMAGE:=registry.k8s.io/pause:3.10}"
DESCHEDULER_STALE_NAMESPACE=descheduler-stale
# The first worker of the env; the second is where evicted pods would go.
DESCHEDULER_STALE_NODE="${CLUSTER_NAME}-worker"
export DESCHEDULER_STALE_NAMESPACE DESCHEDULER_STALE_NODE DESCHEDULER_STALE_REPLICAS DESCHEDULER_PAUSE_IMAGE

# client-go's own defaults, which apply while the descheduler's flags are unset.
CLIENT_DEFAULT_QPS=5
CLIENT_DEFAULT_BURST=10
export CLIENT_DEFAULT_QPS CLIENT_DEFAULT_BURST

CHECK_NAME="$(basename "${0%.sh}")"
pass() { printf 'PASS %s: %s\n' "${CHECK_NAME}" "$*"; }
fail() { printf 'FAIL %s: %s\n' "${CHECK_NAME}" "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null || fail "${tool} not found in PATH"
  done
}

# measure <label> [descheduler flags...] — one pass, as one line of JSON on stdout.
# The driver resets the stand first, so a check can be re-run on the same cluster.
measure() {
  local label=$1; shift
  local bin
  bin="$(build_descheduler "${DESCHEDULER_REPO}" "${DESCHEDULER_VERSION}")"
  python3 -I "${SCENARIO_DIR}/measure.py" \
    --label "${label}" --binary "${bin}" --kubeconfig "${KUBECONFIG:?}" \
    --policy "${SCENARIO_DIR}/policy.yaml" \
    --manifest "${SCENARIO_DIR}/workload.rendered.yaml" \
    --namespace "${DESCHEDULER_STALE_NAMESPACE}" --node "${DESCHEDULER_STALE_NODE}" \
    --replicas "${DESCHEDULER_STALE_REPLICAS}" -- "$@"
}

# jget <json> <key> — one field of a JSON object.
jget() {
  python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(v)' "$1" "$2"
}

# num_ge <a> <b> — true when a >= b, for decimals.
num_ge() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }
