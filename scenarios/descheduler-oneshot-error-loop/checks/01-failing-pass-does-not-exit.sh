#!/usr/bin/env bash
# With --descheduling-interval=0 a failing pass restarts at once instead of ending.
#
# Proves: the process is still running when the limit expires, has logged the same
# error tens of thousands of times and kept a core busy. Both the release under test
# and the older one are run: the older one is the baseline that shows the behaviour
# is not new in the release.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

require_tools kubectl python3

summary=""
for version in "${DESCHEDULER_VERSION}" "${DESCHEDULER_COMPARE_VERSION}"; do
  bin="$(build_descheduler "${DESCHEDULER_REPO}" "${version}")"
  r="$(run_loop "${version}" "${bin}")"
  printf '%s\n' "${r}"

  [ "$(jget "${r}" exited_on_its_own)" = "false" ] \
    || fail "${version} exited by itself after $(jget "${r}" wall_s) s (exit $(jget "${r}" exit)); no loop"
  lines="$(jget "${r}" error_lines)"
  [ "${lines}" -ge "${MIN_ERROR_LINES}" ] \
    || fail "${version} logged ${lines} token errors in ${DESCHEDULER_LOOP_LIMIT_SECONDS} s; either the pass is not the failing one or it is not looping"
  # CPU close to wall time: a busy loop, not a process waiting on a timer.
  num_ge "$(jget "${r}" cpu_s)" "$(python3 -I -c "print(0.5 * ${DESCHEDULER_LOOP_LIMIT_SECONDS})")" \
    || fail "${version} used $(jget "${r}" cpu_s) s of CPU in ${DESCHEDULER_LOOP_LIMIT_SECONDS} s; it was not busy"
  summary="${summary} ${version}: ${lines} error lines, $(jget "${r}" cpu_s) s CPU;"
done

pass "still running at ${DESCHEDULER_LOOP_LIMIT_SECONDS} s on both:${summary%;}"
