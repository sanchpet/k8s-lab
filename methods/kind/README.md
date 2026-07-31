# Method: kind

Kubernetes nodes as Docker containers on one machine, bootstrapped by kubeadm inside each node image.

## Good for

Anything whose truth lives in the control plane or in node-level *configuration*: containerd registry and TLS settings, kubelet flags, DNS domain, admission and RBAC, controller behaviour, chart rollouts.
Cluster creation is a minute, so a scenario can afford to `reset` between runs instead of reasoning about leftover state.

## Cannot reproduce

- **Node OS and its lifecycle.** The node image is prebaked; there is no provisioning path (PXE, cloud-init, config management), no OS package layer, no upgrade-in-place.
- **A real kernel per node.** All nodes share the host's single Linux kernel (a VM on macOS), so per-node sysctls, modules, cgroup drivers and kernel versions cannot diverge the way they do in a fleet.
- **The dataplane at full fidelity.** Nodes are containers on a Docker bridge: no physical topology, MTU, routing, firewalls or middleboxes, no LoadBalancer, and throughput/latency figures mean nothing.
- **Failure domains.** Node reboot, disk pressure and partitions are approximations on shared resources — useful as a rehearsal, worthless as evidence.

When a question turns on any of the above, the answer is a different method (talos-in-docker, lima+kubeadm), not a cleverer kind config.
