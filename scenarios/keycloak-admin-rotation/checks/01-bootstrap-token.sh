#!/usr/bin/env bash
# Baseline: the bootstrap credential from the Secret authenticates.
#
# Everything after this assumes it, and it is also the check that fails first if a
# previous run left the database holding a password nobody put back.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq
open_keycloak

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
[[ "${KC_STATUS}" == "200" ]] || fail "password grant for ${KC_ADMIN_USERNAME} returned ${KC_STATUS}: $(cat "${HTTP_BODY}")"
[[ -n "${KC_TOKEN}" ]] || fail "200 with no access_token in the body"

say "POST /realms/master/protocol/openid-connect/token -> 200, access_token issued"
pass "${KC_ADMIN_USERNAME} authenticates with the bootstrap password"
