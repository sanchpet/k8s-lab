# Env: onprem-kubeadm

Method: `kind`.
A three-node cluster (one control plane, two workers) whose node layer is wired to pull through an in-cluster registry mirror.

## What it reproduces

- **A non-default cluster DNS domain.** Upstream fleets rarely keep `cluster.local`, and a wrong-domain assumption is one of the cheapest ways to break service resolution — so the domain is a parameter, not a constant.
- **The legacy containerd `registry.mirrors` block**, mirror endpoint first and the real upstream second, with `insecure_skip_verify` for a mirror served over plain HTTP.
- **Fall-through when the mirror is down.** The mirror does not exist while the cluster boots, and pulls succeed anyway via upstream — which is exactly why "the pull worked" proves nothing on its own, and every check must prove the bytes came from the mirror.
- **Node-resolver reachability.** containerd resolves through the node's own resolver, not cluster DNS, so `up.sh` maps the mirror Service FQDN to its pinned ClusterIP in each node's `/etc/hosts`.

Site-specific values (domain, mirror address, namespaces) come from `.env`; the tracked template is generic.

## Where it deviates from a real kubeadm fleet

- `containerdConfigPatches` apply to **every** node, while a fleet usually scopes the mirror block to workers only (already noted in `kind.yaml.tmpl`).
- The mirror config is baked in at cluster creation, not delivered by config management to running nodes — so this env cannot answer "what happens while the config rolls out".
- The mirror's ClusterIP is **pinned** in `.env`; a real fleet gets it from the Service and must survive it changing.
- Plain HTTP plus `insecure_skip_verify` sidesteps the certificate trust chain a real mirror needs — CA distribution to nodes is out of scope here by construction.
- The node layer is kind's: shared kernel, container "nodes", Docker bridge networking (see `methods/kind/README.md`).

## Why the node image is pinned where it is

kind ships the control plane and the container runtime in one artifact, so choosing a node image chooses both.
Published images pair recent Kubernetes with containerd 2.x, where the legacy `registry.mirrors` block no longer exists — the very thing this env exists to reproduce.
The pin therefore favours fidelity of the node layer over fidelity of the control-plane version, because the subject under test lives in the node layer.
Do not "update" `K8S_VERSION` without deciding which fidelity you are trading away.

Known deviation: the fleet this env imitates runs the containerd 1.6 branch, while the stand runs 1.7.
Both carry the legacy mirror block and `config_path`, so mirror semantics are expected to match, but the difference is recorded rather than assumed away.
