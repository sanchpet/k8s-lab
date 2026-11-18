# scenario: descheduler-stale-node-snapshot

`RemovePodsViolatingNodeTaints` keeps evicting pods for taints a node no longer carries.

## What it reproduces

descheduler reads the node list once per pass and hands the same objects to every plugin.
The taint plugin decides for each pod against `node.Spec.Taints` of that snapshot, then evicts it, and nothing re-reads the node in between.
A taint that is applied for a few seconds and then removed (a storage HA controller doing a failover is the real-world case) can therefore be acted on for the whole length of a pass that started while it was present.

The scenario puts 60 pods without tolerations on one worker, taints it, starts one pass (`--descheduling-interval=0`), and removes the taint on the first `Evicted pod` log line.
The rest of the pass is evictions off a node that is already clean on the API server.

## Code (v0.37.0, 0756d2fc3b78ec05e0ae80a7748fb0f9fa29bc30)

- `pkg/descheduler/descheduler.go:265` reads the nodes from the informer indexer once per cycle, `:272` filters Ready ones, `:287` passes the slice to every Deschedule plugin.
- `pkg/framework/plugins/removepodsviolatingnodetaints/node_taint.go:112` loops over that slice, `:113` lists the node's pods once, `:124` decides on `node.Spec.Taints` of the snapshot, `:126` evicts.
- `pkg/framework/plugins/defaultevictor/defaultevictor.go:438-439` is the only node re-read on the evictor path; it is behind `nodeFit` (off by default) and does not look at the current node's taints.
- `pkg/descheduler/evictions/evictions.go:519-520` takes a mutex, `:637` makes a synchronous Eviction call inside it: evictions are serial.
- `pkg/descheduler/client/client.go:65-66` copies `--client-connection-qps/burst` into the client; both default to 0, so client-go's 5 QPS / 10 burst apply.

## Run

```sh
mise run lab descheduler-stale-node-snapshot
```

`apply` builds descheduler at `DESCHEDULER_VERSION` into `.cache/descheduler/` (needs Go; the cache is keyed by commit), side-loads the pause image, and puts the pods on `<CLUSTER_NAME>-worker`.
`check` can be repeated on the same stand: every measurement first removes the taint and recreates the Deployment.

The process runs on the host rather than as the official image in a pod.
The checks need the exit status and the log of a single pass with exact flags, and the same code path with a different tag is just another build.

## What the checks prove

| Check | Claim |
|---|---|
| `01-snapshot-outlives-the-taint` | more than half of the evictions are issued after the taint is gone from the API server, over a window of at least a second |
| `02-window-is-more-than-the-rate-limiter` | at the default rate the pass is bound by `(pods - burst) / qps` and logs throttling; at qps/burst 1000 it is shorter, unthrottled, and still stale |

Reference numbers from the same stand on an arm64 laptop (kind, 60 pods): default rate, pass 10.0 s, 58-59 of 60 after removal; qps/burst 1000, pass 5.9-6.6 s, 59 of 60 after removal, median 0.10 s between evictions.

## Reading the numbers

The meaningful quantities are the window (`taint_removed_to_last_eviction_s`) and the fact that nothing re-checks the node during it.
The window is the number of pods times the larger of the rate-limit interval and the per-call latency.
The limiter is part of it: 10.0 s at the default is exactly `(60 - 10) / 5`.
It is not all of it: with the limit lifted the window stays, because evictions are serial and each is one API round trip.
It grows linearly with the pods on the node.

## Where it lies

- "59 of 60 after removal" is by construction of the trigger: the taint is removed right after the first eviction.
  In an incident the taint lives for whatever it lives; what carries over is the window length and the absence of a re-check.
- Latency is kind's on a laptop, so the per-eviction gap and the absolute window differ from a real API server; the checks assert relations between runs, not absolute seconds.
- Replacement pods are Pending while the taint is on and land back on the node afterwards; the same pass does not evict them again, because pods were listed once.

## Parameters

| Variable | Meaning |
|---|---|
| `DESCHEDULER_REPO`, `DESCHEDULER_VERSION` | source and tag of the build under test |
| `DESCHEDULER_STALE_REPLICAS` | pods on the tainted node; scales the window |
| `DESCHEDULER_PAUSE_IMAGE` | image of the victims, side-loaded into the nodes |
