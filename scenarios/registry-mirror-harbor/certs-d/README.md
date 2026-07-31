# Wiring mode B — containerd `certs.d`

The alternative to the nginx shim.

A Harbor proxy-cache project serves exactly one upstream and is addressed by path prefix, so somebody has to put `dockerhub-proxy/` in front of `library/alpine`.
Mode A has a proxy guess it by trying each project in turn.
Mode B has the client do it: `override_path = true` tells containerd that the path in the host URL *is* the registry API root, and everything after `/v2/` is appended to it.

The guessing disappears, and with it both of the shim's weaknesses — no sequential lookups on a miss, and no chance of serving `busybox` from the wrong upstream because two of them happen to publish that path.
The cost is that the mapping now lives on every node instead of in one Deployment, so changing it is a fleet-wide config rollout rather than a `kubectl apply`.

## Installing on a node

The fragments here are templates; `${HARBOR_ENDPOINT}` is the `host:port` at which the node reaches Harbor.

```sh
HARBOR_ENDPOINT=$(kubectl -n "$HARBOR_NAMESPACE" get svc harbor -o jsonpath='{.spec.clusterIP}'):80

for f in certs-d/*/hosts.toml.tmpl; do
  d=/etc/containerd/certs.d/$(basename "$(dirname "$f")")
  mkdir -p "$d"
  HARBOR_ENDPOINT="$HARBOR_ENDPOINT" envsubst < "$f" > "$d/hosts.toml"
done
```

containerd only reads the directory once it is pointed at it:

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

`config_path` and the legacy `registry.mirrors` block are mutually exclusive — `config_path` wins and the legacy block is ignored, so leaving it in place is a trap for the next person reading the config.
Delete it in the same change.
containerd re-reads `hosts.toml` per request, so adding or editing a fragment needs no restart; changing `config_path` in `config.toml` does.

## Two things that change on a real fleet

**Harbor is addressed by name, not by ClusterIP.**
On the stand the ClusterIP is the only stable handle a node has.
A fleet gives Harbor a DNS name and a certificate; the host URL becomes `https://<harbor>/v2/<project>`, and an internal CA goes next to the fragment as `ca = "/etc/containerd/certs.d/<upstream>/ca.crt"`.

**`externalURL` moves.**
Mode A needs Harbor's token realm to point at the shim, because the client entered through the shim and the auth leg must come back through it.
Mode B has no shim in the path, so the realm has to name Harbor itself — otherwise the token request is sent somewhere the node may not even be able to reach.
Set `externalURL` in `harbor-values.yaml.tmpl` to Harbor's own address before testing this mode.

## Why this migration happens regardless

`registry.mirrors` has been deprecated since containerd 1.5 and is gone in containerd 2.x.
Whichever registry the fleet ends up with, the node configuration moves to `certs.d`.
That makes mode B the cheaper of the two in the long run: the migration is owed anyway, and doing it once buys the path rewriting for free.
