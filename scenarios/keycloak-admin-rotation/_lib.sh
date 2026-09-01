#!/usr/bin/env bash
# Shared plumbing for this scenario: parameters, PASS/FAIL reporting, a port-forward
# that always gets torn down, and the two HTTP calls every check is built from —
# a password grant and an admin-API request.
#
# Sourced, never executed.
#
# Functions return values through globals rather than stdout, for the same reason as
# in the harbor scenario: anything registered inside $(...) lives in a subshell the
# EXIT trap cannot reach, so a port-forward would outlive the check that opened it.

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # .env is gitignored; only .env.example is in the repo
  . "${REPO_ROOT}/.env"
  set +a
fi

: "${KEYCLOAK_NAMESPACE:=keycloak}"

# The public upstream image is the tracked default because a registry host identifies
# a fleet. Point KEYCLOAK_IMAGE at your own build in .env to run the same checks
# against it; the answers here were obtained both ways and agreed.
: "${KEYCLOAK_IMAGE:=quay.io/keycloak/keycloak:26.3.2}"
: "${POSTGRES_IMAGE:=docker.io/library/postgres:16-alpine}"

: "${KC_ADMIN_USERNAME:=kk-admin}"

# Three synthetic passwords, one per role in the experiments: the one the instance is
# bootstrapped with, the one written into the Secret afterwards, and the one set
# through the admin API. Every check that changes a password puts A back, so the
# suite can be run twice in a row and mean the same thing both times.
: "${KC_PASS_A:=lab-alpha-0001}"
: "${KC_PASS_B:=lab-bravo-0002}"
: "${KC_PASS_C:=lab-charlie-0003}"

# shellcheck disable=SC2034  # read by the scripts that source this file
KC_SECRET_NAME=keycloak-admin
# shellcheck disable=SC2034  # read by the scripts that source this file
KC_DEPLOYMENT=keycloak

CHECK_NAME="$(basename "${0}" .sh)"

say()  { printf '  %s\n' "$*"; }
pass() { printf 'PASS %s: %s\n' "${CHECK_NAME}" "$*"; }
fail() { printf 'FAIL %s: %s\n' "${CHECK_NAME}" "$*" >&2; exit 1; }

# --- cleanup ---------------------------------------------------------------
_PF_PIDS=()
_TMPFILES=()
_CLEANUP_CMDS=()

on_cleanup() { _CLEANUP_CMDS+=("$*"); }

_cleanup() {
  local rc=$? item
  for item in ${_CLEANUP_CMDS[@]+"${_CLEANUP_CMDS[@]}"}; do
    eval "${item}" >/dev/null 2>&1 || true
  done
  for item in ${_PF_PIDS[@]+"${_PF_PIDS[@]}"}; do
    kill "${item}" 2>/dev/null || true
    wait "${item}" 2>/dev/null || true
  done
  for item in ${_TMPFILES[@]+"${_TMPFILES[@]}"}; do
    rm -f "${item}" || true
  done
  return "${rc}"
}
trap _cleanup EXIT

HTTP_BODY="$(mktemp)"
_TMPFILES+=("${HTTP_BODY}")

# --- which cluster ---------------------------------------------------------

# The tasks export KUBECONFIG; a check run directly does not get one, and kubectl
# then falls through to the ambient config — whose current context, on an engineer's
# laptop, is a real cluster. Nothing here is read-only enough to make that acceptable,
# so a check refuses to run rather than addressing a cluster it was not pointed at.
require_lab_cluster() {
  [[ -z "${KC_BASE:-}" ]] || return 0   # already inside the cluster
  local expected="${REPO_ROOT}/kubeconfig-${CLUSTER_NAME:-}"
  [[ -n "${CLUSTER_NAME:-}" ]] || fail "CLUSTER_NAME is not set — cannot tell which cluster this is"
  [[ "${KUBECONFIG:-}" == "${expected}" ]] || \
    fail "KUBECONFIG is '${KUBECONFIG:-unset}', not the lab's '${expected}' — run through: mise run check keycloak-admin-rotation"
}

# --- access ----------------------------------------------------------------

# open_keycloak -> KC_BASE. A preset KC_BASE means the caller is already inside the
# cluster and there is nothing to forward.
open_keycloak() {
  require_lab_cluster
  if [[ -n "${KC_BASE:-}" ]]; then
    say "using preset KC_BASE=${KC_BASE}"
    return 0
  fi
  local log pid found _
  log="$(mktemp)"
  _TMPFILES+=("${log}")
  kubectl -n "${KEYCLOAK_NAMESPACE}" port-forward svc/keycloak :8080 >"${log}" 2>&1 &
  pid=$!
  _PF_PIDS+=("${pid}")
  for _ in $(seq 1 60); do
    found="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "${log}" | head -1)"
    if [[ -n "${found}" ]]; then
      KC_BASE="http://127.0.0.1:${found}"
      return 0
    fi
    sleep 0.2
  done
  say "port-forward to keycloak never came up:"
  cat "${log}" >&2
  return 1
}

# --- the two calls everything is built from --------------------------------

# kc_token <username> <password> -> KC_STATUS, KC_TOKEN (empty unless 200).
#
# The password grant against admin-cli in realm master is exactly the call a rotation
# job would make to prove a credential, so the checks use nothing more capable.
kc_token() {
  local user="$1" secret="$2"
  KC_TOKEN=""
  KC_STATUS="$(curl -sS -o "${HTTP_BODY}" -w '%{http_code}' \
    -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'client_id=admin-cli' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${secret}")"
  if [[ "${KC_STATUS}" == "200" ]]; then
    # shellcheck disable=SC2034  # read by the scripts that source this file
    KC_TOKEN="$(jq -r '.access_token // empty' <"${HTTP_BODY}")"
  fi
}

# kc_admin <token> <method> <path> [json body] -> KC_STATUS, body in $HTTP_BODY.
kc_admin() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    KC_STATUS="$(curl -sS -o "${HTTP_BODY}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      -d "${body}" "${KC_BASE}/admin/realms/master${path}")"
  else
    KC_STATUS="$(curl -sS -o "${HTTP_BODY}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${token}" "${KC_BASE}/admin/realms/master${path}")"
  fi
}

# A token is cached by the client for its whole lifetime, but the server revokes
# nothing on a password change: the old access token stays valid until it expires.
# Every check that proves "the old password no longer works" must therefore prove it
# with a fresh grant, never by reusing a token.
kc_user_id() {
  local token="$1" user="$2"
  kc_admin "${token}" GET "/users?username=${user}&exact=true"
  [[ "${KC_STATUS}" == "200" ]] || return 1
  KC_USER_ID="$(jq -r '.[0].id // empty' <"${HTTP_BODY}")"
  [[ -n "${KC_USER_ID}" ]]
}

require_tools() {
  local t
  for t in "$@"; do
    command -v "${t}" >/dev/null 2>&1 || fail "required tool not found: ${t}"
  done
}
