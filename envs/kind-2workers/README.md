# env: kind-2workers

Method: `kind`.
A plain cluster: one control plane, two workers, default node image, no extra configuration.

## What it reproduces

Only a place to move pods between nodes.
The workers are named `<CLUSTER_NAME>-worker` and `<CLUSTER_NAME>-worker2`; scenarios address them by those names.

## Where it lies

- The node layer is kind's: shared kernel, container "nodes", Docker bridge networking (see `methods/kind/README.md`).
- Control-plane and API-server latency are those of a laptop, not of a fleet; anything that measures a duration measures this stand's latency and says so.
- `CLUSTER_DOMAIN` is required by the `kind` method but not applied here; the cluster keeps `cluster.local`.
