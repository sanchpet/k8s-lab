#!/usr/bin/env bash
# The API server shortened the requested lifetime, and only the returned expiry says so.
#
# Proves the failure mode the generator's documentation warns about: expirationSeconds
# is a request, not a grant. This cannot be observed against a fake client — the
# controller-runtime fake hardcodes the expiry and ignores the request entirely — so
# it is the one claim that needs a real API server to stand behind it.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl jq base64

claims="$(token_claims)"
iat="$(printf '%s' "${claims}" | jq -r '.iat')"
exp="$(printf '%s' "${claims}" | jq -r '.exp')"
granted=$(( exp - iat ))

cap="$(seconds_from_duration "${SA_TOKEN_MAX_EXPIRATION}")"
requested="${ESO_DEMO_REQUESTED_SECONDS}"

[ "${requested}" -gt "${cap}" ] \
  || fail "the stand asks for ${requested}s under a ${cap}s cap — it cannot show a shortening"

[ "${granted}" = "${cap}" ] \
  || fail "token lived ${granted}s, expected the cap of ${cap}s"

pass "requested ${requested}s, API server granted ${granted}s (cap ${cap}s) — shortened without an error"
