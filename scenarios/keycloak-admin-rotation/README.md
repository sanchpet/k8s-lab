# Scenario — rotating the Keycloak bootstrap admin password

## What is under test

A fleet runs Keycloak with its administrator credential delivered as `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` from a Secret, and wants that password rotated on a schedule.
Two things have to be known before such a job can be written, and neither can be learned on a live instance: whether rewriting the Secret rotates anything, and how the account's own password is changed through the admin API.

The stand is one Keycloak backed by its own PostgreSQL, in the shape that makes those answers transferable:

- the image ships an `ENTRYPOINT` and the deployment **overrides it**, exactly as the fleet does — a wrapper script is one more place a credential could be read or rewritten, so a stand that lets the entrypoint run is not testing the same program;
- the command is the fleet's, minus tracing: `kc.sh start --http-port=8080 --hostname-strict=false --verbose --import-realm`;
- the database is on a PVC, so the Keycloak pod can be restarted against the *same* PostgreSQL — without that, every restart is a fresh install and the first experiment measures nothing.

## Image

`KEYCLOAK_IMAGE` defaults to `quay.io/keycloak/keycloak:26.3.2`, because a registry host identifies a fleet and this repo stays generic.
Point it at your own build in `.env` to run the same checks against it.

Both were run here and the five checks give identical results on each, which is the useful part: the answers below are properties of Keycloak 26.3, not of one build of it.

## Environment

Runs on `envs/onprem-kubeadm` because a scenario must name an env, not because it needs that construction — nothing here touches the node layer.
The images are side-loaded through `$LAB_LOAD_IMAGE`, so that env's mirror wiring, which points at a Service this scenario does not deploy, is never exercised.

## Run

```sh
mise run lab keycloak-admin-rotation      # up, apply, check
mise run check keycloak-admin-rotation    # checks alone, against a stand already applied
```

Run the checks through the task, not directly.
They refuse to start otherwise: without `KUBECONFIG` from the task, `kubectl` falls through to the ambient config, whose current context on an engineer's laptop is a real cluster.

The suite is re-runnable.
Every check that moves a password puts it back, including on the failure path, so a second run starts from the same state as the first.
What it cannot repair is a run killed mid-flight — the Secret and the database can then disagree, and `mise run apply` resets only the Secret. Delete the namespace and re-apply.

## Checks

| Check | What it proves |
|---|---|
| `01-bootstrap-token.sh` | The bootstrap credential authenticates: password grant, `admin-cli`, realm `master`. Everything after this assumes it, and it is also what fails first if a previous run left a password nobody put back. |
| `02-secret-rotation-alone.sh` | **Rewriting the Secret and restarting rotates nothing.** Password B goes into the Secret, the pod restarts against the same PostgreSQL (asserted: the database pod's UID is unchanged), and A still authenticates while B does not. |
| `03-admin-api-self-reset.sh` | The admin API does rotate it, in place: token → user id → `PUT .../reset-password` → the new password works and the old one does not, both proven with **fresh** grants. |
| `04-minimal-role-for-self-reset.sh` | The full admin composite is not required. A throwaway user with no admin role gets 403, with `master-realm:view-users` still 403, with `master-realm:manage-users` 204. |
| `05-master-brute-force-defaults.sh` | Reads the master realm's brute-force settings as upstream creates them — reported, not asserted, because the point is to learn what the live realm most likely carries. |

Check 02 is the one that decides the shape of any rotation job.
The others describe the mechanism it has to use instead.

## What the checks establish

**`KC_BOOTSTRAP_ADMIN_PASSWORD` is not the credential; it is a seed.**
It is consumed once, when the master realm does not yet exist, and never read again — upstream documents this and the stand confirms it on both images.
The evidence is stronger than the token codes: the restarted container has B in its environment (`printenv` inside the pod) and its startup log contains no `KC-SERVICES0077 Created temporary admin user` line at all.
So a rotation job that writes the Secret and restarts the pod produces no error, no log line, and no rotation — and leaves the Secret disagreeing with the database, which is worse than doing nothing, because the next reader believes the Secret.

**The password is user state in PostgreSQL, and only the admin API moves it.**
`PUT /admin/realms/master/users/{id}/reset-password` with `{"type":"password","value":"…","temporary":false}` returns 204 and takes effect immediately for new grants.
Tokens already issued are not revoked — they stay valid until they expire, which is why every "the old password is dead" assertion here uses a fresh grant.
The Secret still has to be updated too, but as a *record* of the rotation rather than its mechanism, and the ordering matters: the API call is the point of no return.

**Reading is a separate right from writing.**
A rotation job needs both, because it starts from a username and the endpoint takes an id.
`manage-users` happens to carry both; `view-users` carries only the lookup.

## What this stand cannot tell you

- **The live master realm's brute-force settings.** Check 05 reads a realm created by this version of Keycloak with no configuration applied to it. If anyone has ever touched those settings on the live instance, the numbers differ and only the live instance knows.
- **Whether the live admin is still the bootstrap user.** The account created this way is registered as a *temporary* admin. An instance whose administrator was later recreated properly may behave differently in ways this stand, which never does that, cannot show.
- **Federation and password policy.** The master realm here has no policy, no LDAP, no required actions. A policy that rejects the generated password turns the 204 into a 400, and a rotation job has to handle that.
- **Concurrency.** One replica, one rotation at a time. Nothing here says what two schedulers racing on the same account do.

## Caveats of the stand

Keycloak crash-loops once or twice on a cold apply while PostgreSQL finishes initialising — there is no init container, and the restart is the wait.
It is visible as a non-zero `RESTARTS` on the first rollout and is not a symptom of anything.

`KC_HTTP_ENABLED=true` is set in the deployment: `start` refuses to serve plain HTTP otherwise, and `--http-port` only chooses the port.
`KC_DB*` are set there too — the estate's own image bakes them in at build time, the upstream base does not, and setting them explicitly is what makes the two images interchangeable here.
