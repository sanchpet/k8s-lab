#!/usr/bin/env bash
# Experiment 2, second half — is the full admin role needed to reset one's own
# password through the admin API, or does a lesser one do?
#
# Measured on a throwaway user rather than on kk-admin, because the question is about
# the role and stripping roles off the only administrator is a way to lock the stand.
# The probe user is deleted on the way out.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq
open_keycloak

PROBE_USER=rotation-probe
PROBE_PASS="${KC_PASS_B}"

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
[[ "${KC_STATUS}" == "200" ]] || fail "cannot authenticate as ${KC_ADMIN_USERNAME} (${KC_STATUS})"
admin_token="${KC_TOKEN}"

if kc_user_id "${admin_token}" "${PROBE_USER}"; then
  kc_admin "${admin_token}" DELETE "/users/${KC_USER_ID}"
fi

kc_admin "${admin_token}" POST "/users" \
  "{\"username\":\"${PROBE_USER}\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"${PROBE_PASS}\",\"temporary\":false}]}"
[[ "${KC_STATUS}" == "201" ]] || fail "could not create the probe user (${KC_STATUS}): $(cat "${HTTP_BODY}")"
kc_user_id "${admin_token}" "${PROBE_USER}" || fail "probe user created but not found"
probe_id="${KC_USER_ID}"
on_cleanup "curl -sS -o /dev/null -X DELETE -H 'Authorization: Bearer ${admin_token}' ${KC_BASE}/admin/realms/master/users/${probe_id}"
say "probe user created, id=${probe_id}"

# --- with no admin role at all ---------------------------------------------
kc_token "${PROBE_USER}" "${PROBE_PASS}"
[[ "${KC_STATUS}" == "200" ]] || fail "the probe user cannot get a token at all (${KC_STATUS})"
probe_token="${KC_TOKEN}"
say "probe user authenticates: a token is not authorisation"

kc_admin "${probe_token}" PUT "/users/${probe_id}/reset-password" \
  "{\"type\":\"password\",\"value\":\"${KC_PASS_C}\",\"temporary\":false}"
bare="${KC_STATUS}"
say "no roles: PUT /users/{self}/reset-password -> ${bare}"

# --- one client role at a time from master-realm ---------------------------
#
# Two roles are tried, not one. A first role that works answers "does something
# lesser than admin suffice"; it does not answer "which is the least that does", and
# view-users is the obvious candidate to be wrongly assumed enough — it can find the
# user, which is half the recipe.
kc_admin "${admin_token}" GET "/clients?clientId=master-realm"
client_id="$(jq -r '.[0].id // empty' <"${HTTP_BODY}")"
[[ -n "${client_id}" ]] || fail "client master-realm not found (${KC_STATUS})"

grant_role() {
  local name="$1" role
  kc_admin "${admin_token}" GET "/clients/${client_id}/roles/${name}"
  [[ "${KC_STATUS}" == "200" ]] || fail "role ${name} not found on master-realm (${KC_STATUS})"
  role="$(cat "${HTTP_BODY}")"
  kc_admin "${admin_token}" POST "/users/${probe_id}/role-mappings/clients/${client_id}" "[${role}]"
  [[ "${KC_STATUS}" == "204" ]] || fail "could not grant ${name} (${KC_STATUS}): $(cat "${HTTP_BODY}")"
  # A role grant does not change a token already issued; take a fresh one.
  kc_token "${PROBE_USER}" "${PROBE_PASS}"
  [[ "${KC_STATUS}" == "200" ]] || fail "probe user lost its token after granting ${name} (${KC_STATUS})"
  probe_token="${KC_TOKEN}"
}

self_reset() {
  kc_admin "${probe_token}" PUT "/users/${probe_id}/reset-password" \
    "{\"type\":\"password\",\"value\":\"${KC_PASS_C}\",\"temporary\":false}"
}

grant_role view-users
self_reset
viewer="${KC_STATUS}"
kc_admin "${probe_token}" GET "/users?username=${PROBE_USER}&exact=true"
say "view-users: PUT /users/{self}/reset-password -> ${viewer}, GET /users?username=... -> ${KC_STATUS}"

grant_role manage-users
self_reset
manager="${KC_STATUS}"
kc_admin "${probe_token}" GET "/users?username=${PROBE_USER}&exact=true"
say "manage-users: PUT /users/{self}/reset-password -> ${manager}, GET /users?username=... -> ${KC_STATUS}"

[[ "${bare}" == "403" ]] || fail "expected 403 without any admin role, got ${bare}"
[[ "${viewer}" == "403" ]] || fail "expected 403 with view-users only, got ${viewer}"
[[ "${manager}" == "204" ]] || fail "expected 204 with master-realm:manage-users, got ${manager}"

pass "the write right is what is needed and it is enough: none 403, view-users 403, manage-users 204 — the admin composite is not required"
