#!/usr/bin/env bash
# ESO produced a Secret carrying a token and the expiry the issuer assigned.
#
# Proves: the generator reached the TokenRequest API at all. Everything below
# assumes this, so failing here means the other checks say nothing.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl base64

token="$(secret_key token)"
[ -n "${token}" ] || fail "the Secret has no token key"

# A JWT, not an opaque string: three dot-separated segments.
[ "$(printf '%s' "${token}" | awk -F. '{print NF}')" = "3" ] \
  || fail "the token is not a JWT (expected three segments)"

expiry="$(secret_key expirationTimestamp)"
[ -n "${expiry}" ] || fail "the Secret has no expirationTimestamp key"
printf '%s' "${expiry}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' \
  || fail "expirationTimestamp is not RFC3339: ${expiry}"

pass "token issued, expires at ${expiry}"
