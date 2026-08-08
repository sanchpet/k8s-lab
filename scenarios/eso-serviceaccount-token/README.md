# scenario: eso-serviceaccount-token

External Secrets Operator issuing a Kubernetes ServiceAccount token through the
`TokenRequest` API, measured against a control plane that caps token lifetimes.

## What is under test

A build of ESO carrying a `ServiceAccountToken` generator, loaded into the cluster
from a local archive rather than pulled from a registry: the point is to exercise a
change that exists only in a working tree.

The scenario applies a ServiceAccount, a `ServiceAccountToken` generator that asks
for two hours, and an `ExternalSecret` that consumes it, then reads the token out of
the resulting Secret.

## What the checks prove

| Check | Claim |
|---|---|
| `01-token-issued` | the generator reached the TokenRequest API and produced a JWT plus the expiry the issuer assigned |
| `02-claims-match-the-request` | `aud` and `sub` are the ones the spec asked for, rather than defaults |
| `03-lifetime-capped-silently` | the request for 7200s came back as 3600s, with no error anywhere |

The third is the reason this scenario exists. It cannot be observed against the
controller-runtime fake client, which hardcodes the returned expiry and ignores
`expirationSeconds` and `audiences` entirely, so a unit test cannot stand behind the
claim that a caller must read the expiry it got back.

## Where it lies

- **The token's signature is never verified.** The checks ask what the API server put
  in the token, not whether the token would be accepted. Conflating the two would let
  a well-formed token with the wrong claims pass.
- **A single cluster.** Carrying the value on to a second cluster through `PushSecret`
  exercises propagation, which ESO already does and which is not what this measures.

## Parameters

| Variable | Meaning |
|---|---|
| `ESO_CHART_DIR` | chart of the build under test |
| `ESO_IMAGE_ARCHIVE` | `docker save` archive of that build |
| `ESO_IMAGE_REPOSITORY`, `ESO_IMAGE_TAG` | how that image is named inside the nodes |
| `ESO_DEMO_*` | namespace, ServiceAccount, Secret, audience and requested lifetime |

`ESO_DEMO_REQUESTED_SECONDS` must exceed the env's cap, or `03` fails on purpose:
a stand that asks for less than the cap cannot show a shortening.
