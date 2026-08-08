#!/usr/bin/env bash
# The audience and subject in the token are the ones the generator asked for.
#
# Proves: the spec is carried into the TokenRequest rather than defaulted away.
# A generator that ignored audiences would still produce a usable-looking token.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl jq base64

claims="$(token_claims)"

aud="$(printf '%s' "${claims}" | jq -r '.aud | if type == "array" then .[0] else . end')"
[ "${aud}" = "${ESO_DEMO_AUDIENCE}" ] \
  || fail "aud is ${aud}, expected ${ESO_DEMO_AUDIENCE}"

want_sub="system:serviceaccount:${ESO_DEMO_NAMESPACE}:${ESO_DEMO_SA}"
sub="$(printf '%s' "${claims}" | jq -r '.sub')"
[ "${sub}" = "${want_sub}" ] || fail "sub is ${sub}, expected ${want_sub}"

pass "aud=${aud} sub=${sub}"
