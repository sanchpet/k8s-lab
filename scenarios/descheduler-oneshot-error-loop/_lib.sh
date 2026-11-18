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

: "${DESCHEDULER_REPO:=https://github.com/kubernetes-sigs/descheduler.git}"
: "${DESCHEDULER_VERSION:=v0.37.0}"
: "${DESCHEDULER_COMPARE_VERSION:=v0.34.0}"
: "${DESCHEDULER_FIX_REPO:=}"
: "${DESCHEDULER_FIX_REF:=}"
: "${DESCHEDULER_LOOP_LIMIT_SECONDS:=10}"

# Fewer lines than this in the limit is not a loop. The stand does hundreds of
# thousands a second, so the margin is several orders of magnitude.
MIN_ERROR_LINES=10000
export MIN_ERROR_LINES

CHECK_NAME="$(basename "${0%.sh}")"
pass() { printf 'PASS %s: %s\n' "${CHECK_NAME}" "$*"; }
fail() { printf 'FAIL %s: %s\n' "${CHECK_NAME}" "$*" >&2; exit 1; }
skip() { printf 'SKIP %s: %s\n' "${CHECK_NAME}" "$*"; exit 0; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null || fail "${tool} not found in PATH"
  done
}

# run_loop <label> <binary> — one run of the binary against the failing pass, as one
# line of JSON on stdout.
run_loop() {
  python3 -I "${SCENARIO_DIR}/loop.py" \
    --label "$1" --binary "$2" --kubeconfig "${KUBECONFIG:?}" \
    --policy "${SCENARIO_DIR}/policy.yaml" --limit "${DESCHEDULER_LOOP_LIMIT_SECONDS}"
}

# jget <json> <key> — one field of a JSON object.
jget() {
  python3 -I -c 'import json,sys; v=json.loads(sys.argv[1])[sys.argv[2]]; print(str(v).lower() if isinstance(v, bool) else v)' "$1" "$2"
}

# num_ge <a> <b> — true when a >= b, for decimals.
num_ge() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$1" "$2"; }
