#!/usr/bin/env bash
# Deploy the subject under test: one Keycloak, one PostgreSQL, one Secret.
#
# Run through the task so the kubeconfig and the method's capabilities are in the
# environment:  mise run apply keycloak-admin-rotation
#
# Idempotent, with one deliberate asymmetry: the admin Secret is put back to password
# A on every apply. The checks move it and move it back, but a run interrupted in the
# middle would otherwise leave a stand whose Secret and whose database disagree — and
# that disagreement is precisely the state this scenario exists to explain, so it must
# not be the state a fresh apply starts from.
set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../scripts/lib/common.sh
. "$(cd "${SCENARIO_DIR}/../.." && pwd)/scripts/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=_lib.sh
. "${SCENARIO_DIR}/_lib.sh"

require_cmd kubectl curl jq envsubst
load_env

# Only the database credential is generated: it is never asserted about, so a fixed
# value would be a committed password for no gain. The admin passwords stay fixed
# because the checks name them.
: "${KC_DB_PASSWORD:=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
export KC_DB_PASSWORD
export KEYCLOAK_NAMESPACE KEYCLOAK_IMAGE POSTGRES_IMAGE KC_ADMIN_USERNAME
KC_ADMIN_PASSWORD="${KC_PASS_A}"
export KC_ADMIN_PASSWORD

# The env this scenario runs on points containerd at a mirror that is not deployed
# here, so an ordinary pull would stall on a dead endpoint before falling through.
# Side-loading is a capability of the method; the scenario only asks for it.
if [ -n "${LAB_LOAD_IMAGE:-}" ]; then
  "${LAB_LOAD_IMAGE}" "${KEYCLOAK_IMAGE}" "${POSTGRES_IMAGE}"
else
  log "WARNING: method exposes no image side-loading — pulls go out to the registry"
fi

# A re-apply must not silently keep an old database credential: the Secret would be
# rewritten while PostgreSQL still holds the password it was initialised with.
if kubectl -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-db >/dev/null 2>&1; then
  KC_DB_PASSWORD="$(kubectl -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-db \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  export KC_DB_PASSWORD
  log "reusing the existing database credential"
fi

render "${SCENARIO_DIR}/keycloak.yaml.tmpl" "${SCENARIO_DIR}/keycloak.rendered.yaml"
kubectl apply -f "${SCENARIO_DIR}/keycloak.rendered.yaml"

kubectl -n "${KEYCLOAK_NAMESPACE}" rollout status deploy/keycloak-db --timeout=5m
kubectl -n "${KEYCLOAK_NAMESPACE}" rollout status deploy/keycloak --timeout=10m

log "applied — keycloak answers at keycloak.${KEYCLOAK_NAMESPACE}.svc:8080"
log "image under test: ${KEYCLOAK_IMAGE}"
