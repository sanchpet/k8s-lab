#!/usr/bin/env bash
# Harbor answers the registry v2 ping and its token service issues a token.
#
# Proves: Harbor itself is a working registry endpoint. Everything downstream
# assumes this, so failing here tells you not to bother reading the other checks.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl curl jq

open_harbor

# Unauthenticated ping must be a challenge, not a success and not a 404.
status="$(curl -sS -o "${REG_BODY}" -D "${REG_HEADERS}" -w '%{http_code}' "${HARBOR_BASE}/v2/")"
if [[ "${status}" != "401" ]]; then
  fail "GET /v2/ returned ${status}, expected a 401 Bearer challenge"
fi

challenge="$(_header_value "${REG_HEADERS}" 'www-authenticate')"
realm="$(_challenge_param "${challenge}" realm)"
if [[ -z "${realm}" ]]; then
  fail "401 carried no Bearer realm: ${challenge}"
fi
say "challenge: ${challenge}"

# The realm Harbor advertises comes from externalURL. It must name the entry
# point clients arrive through, not Harbor itself — that is what keeps the auth
# leg inside the shim. We can only reach it here through the port-forward, so the
# authority is rewritten and the path kept.
say "advertised realm: ${realm}"

reg_get "${HARBOR_BASE}" "/v2/"
if [[ "${REG_STATUS}" != "200" ]]; then
  fail "GET /v2/ with a token returned ${REG_STATUS}, expected 200"
fi

service="$(_challenge_param "${challenge}" service)"
local_realm="${HARBOR_BASE}$(printf '%s' "${realm}" | sed -E 's#^[a-zA-Z]+://[^/]+##')"
token_json="$(curl -sS --get --data-urlencode "service=${service}" "${local_realm}")"
token="$(printf '%s' "${token_json}" | jq -r '.token // .access_token // empty')"
if [[ -z "${token}" ]]; then
  fail "token endpoint returned no token: ${token_json}"
fi

say "token endpoint: ${local_realm}"
say "token: ${#token} bytes, expires_in $(printf '%s' "${token_json}" | jq -r '.expires_in // "unset"')s"
pass "/v2/ challenges, the token service issues a token, and /v2/ then returns 200"
