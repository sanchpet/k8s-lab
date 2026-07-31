#!/usr/bin/env bash
# Shared plumbing for this scenario: environment, PASS/FAIL reporting,
# port-forwards that always get torn down, and a registry client that survives
# the shim's re-challenge chain.
#
# Sourced, never executed.
#
# Functions here return values through globals rather than stdout. A background
# process or a temp file registered inside $(...) lives in a subshell: the parent
# never learns about it and the EXIT trap cannot clean it up, so a port-forward
# would outlive the check that opened it.

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # .env is gitignored; only .env.example is in the repo
  . "${REPO_ROOT}/.env"
  set +a
fi

: "${CLUSTER_DOMAIN:=cluster.local}"
: "${MIRROR_NAMESPACE:=registry}"
: "${MIRROR_SERVICE:=registry-mirror}"
: "${MIRROR_PORT:=5000}"
: "${HARBOR_NAMESPACE:=registry}"
: "${HARBOR_ADMIN_PASSWORD:=Harbor12345}"

# Chart-controlled, not site-specific: set by expose.clusterIP.name in harbor-values.yaml.tmpl.
: "${HARBOR_SERVICE:=harbor}"

# One proxy-cache project per upstream: upstream|project|endpoint URL|Harbor registry type.
# This table is the contract shared with registry-shim.yaml.tmpl and certs-d/.
# shellcheck disable=SC2034  # read by the scripts that source this file
UPSTREAMS=(
  "docker.io|dockerhub-proxy|https://hub.docker.com|docker-hub"
  "gcr.io|gcr-proxy|https://gcr.io|docker-registry"
  "registry.k8s.io|k8s-proxy|https://registry.k8s.io|docker-registry"
  "quay.io|quay-proxy|https://quay.io|docker-registry"
)

CHECK_NAME="$(basename "${0}" .sh)"

say()  { printf '  %s\n' "$*"; }
pass() { printf 'PASS %s: %s\n' "${CHECK_NAME}" "$*"; }
fail() { printf 'FAIL %s: %s\n' "${CHECK_NAME}" "$*" >&2; exit 1; }

# --- cleanup ---------------------------------------------------------------
# One EXIT trap for the whole script. Callers register work with on_cleanup
# instead of installing their own trap, which would silently replace this one.
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

# Fixed scratch files, allocated once in this shell so the trap owns them.
_HTTP_OUT="$(mktemp)"
REG_BODY="$(mktemp)"
REG_HEADERS="$(mktemp)"
_TMPFILES+=("${_HTTP_OUT}" "${REG_BODY}" "${REG_HEADERS}")

# --- access ----------------------------------------------------------------

# port_forward <namespace> <service> <port> -> PF_PORT.
# Each forward gets its own log: a shared one would be truncated under a still
# running kubectl and the port line would be read out of the wrong stream.
port_forward() {
  local ns="$1" svc="$2" port="$3" pid found log
  log="$(mktemp)"
  _TMPFILES+=("${log}")
  kubectl -n "${ns}" port-forward "svc/${svc}" ":${port}" >"${log}" 2>&1 &
  pid=$!
  _PF_PIDS+=("${pid}")
  local _
  for _ in $(seq 1 60); do
    found="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\).*/\1/p' "${log}" | head -1)"
    if [[ -n "${found}" ]]; then
      PF_PORT="${found}"
      return 0
    fi
    sleep 0.2
  done
  say "port-forward to ${svc}.${ns}:${port} never came up:"
  cat "${log}" >&2
  return 1
}

open_harbor() {
  port_forward "${HARBOR_NAMESPACE}" "${HARBOR_SERVICE}" 80
  HARBOR_BASE="http://127.0.0.1:${PF_PORT}"
}

open_mirror() {
  port_forward "${MIRROR_NAMESPACE}" "${MIRROR_SERVICE}" "${MIRROR_PORT}"
  # shellcheck disable=SC2034  # read by the scripts that source this file
  MIRROR_BASE="http://127.0.0.1:${PF_PORT}"
}

# harbor_api <method> <path> [json body] -> body on stdout, status in HARBOR_STATUS.
harbor_api() {
  local method="$1" path="$2" body="${3:-}"
  # shellcheck disable=SC2034  # HARBOR_STATUS is read by the calling script
  if [[ -n "${body}" ]]; then
    HARBOR_STATUS="$(curl -sS -o "${_HTTP_OUT}" -w '%{http_code}' -X "${method}" \
      -u "admin:${HARBOR_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
      -d "${body}" "${HARBOR_BASE}/api/v2.0${path}")"
  else
    HARBOR_STATUS="$(curl -sS -o "${_HTTP_OUT}" -w '%{http_code}' -X "${method}" \
      -u "admin:${HARBOR_ADMIN_PASSWORD}" "${HARBOR_BASE}/api/v2.0${path}")"
  fi
  cat "${_HTTP_OUT}"
}

# --- registry client -------------------------------------------------------

_header_value() {
  local file="$1" name="$2"
  tr -d '\r' <"${file}" | grep -i "^${name}:" | tail -1 | cut -d' ' -f2- || true
}

_challenge_param() {
  local challenge="$1" key="$2"
  printf '%s' "${challenge}" | sed -n "s/.*${key}=\"\([^\"]*\)\".*/\1/p"
}

# reg_get <base> <path> [accept] -> REG_STATUS, and the response in REG_BODY / REG_HEADERS.
#
# Re-authenticates on every 401 rather than once. The shim's fallback chain moves
# a request between projects, and each move produces a fresh challenge with a
# different scope; a client that authenticates only once gives up at the second
# project and reports a missing image that is in fact available.
reg_get() {
  local base="$1" path="$2" accept="${3:-*/*}"
  local token="" challenge realm service scope url _
  url="${base}${path}"
  for _ in 1 2 3 4 5 6; do
    if [[ -n "${token}" ]]; then
      REG_STATUS="$(curl -sS -o "${REG_BODY}" -D "${REG_HEADERS}" -w '%{http_code}' \
        -H "Accept: ${accept}" -H "Authorization: Bearer ${token}" "${url}")"
    else
      REG_STATUS="$(curl -sS -o "${REG_BODY}" -D "${REG_HEADERS}" -w '%{http_code}' \
        -H "Accept: ${accept}" "${url}")"
    fi
    if [[ "${REG_STATUS}" != "401" ]]; then
      return 0
    fi
    challenge="$(_header_value "${REG_HEADERS}" 'www-authenticate')"
    realm="$(_challenge_param "${challenge}" realm)"
    service="$(_challenge_param "${challenge}" service)"
    scope="$(_challenge_param "${challenge}" scope)"
    if [[ -z "${realm}" ]]; then
      return 0
    fi
    # The advertised realm is the in-cluster address from externalURL, which does
    # not resolve out here. We came through a port-forward to the same door, so
    # keep the realm's path and re-point its authority at our end of the tunnel.
    realm="${base}$(printf '%s' "${realm}" | sed -E 's#^[a-zA-Z]+://[^/]+##')"
    token="$(curl -sS --get --data-urlencode "service=${service}" \
      --data-urlencode "scope=${scope}" "${realm}" | jq -r '.token // .access_token // empty')"
    if [[ -z "${token}" ]]; then
      return 0
    fi
  done
  return 0
}

# shellcheck disable=SC2034  # read by the scripts that source this file
MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

require_tools() {
  local t
  for t in "$@"; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      fail "required tool not found: ${t}"
    fi
  done
}
