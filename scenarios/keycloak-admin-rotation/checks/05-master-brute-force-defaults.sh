#!/usr/bin/env bash
# Experiment 3 — the master realm's brute-force settings as upstream creates them.
#
# Reported, not asserted against a hard-coded expectation: the point is to learn what
# a realm created this way carries, which is the closest reachable stand-in for the
# live master realm nobody wants to log into to find out.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq
open_keycloak

kc_token "${KC_ADMIN_USERNAME}" "${KC_PASS_A}"
[[ "${KC_STATUS}" == "200" ]] || fail "cannot authenticate as ${KC_ADMIN_USERNAME} (${KC_STATUS})"

kc_admin "${KC_TOKEN}" GET ""
[[ "${KC_STATUS}" == "200" ]] || fail "GET /admin/realms/master returned ${KC_STATUS}"

jq -r '"  bruteForceProtected=\(.bruteForceProtected)",
       "  failureFactor=\(.failureFactor)",
       "  maxFailureWaitSeconds=\(.maxFailureWaitSeconds)",
       "  waitIncrementSeconds=\(.waitIncrementSeconds)",
       "  permanentLockout=\(.permanentLockout)",
       "  maxTemporaryLockouts=\(.maxTemporaryLockouts)"' <"${HTTP_BODY}"

protected="$(jq -r '.bruteForceProtected' <"${HTTP_BODY}")"
permanent="$(jq -r '.permanentLockout' <"${HTTP_BODY}")"

# A rotation job retries. Whether a wrong guess costs it a lockout is the one thing
# here that changes the design, so it gets a sentence of its own rather than a row.
if [[ "${protected}" == "true" && "${permanent}" == "true" ]]; then
  say "permanent lockout is on: a failed rotation can disable the account outright"
fi

pass "brute-force settings read from the live realm (bruteForceProtected=${protected}, permanentLockout=${permanent})"
