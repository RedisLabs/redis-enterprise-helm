# Changelog

This file lists the changes in each release of the `redis-iris` Helm chart,
which installs the Redis Iris on-prem suite as one Helm release.

`redis-iris` and its seven product charts share one version number. Every
release moves all of them to the same version, including charts that did not
change. Release candidates (`X.Y.Z-rc.N`) are published for `redis-iris` only.
See [Releases and support](README.md#releases-and-support) for the support
window, and [Values compatibility](README.md#values-compatibility) for what a
minor release may change in your values.

## 1.0.1

A patch release of the 1.0 line. Every product chart moves to `1.0.1`, with
`appVersion` and default image tags also `1.0.1`, changed or not.

### Linux ARM64

Every image of the suite is now published for `linux/amd64` and `linux/arm64`
under the same tag, as one multi-platform image index; each node pulls the image
of its own platform. When you mirror images, copy the whole index (for example
`skopeo copy --all`), or nodes of the other platform cannot pull it. See
[Air-gapped installs](README.md#air-gapped-installs).

### Agent Memory queue monitor

The optional queue monitor (`memory.controlplane.queueMonitor`) runs Asynqdash
(`ghcr.io/jpedrosouza/asynqdash:1.2.0`), an Asynqmon fork that publishes both
platforms, instead of `hibiken/asynqmon:0.7.2`, which is `linux/amd64` only.

- The default registry moves from Docker Hub to the GitHub Container Registry:
  mirror the new image, or allow `ghcr.io`, before you upgrade.
- Its Deployment, Service and Ingress are renamed from
  `redis-agent-memory-asynqmon` to `redis-agent-memory-asynqdash`. Update any
  NetworkPolicy, monitoring rule or script that matches the old names.
- The new optional `memory.controlplane.queueMonitor.redis.usernameKey`
  (default `REDIS_USERNAME`) names the key of a Redis ACL user in the queue
  monitor's Redis Secret.

### Redis Enterprise TLS

Agent Memory, Lens, Context Gateway and Intent Router accept an optional
`tls_server_name` query parameter on `rediss://` Redis URLs. It verifies the
default Redis Enterprise certificate against a name the certificate covers,
while the suite still connects to the database Service host. Without it,
nothing changes.

### Other changes

- Agent Memory's support package health checks use
  `replicated/troubleshoot:0.134.3`.

### Upgrade and rollback notes

1.0.1 changes no stored data.

- **Upgrade from 1.0.0:** `helm upgrade` with your values files. If the queue
  monitor Ingress is enabled
  (`memory.controlplane.queueMonitor.ingress.enabled=true`), delete its old
  Ingress first. Helm creates the renamed Ingress before it deletes the old one,
  and the ingress-nginx admission webhook rejects a second Ingress on the same
  host and path, so the upgrade fails otherwise:

  ```bash
  kubectl -n redis-ai delete ingress redis-agent-memory-asynqmon
  ```

  The queue monitor UI is unreachable until the upgrade completes; the products
  are not affected.
- **Roll back to 1.0.0:** on `linux/arm64` nodes it is not possible, because the
  1.0.0 images are `linux/amd64` only; roll back only clusters whose nodes are all
  `linux/amd64`. With the queue monitor Ingress enabled, first run
  `kubectl -n redis-ai delete ingress redis-agent-memory-asynqdash`.

These are exceptions to the rule that every patch of a minor upgrades and rolls
back across every other ([Releases and support](README.md#releases-and-support)).

## 1.0.0 (2026-11-05)

The first release of `redis-iris`. Install it fresh: no earlier `redis-iris`
version was released, so there is no upgrade path into 1.0.0.

### Image digests

The chart pulls images by tag (`1.0.0`), not by digest, and Docker Hub tags are
not guaranteed to be immutable. To run exactly the images that were tested for
this release, or to mirror them into a private registry, use the digests in the
[1.0.0 release notes](https://github.com/RedisLabs/redis-enterprise-helm/blob/master/ai/releases/redis-iris/1.0.0.md).

### Products

Every product chart is version `1.0.0` from `https://helm.redis.io/ai`, with
`appVersion` and default image tags also `1.0.0`. Each one requires Kubernetes
1.28 or later and uses the shared library chart `redis-iris-onprem-lib` 0.5.0.

| Chart | Previous release | Notes |
| --- | --- | --- |
| `iris-identity-service` | `0.10.2` | Now released together with the other products. |
| `redis-agent-memory` | `0.10.2` | Data-plane token validation is opt-in; see [Memory data-plane token validation](#memory-data-plane-token-validation). |
| `redis-agent-playbook` | `0.10.2` | |
| `redis-lens` | `0.10.2` | |
| `redis-context-gateway` | `0.10.2` | |
| `redis-intent-router` | none | First release. Images: `redislabs/iris-intent-router-control` and `redislabs/iris-intent-router-data`. |
| `redis-iris-ui` | `0.1.0` | |

Each product's own 1.0.0 changes are listed in the [1.0.0 release notes](https://github.com/RedisLabs/redis-enterprise-helm/blob/master/ai/releases/redis-iris/1.0.0.md).

### Features

- One set of shared settings, `global.iris`: tenant, license, identity provider
  (IdP), role bindings, CA trust, workload identity, and Ingress. If a product
  value conflicts with a shared setting, the install fails and names the value.
- Turn each product on or off with `global.iris.products.<product>.enabled`.
- Let the chart generate credentials, or supply your own Secrets. A `gitops`
  render mode (`global.iris.renderMode: gitops`) renders the suite offline for
  GitOps tools.
- Sign in to the UI through your IdP. If the IdP is unavailable, the
  [Admin Token break-glass procedure](docs/runbooks/iris-onprem-admin-token-break-glass.md)
  switches the UI to Admin Token sign-in.
- Workload identity for the Agent Memory and Agent Playbook workers.
- Extraction from Agent Playbook into Agent Memory, enabled with
  `global.iris.extraction.enabled`.
- Rolling upgrades that keep ready capacity, PodDisruptionBudgets, and a suite
  preflight check you can run before installing.
- Runbooks shipped with the chart:
  [Redis operations](docs/runbooks/iris-onprem-redis-operations.md),
  [disaster recovery](docs/runbooks/iris-onprem-disaster-recovery.md), and
  [uninstall](docs/runbooks/iris-onprem-uninstall.md).

### Memory data-plane token validation

The Agent Memory data plane validates IdP access tokens only when you set
`memory.memory.auth.oidc.enabled=true`; the suite does not turn it on for you.
When it is on, the data plane takes the issuer, JWKS, role claims, and role
mappings from `global.iris.auth.oidc` and `global.iris.auth.roleBindings`. The
install fails if you also set a different local `issuer`, `jwks_uri`,
`role_claims`, or `role_mappings`, or set `allow_insecure_transport: true`
while `global.iris.auth.oidc.jwksURI` is an `https://` URL.

If you install `redis-agent-memory` on its own: enabling `memory.auth.oidc`
without `issuer` and `jwks_uri` now fails the install, instead of leaving the
data plane in a crash loop. This does not apply when `config.existingSecret` or
`config.render=false` is set. A secret overlay (`secrets.secretName`) does not
count: if yours supplies `issuer` and `jwks_uri`, move them to
`memory.auth.oidc.*` values before you upgrade (they are not secrets).

### Upgrade and rollback notes

None for 1.0.0: it is the first release, so there is nothing to upgrade from or
roll back to.

From 1.1.0, every minor release that changes how the suite stores or reads its
data in Redis (queued jobs and their retries, grants, indexes, updates, and
deletes) lists each change here, with what the new version reads and writes,
when any background data migration is complete, and what happens if you roll
back to the previous minor release. Patch releases never change stored data.

### Moving from ingress-nginx to Traefik

Community ingress-nginx is not supported: it was
[retired in March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/).
Traefik v3 is the tested and supported controller (browser sign-in redirects,
request size limits, streaming, and data-plane routing); other controllers are
best effort. To move a cluster that runs ingress-nginx:

1. Install Traefik v3 alongside ingress-nginx, with its own IngressClass
   (for example `traefik`).
2. Point every Ingress the suite creates at it:
   `global.iris.ingress.className` (the UI), `memory.ingress.className` if
   Agent Memory's Ingress is enabled (its standalone default is `nginx`), and
   `contextGateway.dataplane.ingress.className` if the Context Gateway's Ingress
   is enabled. Remove any `nginx.ingress.kubernetes.io/*` annotations you added.
   Do not move the Agent Memory queue monitor Ingress
   (`memory.controlplane.queueMonitor.ingress`): its sign-in works only on
   ingress-nginx, so on Traefik the queue monitor would be open to anyone.
   Turn it off (`memory.controlplane.queueMonitor.ingress.enabled=false`) and use
   `kubectl port-forward`, or add your own authentication in front of it.
3. Lower the DNS TTL of each host beforehand, and plan a short maintenance
   window: from the upgrade until DNS points at Traefik, requests that still
   reach ingress-nginx are not routed. Run `helm upgrade` with those values,
   then move DNS for each host to Traefik's address. Check that IdP sign-in
   through the UI and the Context Gateway's public endpoint work.
4. Remove ingress-nginx once nothing routes through it.
