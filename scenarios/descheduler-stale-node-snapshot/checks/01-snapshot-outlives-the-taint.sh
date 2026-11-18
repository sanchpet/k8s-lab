#!/usr/bin/env bash
# Evictions keep coming after the taint is gone from the API server.
#
# Proves: the node list, with its taints, is fixed when the pass starts and nothing
# re-reads it before the next eviction. Taint removal is timed against the first
# eviction, so "after" is by construction of the trigger: what carries the claim is
# that the stale decisions are the rest of the pass, and that the node is clean
# on the API server the whole time they are issued.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl python3 envsubst

r="$(measure default-rate)"
printf '%s\n' "${r}"

[ "$(jget "${r}" node_taints_after)" = "" ] || fail "the taint is still on the node, so nothing was removed"
evicted="$(jget "${r}" evicted)"
after="$(jget "${r}" evictions_after_taint_removed)"
[ "${evicted}" -eq "${DESCHEDULER_STALE_REPLICAS}" ] \
  || fail "evicted ${evicted} of ${DESCHEDULER_STALE_REPLICAS}: the pass did not run to the end"
# More than half the pods evicted off a node that was already clean: not noise.
[ $(( after * 2 )) -gt "${evicted}" ] \
  || fail "only ${after} of ${evicted} evictions came after the taint was removed"
num_ge "$(jget "${r}" taint_removed_to_last_eviction_s)" 1 \
  || fail "the window after removal is under a second, too short to be the effect"

pass "${after} of ${evicted} evictions issued after the taint was removed; the node was clean for $(jget "${r}" taint_removed_to_last_eviction_s) s of the pass"
