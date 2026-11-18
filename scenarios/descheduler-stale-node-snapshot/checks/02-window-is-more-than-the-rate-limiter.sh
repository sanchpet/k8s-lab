#!/usr/bin/env bash
# The staleness window is made by the client rate limit and by serial evictions.
#
# Proves two things from the same stand: lifting the limit shortens the pass, so the
# limiter is part of the window; and the window does not close, so it is not only
# the limiter. The floor is one synchronous Eviction call at a time.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl python3 envsubst

d="$(measure default-rate)"
c="$(measure qps-1000 --client-connection-qps=1000 --client-connection-burst=1000)"
printf '%s\n%s\n' "${d}" "${c}"

n="${DESCHEDULER_STALE_REPLICAS}"
# (pods - burst) / qps: what the default limiter alone costs. A run that beats it by a
# wide margin did not hit the limiter, and says nothing about it.
floor="$(python3 -I -c "print(max(0, ($n - $CLIENT_DEFAULT_BURST) / $CLIENT_DEFAULT_QPS) * 0.8)")"
num_ge "$(jget "${d}" pass_duration_s)" "${floor}" \
  || fail "default-rate pass took $(jget "${d}" pass_duration_s) s, under the limiter's floor of ${floor} s"
[ "$(jget "${d}" throttled_requests)" -gt 0 ] || fail "no throttled request logged at the default rate"

num_ge "$(jget "${d}" pass_duration_s)" "$(jget "${c}" pass_duration_s)" \
  || fail "lifting the limit did not shorten the pass"
[ "$(jget "${c}" throttled_requests)" -eq 0 ] || fail "requests were still throttled at qps/burst 1000"
[ $(( $(jget "${c}" evictions_after_taint_removed) * 2 )) -gt "$(jget "${c}" evicted)" ] \
  || fail "with the limit lifted most evictions were no longer stale: the window is the limiter alone"

pass "pass $(jget "${d}" pass_duration_s) s at the default rate, $(jget "${c}" pass_duration_s) s at qps/burst 1000; still $(jget "${c}" evictions_after_taint_removed) of $(jget "${c}" evicted) stale at 1000 (median gap $(jget "${c}" median_gap_between_evictions_s) s per eviction)"
