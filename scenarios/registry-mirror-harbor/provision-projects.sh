#!/usr/bin/env bash
# Creates the four proxy-cache projects: one registry endpoint and one project
# per upstream.
#
# This is a script rather than a click-through in the UI because the stand runs
# Harbor with persistence.enabled=false. The project configuration lives in
# Harbor's PostgreSQL, which is an emptyDir, so it evaporates with the pod and
# every bring-up has to rebuild it identically. The script is also what makes the
# configuration reviewable instead of remembered.
#
# Idempotent and non-interactive: safe to re-run at any point.
#
# The admin credential comes from HARBOR_ADMIN_PASSWORD in .env; the only value
# baked in is the chart's documented default, which .env.example carries openly.
#
#   ./provision-projects.sh

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# shellcheck disable=SC2034  # read by pass()/fail() in _lib.sh
CHECK_NAME="provision"
# kubectl is only needed to open a tunnel; in-cluster there is nothing to tunnel.
require_tools curl jq
[[ -n "${HARBOR_BASE:-}" ]] || require_tools kubectl

open_harbor

# Wait for the API instead of racing the chart's first boot.
ready=false
for _ in $(seq 1 60); do
  harbor_api GET /health >/dev/null || true
  if [[ "${HARBOR_STATUS}" == "200" ]]; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "${ready}" != "true" ]]; then
  fail "Harbor API did not become healthy (last status ${HARBOR_STATUS:-none})"
fi

# ensure_registry <name> <url> <type> -> REGISTRY_ID
ensure_registry() {
  local name="$1" url="$2" type="$3"
  REGISTRY_ID="$(harbor_api GET "/registries?page_size=100" \
    | jq -r --arg n "${name}" '.[]? | select(.name == $n) | .id' | head -1)"
  if [[ -n "${REGISTRY_ID}" ]]; then
    say "registry endpoint ${name} already present (id ${REGISTRY_ID})"
    return 0
  fi
  harbor_api POST /registries \
    "$(jq -nc --arg n "${name}" --arg u "${url}" --arg t "${type}" \
        '{name: $n, url: $u, type: $t, insecure: false}')" >/dev/null
  if [[ "${HARBOR_STATUS}" != "201" ]]; then
    fail "creating registry endpoint ${name} returned ${HARBOR_STATUS}"
  fi
  REGISTRY_ID="$(harbor_api GET "/registries?page_size=100" \
    | jq -r --arg n "${name}" '.[]? | select(.name == $n) | .id' | head -1)"
  say "registry endpoint ${name} created (id ${REGISTRY_ID}, ${url})"
}

ensure_project() {
  local project="$1" registry_id="$2" existing
  existing="$(harbor_api GET "/projects?page_size=100" \
    | jq -r --arg n "${project}" '.[]? | select(.name == $n) | .project_id' | head -1)"
  if [[ -n "${existing}" ]]; then
    say "project ${project} already present (id ${existing})"
    return 0
  fi
  # Public on purpose. The shim walks the four projects on a miss, and an
  # anonymous client can only obtain a token for each scope in turn if every
  # project grants anonymous pull. A private project answers 401 indefinitely and
  # the walk never reaches the project that actually holds the image.
  harbor_api POST /projects \
    "$(jq -nc --arg n "${project}" --argjson r "${registry_id}" \
        '{project_name: $n, registry_id: $r, public: true, metadata: {public: "true"}}')" >/dev/null
  if [[ "${HARBOR_STATUS}" != "201" ]]; then
    fail "creating project ${project} returned ${HARBOR_STATUS}"
  fi
  say "project ${project} created (public, proxy cache of registry ${registry_id})"
}

for entry in "${UPSTREAMS[@]}"; do
  IFS='|' read -r upstream project url type <<<"${entry}"
  say "--- ${upstream} -> ${project}"
  ensure_registry "${project}-endpoint" "${url}" "${type}"
  ensure_project "${project}" "${REGISTRY_ID}"
done

pass "${#UPSTREAMS[@]} proxy-cache projects present"
