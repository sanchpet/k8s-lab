# scenario: descheduler-oneshot-error-loop

A descheduler started with `--descheduling-interval=0` does not exit when its pass fails: it starts the next pass immediately, forever.

## What it reproduces

`--descheduling-interval=0` is the one-shot mode, meant for a Job or a CronJob: do one pass and exit.
When the pass returns an error, the run loop returns without cancelling its context, so the process stays alive and the loop calls the pass again with no delay.
The result is a core held at 100% and the same error logged hundreds of thousands of times a second, and the Job never completes.

The failing pass here is the in-cluster ServiceAccount token read.
A Prometheus metrics provider without `authToken` makes the descheduler read the in-cluster token on every pass; with the service host/port set and no token file mounted (a pod with `automountServiceAccountToken: false` sees exactly this) the read fails.
The binary is production code, unmodified; only those two environment variables are the driver's.

## Code

- `pkg/descheduler/descheduler.go:486-491` @ v0.37.0: the pass function calls `reconcileInClusterSAToken()` on every pass; its error goes back to the run loop.
- `pkg/descheduler/descheduler.go:688-690` @ v0.34.0: the same branch returns the error without `cancel()`, so v0.34.0 loops as well; the behaviour predates the release under test, which is why the older tag is part of the checks.

## Run

```sh
mise run lab descheduler-oneshot-error-loop
```

`apply` builds `DESCHEDULER_VERSION` and `DESCHEDULER_COMPARE_VERSION` from source into `.cache/descheduler/` (needs Go; keyed by commit), and the fixed build too when `DESCHEDULER_FIX_REF` is set (`DESCHEDULER_FIX_REPO` takes a URL or a local path; empty means the same repo).
Nothing is deployed to the cluster and no image is loaded: the failing pass needs only an API server to start against.
`check` can be repeated on the same stand; each run is a fresh process.

The process runs on the host rather than as the official image in a pod, so that the checks read its exit status, CPU time and stderr directly, and so that a fork branch is just another build.
Port 10258 (the descheduler's metrics endpoint) must be free.

## What the checks prove

| Check | Claim |
|---|---|
| `01-failing-pass-does-not-exit` | at `DESCHEDULER_VERSION` and at `DESCHEDULER_COMPARE_VERSION` the process is still running after `DESCHEDULER_LOOP_LIMIT_SECONDS`, has logged at least 10 000 token errors and used at least half the limit in CPU |
| `02-fixed-build-exits-after-one-failed-pass` | a build from `DESCHEDULER_FIX_REF` exits on its own having logged the error once; skipped, loudly, when unset |

Reference numbers from an arm64 laptop, 10 s limit: v0.34.0 and v0.37.0 both ran to the limit, about 11 s of CPU, 3.0-3.6 million error lines, 60 MiB RSS; a build with the fix exited by itself in 0.2-1.3 s with one error line.

## Reading the numbers

Look at "exited on its own" first; the rest is its consequence.
The line count and CPU say how expensive the loop is, and the line count is only an order of magnitude: it moves 20-30% with background load because the loop speed does.
CPU above wall time is normal, the loop occupies a core and the logging goroutines take part of another.

## Where it lies

- The exit code of the fixed build is 0, as it is on the `cancel()` path of older releases, so a CronJob would see success for a failed pass.
  The check asserts that the process ends, not that the status is informative.
- The error is reproduced through the token path with an environment trick, not through a real pod; the claim is about the run loop, which any failing pass reaches, and not about this one error.
- A failure inside the descheduling itself (as opposed to the token read) takes a different branch of the loop and is not exercised here.

## Parameters

| Variable | Meaning |
|---|---|
| `DESCHEDULER_REPO` | source of the releases |
| `DESCHEDULER_VERSION`, `DESCHEDULER_COMPARE_VERSION` | the release under test and an older one |
| `DESCHEDULER_FIX_REPO`, `DESCHEDULER_FIX_REF` | optional build carrying a fix; both tracked values stay empty |
| `DESCHEDULER_LOOP_LIMIT_SECONDS` | how long a process gets to exit on its own |
