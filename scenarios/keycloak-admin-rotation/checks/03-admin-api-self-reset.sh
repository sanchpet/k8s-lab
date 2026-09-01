#!/usr/bin/env bash
# Experiment 2 — rotate kk-admin's own password through the admin API.
#
# The whole recipe, in the order a rotation job would run it: authenticate, resolve
# the user id, PUT a credential representation, then prove the new password works and
# the old one does not with FRESH grants. A token already issued stays valid until it
# expires — reusing one would prove nothing about the credential.
#
# Ends by setting the password back to A, so the suite is re-runnable.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq
open_keycloak

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
[[ "${KC_STATUS}" == "200" ]] || fail "cannot authenticate with password A (${KC_STATUS}) — run check 01 first"
token_a="${KC_TOKEN}"

kc_user_id "${token_a}" "${KC_ADMIN_USERNAME}" || fail "cannot resolve the user id of ${KC_ADMIN_USERNAME} (${KC_STATUS})"
say "GET /admin/realms/master/users?username=${KC_ADMIN_USERNAME}&exact=true -> 200, id=${KC_USER_ID}"

kc_admin "${token_a}" PUT "/users/${KC_USER_ID}/reset-password" \
  "{\"type\":\"password\",\"value\":\"${KC_PASS_C}\",\"temporary\":false}"
say "PUT /admin/realms/master/users/${KC_USER_ID}/reset-password -> ${KC_STATUS}"
[[ "${KC_STATUS}" == "204" ]] || fail "reset-password returned ${KC_STATUS}: $(cat "${HTTP_BODY}")"

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_C}"
status_c="${KC_STATUS}"
token_c="${KC_TOKEN}"
say "fresh grant with the new password -> ${status_c}"

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
status_a="${KC_STATUS}"
say "fresh grant with the old password -> ${status_a}"

# Restore before judging: a failed assertion must not leave the stand on password C.
if [[ -n "${token_c}" ]]; then
  kc_admin "${token_c}" PUT "/users/${KC_USER_ID}/reset-password" \
    "{\"type\":\"password\",\"value\":\"${KC_PASS_A}\",\"temporary\":false}"
  say "restored password A -> ${KC_STATUS}"
fi

[[ "${status_c}" == "200" ]] || fail "the new password does not authenticate (${status_c})"
[[ "${status_a}" != "200" ]] || fail "the old password still authenticates — the reset did not take"

pass "reset-password rotates the credential in place: new password 200, old password ${status_a}"
