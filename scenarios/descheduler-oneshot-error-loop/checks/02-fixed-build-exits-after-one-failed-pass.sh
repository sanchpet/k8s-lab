#!/usr/bin/env bash
# A build carrying the fix ends the process after the first failed pass.
#
# Proves: with the same policy and environment the build exits on its own with a
# non-zero status after one failed pass. Skipped, loudly, when no fixed
# build is named.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

[ -n "${DESCHEDULER_FIX_REF}" ] || skip "DESCHEDULER_FIX_REF is empty; set it (and DESCHEDULER_FIX_REPO) to check a fix"
require_tools kubectl python3

bin="$(build_descheduler "${DESCHEDULER_FIX_REPO:-${DESCHEDULER_REPO}}" "${DESCHEDULER_FIX_REF}")"
r="$(run_loop "fix:${DESCHEDULER_FIX_REF}" "${bin}")"
printf '%s\n' "${r}"

[ "$(jget "${r}" exited_on_its_own)" = "true" ] \
  || fail "the fixed build was still running after ${DESCHEDULER_LOOP_LIMIT_SECONDS} s"
# The returned error is reported twice, by the server and by cli.Run; a loop logs it on every pass.
[ "$(jget "${r}" error_lines)" -le 2 ] \
  || fail "the fixed build logged the error $(jget "${r}" error_lines) times, expected one pass"
[ "$(jget "${r}" exit)" -ne 0 ] \
  || fail "the fixed build exited 0 after a failed pass; a Job would count it as success"

pass "exited $(jget "${r}" exit) after one failed pass in $(jget "${r}" wall_s) s, $(jget "${r}" cpu_s) s CPU"
