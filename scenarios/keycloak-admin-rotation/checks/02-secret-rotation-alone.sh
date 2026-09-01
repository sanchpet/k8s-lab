#!/usr/bin/env bash
# Experiment 1 — does rewriting the Secret and restarting rotate the credential?
#
# Boot state is password A. Change ONLY the Secret to B, restart the pod against the
# same database, then ask for a token with each. Upstream documents
# KC_BOOTSTRAP_ADMIN_* as read only while the master realm does not yet exist; this
# check is what turns that sentence into a measurement on the build we run.
#
# Puts the Secret back to A before it ends, whichever way it ends.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

set_secret_password() {
  kubectl -n "${KEYCLOAK_NAMESPACE}" patch secret "${KC_SECRET_NAME}" --type merge \
    -p "{\"stringData\":{\"KC_BOOTSTRAP_ADMIN_PASSWORD\":\"$1\"}}" >/dev/null
}

restart_keycloak() {
  kubectl -n "${KEYCLOAK_NAMESPACE}" rollout restart "deploy/${KC_DEPLOYMENT}" >/dev/null
  kubectl -n "${KEYCLOAK_NAMESPACE}" rollout status "deploy/${KC_DEPLOYMENT}" --timeout=10m >/dev/null
}

db_uid_before="$(kubectl -n "${KEYCLOAK_NAMESPACE}" get pod -l app=keycloak-db \
  -o jsonpath='{.items[0].metadata.uid}')"

on_cleanup "kubectl -n ${KEYCLOAK_NAMESPACE} patch secret ${KC_SECRET_NAME} --type merge -p '{\"stringData\":{\"KC_BOOTSTRAP_ADMIN_PASSWORD\":\"${KC_PASS_A}\"}}'"
# The restart has to be waited on, not merely ordered: a check that returns while the
# pod is still terminating hands the next check a Pending pod and a port-forward that
# cannot open, which reads as a failure of the wrong thing.
on_cleanup "kubectl -n ${KEYCLOAK_NAMESPACE} rollout restart deploy/${KC_DEPLOYMENT} && kubectl -n ${KEYCLOAK_NAMESPACE} rollout status deploy/${KC_DEPLOYMENT} --timeout=10m"

say "writing password B into the Secret and restarting Keycloak"
set_secret_password "${KC_PASS_B}"
restart_keycloak

db_uid_after="$(kubectl -n "${KEYCLOAK_NAMESPACE}" get pod -l app=keycloak-db \
  -o jsonpath='{.items[0].metadata.uid}')"
[[ "${db_uid_before}" == "${db_uid_after}" ]] || \
  fail "the database pod was replaced during the restart — this measured a fresh install, not a rotation"

open_keycloak

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_B}"
status_b="${KC_STATUS}"
say "grant with the password now in the Secret (B) -> ${status_b}"

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
status_a="${KC_STATUS}"
say "grant with the password the instance was bootstrapped with (A) -> ${status_a}"

if [[ "${status_a}" == "200" && "${status_b}" != "200" ]]; then
  pass "the Secret is not the credential: rewriting it and restarting changed nothing (A still authenticates, B does not)"
elif [[ "${status_b}" == "200" && "${status_a}" != "200" ]]; then
  fail "this build DOES re-read KC_BOOTSTRAP_ADMIN_PASSWORD on restart — the rotation design must be reconsidered"
else
  fail "neither exclusive outcome: A -> ${status_a}, B -> ${status_b}"
fi
