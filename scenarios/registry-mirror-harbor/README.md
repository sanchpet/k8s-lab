# Scenario — replacing a four-upstream pull-through cache with Harbor

## What is under test

A fleet runs one registry as a pull-through cache for `docker.io`, `gcr.io`, `registry.k8s.io` and `quay.io`, behind a single in-cluster endpoint wired into containerd's legacy `registry.mirrors` block.
The proposal is to put Harbor there instead.

The constraint that shapes everything: a Harbor proxy-cache project maps to exactly one upstream, and clients address it by path prefix — `<harbor>/<project>/<image>`.
One flat endpoint serving four upstreams therefore needs the prefix added somewhere, and there are only two places it can go.

**Mode A — a reverse proxy adds it.**
An nginx shim takes over the mirror address and tries the four projects in turn until one answers.
Nothing on the nodes changes.

**Mode B — the client adds it.**
containerd `hosts.toml` with `override_path = true`, one fragment per upstream, pointing at a single Harbor host.
No guessing, but it requires migrating the fleet off the legacy block onto `certs.d`.

This scenario builds both so they can be measured against each other rather than argued about.

## Environment

Runs on `envs/onprem-kubeadm` — a kind cluster with a non-default cluster DNS domain and the legacy containerd mirror block already in place, mirror first and the real upstream second.
That fallback is deliberate and it is the reason check 04 exists: with a working upstream configured behind the mirror, a successful pull proves nothing about where the bytes came from.

All parameters come from `.env` at the repo root (see `.env.example`).
Nothing in this directory names a real fleet.

## Run order

```sh
set -a; . ../../.env; set +a

envsubst < harbor-values.yaml.tmpl > /tmp/harbor-values.yaml
helm upgrade --install harbor harbor/harbor \
  -n "$HARBOR_NAMESPACE" --create-namespace \
  --version "$HARBOR_CHART_VERSION" -f /tmp/harbor-values.yaml

./provision-projects.sh

envsubst < registry-shim.yaml.tmpl | kubectl apply -f -

for c in checks/*.sh; do "$c"; done
```

Order matters in two places.
The shim's own nginx image must be on the nodes before the Service claims `MIRROR_CLUSTER_IP`, or the shim needs the mirror it is about to become.
And `provision-projects.sh` has to run after every Harbor restart, not only the first — see *Statelessness*.

Mode B is wired separately and is documented in `certs-d/README.md`; it also needs `externalURL` repointed at Harbor, since there is no shim in the path to route the token realm through.

## Checks

Each script prints `PASS`/`FAIL` plus the evidence it based that on.

| Check | What it proves |
|---|---|
| `01-harbor-v2-token.sh` | Harbor is a working registry endpoint: `/v2/` returns a Bearer challenge, the token service issues a token, and `/v2/` with that token returns 200. Everything else assumes this. |
| `02-pull-single-arch.sh` | A single-architecture manifest and its config blob come through the shim intact. The blob is re-hashed against the digest the manifest declares, so truncation or rewriting fails here rather than at container start. |
| `03-pull-multiarch.sh` | A manifest list survives as a manifest list — same media type, more than one platform — and each platform's child manifest hashes to the digest that was requested. A proxy that collapses `Accept` or caches one platform for all nodes fails here. |
| `04-served-by-harbor.sh` | **The pull actually went through Harbor.** The repository is deleted from the proxy project, the image is pulled on a node with `imagePullPolicy: Always`, and Harbor is asked whether the artifact came back. If containerd fell through to the upstream, the project is still empty and the check fails. |
| `05-upstream-unreachable.sh` | A cache miss against a dead upstream fails within a bounded time instead of stalling the client, and the node still gets the image via containerd's fallback endpoint. A dead mirror costs throughput, not availability. |
| `06-core-replica-loss.sh` | Losing one Harbor core pod does not interrupt the mirror, so a rolling upgrade or node drain is not an outage. |

Check 04 is the one that decides whether any of the others mean anything.
The rest can pass with Harbor entirely bypassed.

## Statelessness

`persistence.enabled: false` — everything is on `emptyDir`.

The image cache being disposable is fine; that is what a cache is.
What goes with it is the project configuration, which lives in the same PostgreSQL, so a restarted Harbor comes back as an empty Harbor that knows about no upstreams at all.
That is why the four projects are provisioned by `provision-projects.sh` and not through the UI, and why the registry component stays at one replica while core runs two: core's state is in PostgreSQL and Redis and scales out, the registry's cache is node-local and does not.

## Known weaknesses of the shim (mode A)

**Up to four sequential upstream lookups on a miss.**
An image that lives in `quay.io` is asked for at Docker Hub, then gcr.io, then registry.k8s.io first — each a real request to a real upstream, each with its own token handshake, before the right one is tried.
Cold-start latency is roughly four times the honest number, and the three wasted lookups are load applied to upstreams that did nothing wrong.
Ordering the chain by traffic share limits the damage; it does not remove it.

**Wrong-source risk when a path exists in more than one upstream.**
The chain returns the first project that answers, not the correct one.
`busybox` or `nginx` exist under recognisable paths in several registries, and the shim has no way to know which one the caller meant — it will serve whichever comes first in the chain and cache that answer.
The failure is silent: the pull succeeds, the digest is valid, and the image is simply not the one that was asked for.

Both are acceptable on a stand and in dev, where a wrong image is noticed and the latency is paid once.
Neither is acceptable in production, which is the argument for mode B: `certs.d` removes the guessing entirely, and the migration off the legacy `registry.mirrors` block is owed anyway — it is deprecated since containerd 1.5 and gone in 2.x.

## Smaller caveats

The shim does not forward query strings on the rewritten paths, because nginx drops them when the `proxy_pass` target is built from a capture.
Image pulls do not use query parameters, but tag-list and catalog pagination do, so those endpoints are not usable through the shim.

`hosts.toml` and `nginx.conf` and `provision-projects.sh` each carry the same upstream-to-project mapping.
There is one authoritative copy in `_lib.sh` (`UPSTREAMS`), but the two rendered configs cannot read it, so a change has to be made in all three.
