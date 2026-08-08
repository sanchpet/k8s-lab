# env: sa-token-capped

A plain kind cluster whose API server carries
`--service-account-max-token-expiration`.

## What it reproduces

One thing: a control plane that shortens ServiceAccount token lifetimes without
telling the client. A `TokenRequest` asking for more than the cap comes back with
less, and nothing in the response is an error — the only evidence is the expiry
that was returned. Any client that treats `expirationSeconds` as a grant rather
than a request is wrong on this cluster and right on a default one, which is why
the flag belongs to the construction and not to a scenario.

## Where it lies

- **The cap cannot go below one hour.** The API server refuses to start otherwise:
  `the service-account-max-token-expiration must be between 1 hour and 2^32
  seconds`. A stand that wants to show a shortening therefore has to request more
  than an hour, not cap below one. `SA_TOKEN_MAX_EXPIRATION=1h` is the tightest
  setting that runs, and it is the default here.
- **The node image is kind's own default.** This env reproduces an API server flag,
  not a fleet, so pinning a Kubernetes version would add a variable with no bearing
  on what is measured. An env that cares about the node layer should pin it.
- **One cluster at a time.** `CLUSTER_NAME` is read from the single `.env` shared by
  every env, so switching between this stand and another means editing that value
  and bringing the previous cluster down.

## Parameters

| Variable | Meaning |
|---|---|
| `CLUSTER_NAME` | cluster and kubeconfig name; set it to something that does not collide with another stand |
| `SA_TOKEN_MAX_EXPIRATION` | the cap, as a Go duration; one hour or more |
