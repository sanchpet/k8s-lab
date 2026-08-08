#!/usr/bin/env bash
# Shared plumbing for this scenario: environment, PASS/FAIL reporting, and the
# JWT claim reader the checks are built on.
#
# Sourced, never executed.

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # .env is gitignored; only .env.example is in the repo
  . "${REPO_ROOT}/.env"
  set +a
fi

: "${ESO_NAMESPACE:=external-secrets}"
: "${ESO_DEMO_NAMESPACE:=demo}"
: "${ESO_DEMO_SA:=argocd-remote}"
: "${ESO_DEMO_SECRET:=argocd-remote-token}"
: "${ESO_DEMO_AUDIENCE:=https://kubernetes.default.svc.cluster.local}"
: "${ESO_DEMO_REQUESTED_SECONDS:=7200}"
: "${SA_TOKEN_MAX_EXPIRATION:=1h}"

CHECK_NAME="$(basename "${0%.sh}")"
pass() { printf 'PASS %s: %s\n' "${CHECK_NAME}" "$*"; }
fail() { printf 'FAIL %s: %s\n' "${CHECK_NAME}" "$*" >&2; exit 1; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null || fail "${tool} not found in PATH"
  done
}

# secret_key <key> — the decoded value of one key of the generated Secret.
secret_key() {
  kubectl -n "${ESO_DEMO_NAMESPACE}" get secret "${ESO_DEMO_SECRET}" \
    -o "jsonpath={.data.$1}" | base64 -d
}

# token_claims — the payload of the issued JWT, as JSON.
#
# The signature is not verified here on purpose: these checks ask what the API
# server put in the token, not whether the token would be accepted. A check that
# conflated the two would go green on a well-formed token with the wrong claims.
token_claims() {
  local payload
  payload="$(secret_key token | cut -d. -f2)"
  # base64url without padding: restore both before decoding.
  payload="${payload//-/+}"
  payload="${payload//_//}"
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "${payload}" | base64 -d
}

# seconds_from_duration <30m|1h|3600s> — a Go duration as plain seconds.
seconds_from_duration() {
  local d=$1 n=${1%[smh]}
  case "${d}" in
    *h) printf '%s' $(( n * 3600 )) ;;
    *m) printf '%s' $(( n * 60 )) ;;
    *s) printf '%s' "${n}" ;;
    *)  printf '%s' "${d}" ;;
  esac
}
