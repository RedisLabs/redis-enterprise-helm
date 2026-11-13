# redis-iris

The Redis Iris on-prem suite as one Helm release: the Identity Service, Agent
Memory, Agent Playbook, Lens, Context Gateway, Intent Router, and the on-prem UI.

Each release pins all seven product charts at its own version from
`https://helm.redis.io/ai`; 1.0.0 was the first. What each release changes is in
[`CHANGELOG.md`](CHANGELOG.md). The operations runbooks ship with the chart under
[`docs/runbooks/`](docs/runbooks/).

## Install

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm repo update redis-ai
helm search repo redis-ai/redis-iris --versions          # pick the latest patch of a supported minor
helm pull redis-ai/redis-iris --version <version> --untar   # the examples/ values files and docs/ runbooks
```

1. Check the cluster with the [suite preflight](#suite-preflight), and create the
   Secrets each example's header lists (name, key, and contents). The examples
   are starting points: replace their noop embedding and inference models and
   example hosts with your own.
2. Choose the products and values (see [Suite values](#suite-values) and
   [Product selection](#product-selection)), then install:

   ```bash
   helm install iris redis-ai/redis-iris --version <version> --namespace redis-ai --create-namespace \
     -f redis-iris/examples/memory-only.yaml -f redis-iris/examples/playbook.yaml \
     -f redis-iris/examples/lens.yaml -f redis-iris/examples/context-gateway.yaml \
     -f redis-iris/examples/intent.yaml
   helm test iris --namespace redis-ai --logs
   ```

3. Keep this chart version and your values files: a rollback, and the
   [Admin Token break-glass path](docs/runbooks/iris-onprem-admin-token-break-glass.md),
   need both (`NOTES.txt` prints the `helm pull` command).

## Supported environment

| Item | Requirement |
| --- | --- |
| Kubernetes | 1.28 or later (`kubeVersion: ">=1.28.0-0"` on every chart); the suite preflight checks it. |
| Helm | Helm 3, 3.10 or later, for install, upgrade, and rollback. The charts lint on Helm 4.3.1; full Helm 4 support arrives in 1.1. |
| Distributions | Certified: kind and EKS. Best effort: GKE, AKS, and other conformant distributions. Unsupported until 1.1: OpenShift. |
| Architecture | linux/amd64 and linux/arm64 from 1.0.1: every image tag is one multi-platform index. 1.0.0 is linux/amd64 only. |
| Ingress | Your controller, with TLS. Traefik v3 is the qualified controller; community ingress-nginx is not supported (see [`CHANGELOG.md`](CHANGELOG.md), "Moving from ingress-nginx to Traefik"). |
| FIPS | Not in 1.0: `global.security.profile: fips` fails the install. FIPS arrives in 1.1. |

## Air-gapped installs

Mirror these images by digest. Each release's digests are recorded in its
[release notes](https://github.com/RedisLabs/redis-enterprise-helm/tree/master/ai/releases/redis-iris) (`<version>.md`, and `<version>.json` for tools),
and every tag equals the product version:

| Product | Images |
| --- | --- |
| Identity Service | `redislabs/iris-identity-service` |
| Agent Memory | `redislabs/agent-memory`, `redislabs/agent-memory-control-plane` |
| Agent Playbook | `redislabs/iris-agent-playbook-data`, `redislabs/iris-agent-playbook-control` |
| Lens | `redislabs/iris-lens-data`, `redislabs/iris-lens-control` |
| Context Gateway | `redislabs/iris-context-gateway-data`, `redislabs/iris-context-gateway-control` |
| Intent Router | `redislabs/iris-intent-router-data`, `redislabs/iris-intent-router-control` |
| UI | `redislabs/iris-ui-gateway`, `redislabs/iris-ui-auth` |

The suite also runs two public helper images: `python` (`3.13-alpine`) for
`helm test` (`tests.suiteVerify.image.repository`), and `curlimages/curl` for
the preflight (`preflight.image.repository`) and the Identity Service's
`helm test` Pod (`identityService.tests.image`, a full image reference such as
`<mirror>/curlimages/curl:8.17.0`). The other products' own test hooks are off
by default. Agent Memory's support package health checks run
`replicated/troubleshoot` (`memory.supportPackage.healthCheckImage`), and its
optional queue monitor runs `ghcr.io/jpedrosouza/asynqdash` from 1.0.1
(`memory.controlplane.queueMonitor.image`; `hibiken/asynqmon` on Docker Hub in
1.0.0). Point each product image's
`repository` at your mirror under its product's alias (for example
`memory.image.repository`). `helm template` with your values lists every image
the release uses: mirror that list.

From 1.0.1 every image is a multi-platform index (`linux/amd64` and
`linux/arm64`). Copy the whole index, for example with `skopeo copy --all` or
`crane copy`, so that nodes of both platforms can pull it; a single-platform
copy fails on the other platform's nodes.

## Components

| Alias | Chart | Fixed name | Condition |
| --- | --- | --- | --- |
| `identityService` | `iris-identity-service` | `iris-identity-service` | always installed |
| `memory` | `redis-agent-memory` | `redis-agent-memory` (`-controlplane`, `-worker`) | `global.iris.products.memory.enabled` |
| `playbook` | `redis-agent-playbook` | `redis-agent-playbook-controlplane`, `-dataplane` | `global.iris.products.playbook.enabled` |
| `lens` | `redis-lens` | `redis-lens-dataplane` (9000), `-worker`, `-controlplane` (9300) | `global.iris.products.lens.enabled` |
| `contextGateway` | `redis-context-gateway` | `redis-context-gateway-controlplane` (9100), `-dataplane` (8083) | `global.iris.products.contextGateway.enabled` |
| `intent` | `redis-intent-router` | `redis-intent-router-controlplane` (9400), `-dataplane` (9401) | `global.iris.products.intent.enabled` |
| `ui` | `redis-iris-ui` | `iris-ui` | always installed |

Each product's values sit under its alias and keep the meaning the product's
own README gives them. The names are fixed (`fullnameOverride`) so the products
reach each other, and the UI reaches them, by Service name in the release
namespace, whatever the release is called. The UI derives its upstream hosts
from those names and the release namespace (`products[].upstream.service`).

## Suite values

The main product and feature switches, in one place; [`values.yaml`](values.yaml)
points here. Every other value sits under its product's alias (see
[Components](#components)) and keeps the meaning the product's README gives it.

| Key | Default | Prerequisites | Example | Meaning |
| --- | --- | --- | --- | --- |
| `global.iris.products.memory.enabled` | `true` | Secrets `mem-secrets`, `cluster-ca`; `memory.secrets.secretName` (or `memory.secrets.additionalSecrets`, `memory.config.existingSecret`) | [`memory-only.yaml`](examples/memory-only.yaml) | Install Agent Memory |
| `global.iris.products.playbook.enabled` | `true` | `playbook.storage.existingSecret` (two distinct Redis deployments), `playbook.inference.models`, and `playbook.inference.existingSecret` unless every model is `noop` | [`playbook.yaml`](examples/playbook.yaml) | Install Agent Playbook |
| `global.iris.products.lens.enabled` | `true` | `lens.storage.existingSecret` (the data-plane and control-plane storage overlays) | [`lens.yaml`](examples/lens.yaml) | Install Lens |
| `global.iris.products.contextGateway.enabled` | `true` | `contextGateway.publicBaseURL` (an `https://` origin, never derived from `global.iris.publicURL`); `contextGateway.metadataDB.existingSecret`; the references of the selected `contextGateway.credentialStorage.provider`; and either `contextGateway.dataplane.ingress` or your own routing to `redis-context-gateway-dataplane:8083` | [`context-gateway.yaml`](examples/context-gateway.yaml) | Install Context Gateway |
| `global.iris.products.intent.enabled` | `true` | `intent.storage.existingSecret` (the control-plane and data-plane storage overlays, the data plane's Redis with Search); exactly one `intent.inference.models` entry; `intent.inference.existingSecret` unless the model is `noop` | [`intent.yaml`](examples/intent.yaml) | Install Intent Router |
| `ui.sso.enabled` | `true` | `global.iris.auth.oidc.{issuer,jwksURI}`, `global.iris.publicURL`, `ui.sso.{clientId,clientCredential.existingSecret,redis.existingSecret}` | [`single-product.yaml`](examples/single-product.yaml) | IdP login in the UI; `false` is Admin Token mode, the [break-glass path](docs/runbooks/iris-onprem-admin-token-break-glass.md) |
| `ui.ingress.enabled` | `true` | `global.iris.publicURL` (the host); `global.iris.ingress.{className,tls.secretName}` | [`single-product.yaml`](examples/single-product.yaml) | The UI Ingress |
| `global.iris.tenantId` | `default` | | | The release's one tenant, in every product and the Identity Service |
| `global.iris.license.{existingSecret,secretKey}` | `iris-license`, `license.key` | The license Secret | [`memory-only.yaml`](examples/memory-only.yaml) | One suite license for every product |
| `global.iris.clusterDomain` | `cluster.local` | | | Completes every in-cluster URL the suite derives and the default workload identity issuer |
| `global.iris.auth.oidc.*` | issuer empty; audience `api://redis-iris`; roleClaims `[groups]` | | [`single-product.yaml`](examples/single-product.yaml) | The IdP, once, for the UI, the control planes, and Identity Service Control; `accessTokenIssuer` defaults to `issuer`. An `http://` `jwksURI` needs `identityService.configData.profile=dev` and makes every product fetch the IdP keys without TLS: development and test clusters only |
| `global.iris.auth.roleBindings` | `[]` | Suite scope: `suite_admin` only; product scope: `product_admin`, `operator`, or `viewer` with `product` | [`single-product.yaml`](examples/single-product.yaml) | Operator policy, translated for every consumer; a disabled product's bindings are kept and emitted again on re-enable |
| `memory.memory.auth.oidc.enabled` | `false` | `global.iris.auth.oidc.{issuer,jwksURI}` | | Memory's data plane validates IdP access tokens too (opt-in; the suite never turns it on). Its issuer, JWKS, role claims, and role mappings come from `global.iris.auth.oidc` and `global.iris.auth.roleBindings`; a differing local `issuer`, `jwks_uri`, `role_claims`, `role_mappings`, or `allow_insecure_transport: true` against an https JWKS fails the render |
| `global.iris.workloadIdentity.{issuer,jwksURI}` | `https://kubernetes.default.svc.<clusterDomain>`, `<issuer>/openid/v1/jwks` | EKS must set both | | The issuer the Memory and Playbook workers' and the Playbook control plane's ServiceAccount tokens are verified against |
| `global.iris.extraction.enabled` | `false` | Both products; `playbook.worker.{existingSecret,region}`; chart-rendered Memory configs and Playbook control-plane config (no `config.existingSecret`); anonymous issuer discovery on kubeadm/kind (see [Install-time checks](#install-time-checks)) | [`extraction.yaml`](tests/kind/products/extraction.yaml) | Playbook → Memory extraction: the Playbook worker and connection, and Memory's trust in the Playbook worker (reads) and control plane (source ownership). To turn it off, pause or delete the extraction bindings first, then set `false`; the bindings stay in Playbook's Redis |
| `global.tls.caCertSecret` | `""` | | [`single-product.yaml`](examples/single-product.yaml) | CA trust for Redis, the IdP, and in-cluster TLS, in every product and ui-auth |
| `global.iris.renderMode` | `helm` | `gitops` needs `secrets.generate: false` | [`full-suite-gitops.yaml`](examples/full-suite-gitops.yaml) | `helm` (install/upgrade) or `gitops` (offline render) |
| `global.iris.secrets.generate` | `true` | `helm install` or `helm upgrade` (`lookup`) | [`memory-only.yaml`](examples/memory-only.yaml) | Generate the suite credentials (see [Credentials](#credentials)) |
| `global.iris.secrets.dataplaneServiceCredentials.existingSecret` | `""` | `generate: false`; keys `memory-dp`, `playbook-dp`, `lens-dp`, `context-gateway-dp`, `intent-dp` for the enabled products | [`byo-gitops.yaml`](examples/byo-gitops.yaml) | Supplied data-plane credentials |
| `global.iris.secrets.controlplaneInternalTokens.existingSecret` | `""` | `generate: false`; keys `memory`, `playbook`, `lens`, `context-gateway`, `intent` for the enabled products | [`byo-gitops.yaml`](examples/byo-gitops.yaml) | Supplied control-plane internal tokens |
| `tests.suiteVerify.databaseId` | `"1"` | A key of Memory's `databases` registry | | The database `helm test` creates its temporary store in |

These values are the only input for what the products share. The product
charts derive their tenant, license, CA, OIDC settings, role mappings,
Identity Service wiring, worker identity, and UI routes from them (TDD
MOD-19479, "Values precedence"). A product value that differs from the one
derived fails the render and names the field: remove it. The Identity Service
registrations and the UI routes follow the product switches, so a product's
`enabled` flag is all it takes to switch it off (see
[Product selection](#product-selection)).

### Not yet supported

| Feature | Key | Status |
| --- | --- | --- |
| FIPS | `global.security.profile: fips` | The install fails; planned for redis-iris 1.1 |

## Credentials

With `global.iris.secrets.generate: true` (the default) the umbrella generates
every suite credential once, as a `pre-install,pre-upgrade` hook Secret that
renders only while `lookup` finds no Secret of that name, with
`helm.sh/resource-policy: keep`. The product charts' own generators are off.
Each product gets its own data-plane credential and internal token Secrets, so
enabling a product on upgrade creates its Secrets without touching existing ones.

| Secret | Key | Consumers (each mounts only its key) |
| --- | --- | --- |
| `iris-memory-dataplane-credential` | `memory-dp` | Memory data plane, Identity Service (introspection credential) |
| `iris-memory-internal-token` | `memory` | Memory control plane, Identity Service (grant validation) |
| `iris-memory-admin-token` | `token` | Memory control plane (admin API) |
| `iris-playbook-dataplane-credential` | `playbook-dp` | Playbook data plane, Identity Service (introspection credential) |
| `iris-playbook-internal-token` | `playbook` | Playbook control plane, Identity Service (grant validation) |
| `iris-playbook-admin-token` | `token` | Playbook control plane and data plane (admin API) |
| `iris-lens-dataplane-credential`, `iris-lens-internal-token`, `iris-lens-admin-token` | `lens-dp`, `lens`, `token` | Lens data plane, control plane, and Identity Service, as for Memory |
| `iris-context-gateway-dataplane-credential`, `iris-context-gateway-internal-token`, `iris-context-gateway-admin-token` | `context-gateway-dp`, `context-gateway`, `token` | Context Gateway data plane, control plane, and Identity Service, as for Memory |
| `iris-intent-dataplane-credential`, `iris-intent-internal-token`, `iris-intent-admin-token` | `intent-dp`, `intent`, `token` | Intent Router data plane, control plane, and Identity Service, as for Memory |
| `iris-identity-service-control-token` | `token` | Identity Service (Control API) |
| `iris-ui-session-key` | `key` | UI auth (only with `ui.sso.enabled`) |

Because the values never enter the release manifest:

- `helm upgrade` keeps them, and so does `helm rollback`: a rotated or revoked
  value is never restored.
- To rotate one, change the Secret in place. Memory and the Identity Service
  re-read the mounted file on each request, so the old value stops working once
  the kubelet syncs the volume (about a minute), with no restart. The UI session
  key is the exception: ui-auth reads it at startup, so roll it out
  (`kubectl rollout restart deployment/iris-ui-auth`), which signs everyone out.
- `helm uninstall` leaves them behind and a reinstall reuses them. Delete them
  yourself to start from scratch:
  `kubectl delete secret -l app.kubernetes.io/component=credentials,app.kubernetes.io/name=redis-iris`.

To bring your own value, create the Secret under the same name before
installing. Pointing a product's `controlplane.adminToken.existingSecret`
(`memory`, `playbook`, `lens`, `contextGateway`, `intent`),
`identityService.control.existingSecret`, or `ui.sso.session.existingSecret` at
another Secret suppresses that generated Secret.

Generation needs `lookup`, so it only works under `helm install` /
`helm upgrade`, not `helm template` or GitOps renderers.

### Supplied credentials and GitOps

For an offline render (`helm template`, Argo CD, Flux), set
`global.iris.renderMode: gitops` and `global.iris.secrets.generate: false`:
no `lookup` runs and no hook renders, so every render is identical. Supply the
two aggregates through `global.iris.secrets.dataplaneServiceCredentials` and
`global.iris.secrets.controlplaneInternalTokens` (`existingSecret`), with one
key per enabled product (`<product>-dp`; `<product>`); the products and the
Identity Service derive their references from them and mount only their own
key. A missing key is not caught offline: that product's Pod fails to start.
Name the admin token, Control token, and session key Secrets through their
product references. [`examples/byo-gitops.yaml`](examples/byo-gitops.yaml) adds
supplied credentials to the product examples;
[`examples/full-suite-gitops.yaml`](examples/full-suite-gitops.yaml) is the
whole suite with IdP login, extraction, and Context Gateway's Vault credential
storage, layered on `examples/memory-only.yaml`. The render tests render it
twice and compare.

## Install-time checks

`templates/validate.yaml` fails `helm install` and `helm template` with the field
to fix when no product is enabled, Memory is enabled without
`memory.secrets.secretName` (or `memory.config.existingSecret`), `identityService.enabled` is set (the
Identity Service is always installed), a component's `fullnameOverride` differs
from its fixed name (see [Components](#components)), a component's Service port differs from
its fixed port (`identityService.service.port` 9200, `memory.service.port` 9000,
`memory.controlplane.service.port` 9100, `playbook.controlplane.service.port` 9200,
`playbook.dataplane.service.port` 9201), `lens.instance.id` is not `default` (the UI's
Lens route queries that instance), a product `tls.caCertSecret` differs from a set
`global.tls.caCertSecret`, `global.security.profile` is `fips`
(planned for 1.1), `renderMode: gitops` is combined with generated credentials,
a supplied aggregate is set with `generate: true` or missing (or shared) with
`generate: false`, or SSO is on with `generate: false` and no
`ui.sso.session.existingSecret`. Product charts render first, so their own
guards can report a problem before these do. Under the umbrella the Playbook
chart's guards name their `playbook.*` field: `playbook.storage.existingSecret`,
`playbook.license.existingSecret`, `playbook.inference.models`, and
`playbook.inference.existingSecret` when a model's provider is not `noop`.
With `global.iris.extraction.enabled`, `validate.yaml` also requires both products and
Playbook's default Memory audiences (`playbook.extraction.connection.ramControlPlaneAudience`
`api://memory-cp`, `playbook.worker.sourceTokenAudience` `api://memory-dp`), and Playbook names
a missing `playbook.worker.existingSecret` or `playbook.worker.region`. It also refuses a
bring-your-own config Secret (`memory.config.existingSecret`,
`memory.controlplane.config.existingSecret`, `playbook.controlplane.config.existingSecret`):
the derived trust and extraction settings land only in the configs the charts render.

### Suite preflight

The [troubleshoot.sh](https://troubleshoot.sh) preflight in Secret `iris-preflight`
(`preflight.enabled`, default `true`) checks the cluster before an install. It replaces Agent
Memory's own preflight, which the umbrella turns off (`memory.preflight.enabled: false`). It reads no
Secret value, prints none, and creates no RBAC.

| Check | Outcome |
| --- | --- |
| Kubernetes version | Fails below 1.28 |
| Baseline sizing: 3 worker nodes, 12 vCPU and 24 GiB allocatable on them in total | Warns below each (provisional figures, pending load tests). Nodes with the `node-role.kubernetes.io/control-plane` label are left out; cordoned or otherwise tainted nodes still count |
| Metrics API (`metrics.k8s.io/v1beta1`) | Warns when it is missing: the HPAs cannot scale |
| Ingress class, with `ui.ingress.enabled` and `global.iris.ingress.className` set | Fails when no IngressClass of that name exists |
| Credential keys, with `global.iris.secrets.generate: false` | Fails for each enabled product whose key (`<product>-dp`, `<product>`) is missing or empty in the supplied aggregate. A collector Pod mounts only those keys and prints `key-<key>=present`, `empty`, or `missing` |
| Workload identity, when a plane fetches the JWKS | Below |

### Workload identity preflight

The Memory and Playbook planes verify ServiceAccount tokens against
`global.iris.workloadIdentity` and fetch its JWKS without a credential. The preflight
checks, from a Pod in the release namespace, that the configured issuer equals the
cluster's ServiceAccount issuer and that the JWKS is reachable anonymously, once per plane that
fetches it (Agent Memory; Agent Playbook with extraction) with the CAs that plane trusts: the system
CAs plus its `tls.caCertSecret` or `global.tls.caCertSecret`. Agent Playbook alone without extraction
fetches no JWKS, so these checks are left out then. For the in-cluster issuer, that Secret
must hold the cluster CA (ConfigMap `kube-root-ca.crt`); without it the check fails. A mismatched issuer
fails, naming the configured one; on EKS set both `global.iris.workloadIdentity` fields to the
cluster's OIDC issuer (`aws eks describe-cluster --query cluster.identity.oidc.issuer`). A JWKS the
cluster refuses anonymously (kubeadm, kind) fails and prints the grant to apply, which the chart
never creates:

```sh
kubectl create clusterrolebinding <namespace>-issuer-discovery \
  --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated
```

With the [`kubectl preflight`](https://troubleshoot.sh/docs/#installation) plugin (v0.124.0 or
later: older versions do not collect IngressClasses, so the ingress class check only warns), run it before
installing (the namespace must exist):

```sh
helm template iris redis-ai/redis-iris -n <namespace> -f values.yaml --show-only templates/preflight.yaml \
  | yq '.stringData["preflight.yaml"]' | kubectl preflight -
```

or after installing: `kubectl preflight secret/<namespace>/iris-preflight`.

## Product selection

Every product is on by default, each with its own values file:
[`examples/memory-only.yaml`](examples/memory-only.yaml),
[`examples/playbook.yaml`](examples/playbook.yaml),
[`examples/lens.yaml`](examples/lens.yaml),
[`examples/context-gateway.yaml`](examples/context-gateway.yaml), and
[`examples/intent.yaml`](examples/intent.yaml). The Identity
Service registrations and the UI routes follow the enabled products. To switch
a product off, set its flag; a disabled product needs none of its inputs:

| Selection | Values |
| --- | --- |
| Every product (default) | `memory-only.yaml`, `playbook.yaml`, `lens.yaml`, `context-gateway.yaml`, `intent.yaml` |
| Memory and Playbook | the first two, plus `--set global.iris.products.lens.enabled=false --set global.iris.products.contextGateway.enabled=false --set global.iris.products.intent.enabled=false` |
| One product | its file (and `memory-only.yaml` for the suite license and Identity Service metadata), plus `enabled=false` for every other product |

Context Gateway's data plane is public: MCP clients reach it at
`contextGateway.publicBaseURL`. Either enable `contextGateway.dataplane.ingress`
(its host must be the `publicBaseURL` host, path `/` with `pathType: Prefix`, no
rewrite annotation, and a TLS entry with a `secretName` for that host), or set it
to `false` and route that origin to `redis-context-gateway-dataplane:8083`
yourself. The UI reaches its control plane through `/api/context-gateway` either way.
Each Gateway advertises `<publicBaseURL>/iris/data/v1/context-gateway/gateways/<gatewayId>/mcp`.

Intent Router keeps one embedding model per installation (`intent.inference.models`,
exactly one entry); a Router's vector space must be that model. Its storage Secret holds
a control-plane overlay (the Router metadata Redis) and a data-plane overlay (the data
plane's Redis, which needs Search, and the mailbox, normally the control plane's metadata
Redis); register customer databases in both with the same ids (`intent/helm` README,
"Storage"). The UI derives the `intent` route, shown in navigation as the console at
`/intent`, and the hidden `intent-data` route the console calls for intents and matching;
a `ui.products` entry with `showInNavigation: false` hides the console.

Switching a product off keeps its generated Secrets (`resource-policy: keep`),
so switching it back on reuses them. With no product enabled the render fails.

### Removing a product for good

Switching a product off keeps its credentials and its data, so switching it on again resumes where
it stopped. To remove it for good (a new install of it starts empty, with new credentials):

1. Set `global.iris.products.<product>.enabled: false` and upgrade.
2. Delete its generated Secrets:
   `kubectl -n <namespace> delete secret iris-<id>-dataplane-credential iris-<id>-internal-token iris-<id>-admin-token`,
   where `<id>` is `memory`, `playbook`, `lens`, `context-gateway`, or `intent`.
3. Delete its data by key pattern, on every Redis its Secrets name. A database can hold other
   products' data too (the KinD fixture shares one Redis between the Identity Service, Memory's
   metadata, store and job queue, the Playbook worker's queue, and the other products' metadata), so
   flush or delete a whole database only after checking that no other component's Secret names it.
   Never delete `iris:*` or `asynq:*`: they include the Identity Service's keys
   (`iris:apikey:*`, `iris:subject-grants:*`, `iris:subject-grant-sets:*`) and the other products' queues.

   | Product | Key patterns (default prefixes) | Where |
   | --- | --- | --- |
   | Agent Memory | `iris:memory:*`, `{iris:memory:*` | metadata (`metadata.namespace`) and the job idempotency URL |
   | | `memory:*`, `memory-write:*`, `{memory-write:*` | its store databases (`databases`) |
   | | `asynq:{ram:*` | its job queue (`background_jobs.redis`, `queue_prefix`) |
   | Agent Playbook | `iris:playbook:*` | metadata and `storage.content` (`playbook.storage.keyPrefix`) |
   | | `asynq:{playbook-extraction:*`, `playbook-queue-admission:{playbook-extraction:*` | the worker's queue (`playbook.worker.queuePrefix`) |
   | Lens | `iris:lens:*` | metadata (`lens.storage.keyPrefix`) |
   | | `lens:*` | the streams, content, and index Redis |
   | Context Gateway | `iris:context-gateway:*` | metadata |
   | | `context-gateway/*` | the credential storage Redis (`credentialStorage.basePath`), with `credentialStorage.provider: redis` |
   | Intent Router | `iris:intent:*` | metadata, the mailbox, and the Router databases (`intent.storage.keyPrefix`) |

   Put the connection to the database you clean in `R`, the same URL its Secret holds, and give it to
   every `redis-cli` below: the one `xargs` starts is a separate process and would otherwise connect to
   local database 0.

   ```bash
   R=(-u 'rediss://<user>:<password>@<host>:<port>/<db>')   # add --tls --cacert <file> if your Redis needs them
   redis-cli "${R[@]}" --scan --pattern 'iris:context-gateway:*' | xargs -r -n 1 redis-cli "${R[@]}" unlink
   ```

   Run that for each pattern, one key per command: a clustered database (Redis OSS Cluster, the OSS
   Cluster API, Active-Active) refuses a multi-key `DEL` across slots with `CROSSSLOT`, which would leave
   data behind. On a Redis OSS Cluster, `--scan` sees only the node it connects to, so run it against
   each primary.
   For a queue, also remove its queue names from the shared queue set:
   `redis-cli "${R[@]}" smembers asynq:queues`, then `redis-cli "${R[@]}" srem asynq:queues <name>` for
   each `ram:*` (Memory) or `playbook-extraction:*` (Playbook) name.
   Deleting keys leaves Search indexes in place, so also drop the product's indexes:
   `redis-cli "${R[@]}" ft._list`, then `redis-cli "${R[@]}" ft.dropindex <name>` for each that starts
   with one of its prefixes above.

   Context Gateway with another `credentialStorage.provider` keeps its upstream credentials outside
   Redis, named `<credentialStorage.basePath>/tenant/<tenant>/gateway/<gateway>/credentials/<id>`. Delete
   them there too:

   - `vault`: every secret under `<basePath>/` in the KV v2 mount (`credentialStorage.vault.mount`).
     `vault kv list -mount=<mount> <basePath>/tenant/` and the levels below it list them;
     `vault kv metadata delete -mount=<mount> <path>` deletes one with all its versions.
   - `aws_secrets_manager`: every secret whose name starts with `<basePath>/`, in
     `credentialStorage.aws.region`:

     ```bash
     aws secretsmanager list-secrets --region <region> --filters Key=name,Values=<basePath>/ \
       --query 'SecretList[].Name' --output text | tr '\t' '\n' \
       | xargs -r -n 1 aws secretsmanager delete-secret --region <region> --force-delete-without-recovery --secret-id
     ```

`tests/kind.sh UPGRADE_FROM` removes Context Gateway this way and adds it again (MOD-20418).

## Availability

Rolling upgrades and node drains keep every data plane serving:

| Setting | Value | Override |
| --- | --- | --- |
| Data-plane rollout (`memory.server`, `playbook.dataplane`, `lens.dataplane.server`, `contextGateway.dataplane`, `intent.dataplane`) | `strategy: RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1`, also under an HPA | Fixed; another strategy fails the render naming the path |
| `<component>.podDisruptionBudget.enabled` (all seven) | `true`: a PodDisruptionBudget with `maxUnavailable: 1` for each Deployment that keeps more than one Pod (`minReplicas` under autoscaling) | Fixed |
| Replicas | 2: Identity Service, UI gateway (`ui.replicaCount`) and `ui.uiAuth.replicas`, and the Playbook, Lens, Context Gateway and Intent Router data planes; Memory's server and worker (HPA 2–10 and 2–5). 1: the control planes and the Playbook and Lens workers | Yours to size |

A rollout starts one new Pod and removes an old one only when the new one is Ready, so it needs room
for one extra Pod (requests, quota). Without that room it waits, with every old Pod still serving.
A stopping Pod keeps accepting requests for 5 seconds after its SIGTERM, while it leaves its
Services' endpoints, and then finishes the requests in flight within the rest of its 30-second grace period.
A Deployment at one replica gets no PodDisruptionBudget: a drain evicts its Pod. Scale it to two
to keep it serving through drains.

## Local development

```bash
task iris:dev:on          # point the umbrella at local product chart sources
task iris:test:chart      # lint and offline render checks (restores with iris:dev:off)
task iris:test:kind       # install on KinD as release iris in namespace redis-ai
task iris:dev:off         # restore the committed Chart.yaml and Chart.lock
```

`iris:dev:on` rewrites each umbrella entry's `repository` and `version` to the
local source, after building each product chart's own dependencies. Never commit
that state. `iris:test:kind` builds the Identity Service, Memory, Playbook, Lens,
Context Gateway, Intent Router, and UI gateway images (only the selected products') (the UI build needs `NPM_AUTH_TOKEN`, or set `GATEWAY_IMAGE`); see the
header of `tests/kind.sh` for its options (`PRODUCTS` picks the selection). Intent
Router embeds through the KinD model stub's OpenAI-compatible `/v1/embeddings`. It
installs the product examples and runs `helm test`: for each enabled product
`iris-suite-verify` uses the admin token on the control plane (a store, a Playbook,
a Gateway that must advertise `publicBaseURL`, a Router, the Lens instance), mints a
scoped key, uses it on the data plane (Lens read only: Lens keeps what it ingests),
and calls the UI gateway, then removes what it created.
With `PLAYWRIGHT=1` it also runs the Admin Token browser flow
(`iris/ui/tests/sso-e2e/umbrella`).

## Demo install

`examples/memory-only.yaml` and `examples/playbook.yaml` install the suite with
Agent Memory and Agent Playbook as release `iris` in namespace `redis-ai`, with
generated credentials and the UI in Admin Token mode. Their headers list the
Secrets to create first. The command below adds Lens, Context Gateway, and Intent Router
to install all five products. From the repository root, fetch the published 1.0.0
component charts using the committed dependency lock, then install:

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm repo update redis-ai
helm dependency build iris/helm
helm install iris iris/helm --namespace redis-ai -f iris/helm/examples/memory-only.yaml -f iris/helm/examples/playbook.yaml \
  -f iris/helm/examples/lens.yaml -f iris/helm/examples/context-gateway.yaml -f iris/helm/examples/intent.yaml
helm test iris --namespace redis-ai --logs
```

`helm test` creates its temporary store in Memory database `1`; if your Memory
`databases` registry uses another key, set `tests.suiteVerify.databaseId`.

## Releases and support

- **Versions.** `redis-iris` and its seven product charts share one
  `MAJOR.MINOR.PATCH`. Each product's `version`, `appVersion`, and image tags are
  equal. Redis never republishes a released tag; to guarantee the exact image,
  pull by digest (see [Air-gapped installs](#air-gapped-installs)). Every fix moves all seven
  products and `redis-iris` to the next patch, changed or not. Only `redis-iris`
  publishes release candidates (`X.Y.Z-rc.N`, installed with `--devel`); the
  approved candidate is released as `X.Y.Z`.
- **Cadence.** A new minor about monthly, after a 7-day freeze; patches when a
  fix needs one. Each minor has its own release line, `release/iris-on-prem-vMAJOR.MINOR`,
  which carries its candidates, its release, and its patches. A fix made there
  is assessed for every supported minor and forward-ported to ongoing development.
- **Support window.** The current minor receives all fixes; the previous minor
  receives security fixes only; older minors leave support when the next minor
  is generally available. For example, once 1.2.0 is released, 1.2.x receives all
  fixes, 1.1.x security fixes only, and 1.0.x is unsupported. With monthly
  minors a minor is supported for about two months, so plan to upgrade every
  month or two.
- **Upgrades and rollbacks.**
  - Within a minor, every patch is compatible with every other in both
    directions: patches never change a persisted or wire contract. 1.0.1 has
    two exceptions, both in its [`CHANGELOG.md`](CHANGELOG.md) entry: it cannot
    roll back to 1.0.0 on linux/arm64 nodes, and with the Agent Memory queue
    monitor Ingress enabled, upgrading from or rolling back to 1.0.0 needs one
    `kubectl delete ingress` step first.
  - Across minors, upgrade and roll back only between the latest patch of N-1
    and any patch of N. Skipping a minor is unsupported. From 1.1.0 the chart
    refuses a skipped minor on `helm upgrade`; `helm template` and GitOps tools
    cannot check it, so a GitOps install owns that order itself.
  - A minor that changes a persisted contract lists each change, with its
    rollback behavior, in its [`CHANGELOG.md`](CHANGELOG.md) entry.

## Values compatibility

- Removing a values key, or ceasing to accept its old name, needs a major
  version.
- A minor may introduce a new name for a key only if the old name stays accepted,
  with the same behavior, for the rest of that major. `NOTES.txt` names the
  replacement and the earliest major that may remove the old one.
- The previous minor's values files upgrade unchanged, deprecated names included:
  the old name alone and the new name alone behave the same, equal values under
  both are accepted, and conflicting values under both fail with both paths in
  the error.

## Upgrades, rotation, and recovery

Runbooks: [metadata Redis credential rotation and planned outage](docs/runbooks/iris-onprem-redis-operations.md),
[disaster recovery](docs/runbooks/iris-onprem-disaster-recovery.md),
[uninstall and cleanup](docs/runbooks/iris-onprem-uninstall.md), and
[break glass](docs/runbooks/iris-onprem-admin-token-break-glass.md). They ship with the
chart under `docs/runbooks/`.

### Upgrading

Read the target version's [`CHANGELOG.md`](CHANGELOG.md) entry first: it names
any values to add or remove and, for a minor, each persisted contract change and
its rollback behavior. Then upgrade with your values files:

```bash
helm upgrade iris redis-ai/redis-iris --version <version> --namespace redis-ai -f <your values files>
helm test iris --namespace redis-ai --logs
```

Within a minor any patch upgrades to any other. Across minors, first move to
the latest patch of your minor, then upgrade to the next minor (see
[Releases and support](#releases-and-support)). 1.0.0 is the first published
release: the 0.x versions were internal milestones, and there is no upgrade from
them.

### Rotating a credential

Change the Secret in place (see [Credentials](#credentials)). Memory, Playbook,
and the Identity Service re-read the mounted file on each request, so the old
value stops working once the kubelet syncs the volume (about a minute), with no
restart. An upgrade or a rollback keeps the rotated value.

### Rolling back

`helm rollback iris <revision>` restores the workloads and values of that
revision, never a credential: the hook Secrets are not in the release manifest.
Rolling back to a revision without a product removes that product's workloads
and keeps its Secrets, so a later upgrade reuses them. Keep the chart of each
installed version for a rollback without the repository
(`helm pull redis-ai/redis-iris --version <v>`, which `NOTES.txt` prints).

### A failed or interrupted upgrade

- `helm upgrade --atomic` returns to the previous revision by itself when the
  upgrade does not become ready.
- An upgrade whose client was interrupted leaves the release in
  `pending-upgrade`, and every later upgrade is refused. Find the last
  `deployed` revision with `helm history iris -n redis-ai`, then
  `helm rollback iris <that revision> -n redis-ai --wait`.

### Tested baselines

The `upgrade-e2e` job of `iris-onprem-helm-test.yml` upgrades from the previous
stable release as customers have it (MOD-20425): `UPGRADE_FROM`
(`redis-ai/redis-iris@1.0.0`) is pulled from `https://helm.redis.io/ai`, installed
with its own `examples/` and the KinD fixtures in `tests/kind/`, and runs its
published images (each product at its chart's `appVersion`). Raise `UPGRADE_FROM`
in the workflow when a newer stable release is published. The populated upgrade it
runs is described in `tests/kind.sh` (`UPGRADE_FROM`). The release images enforce
the license, so the job signs a temporary one with `LICENSE_PRIVATE_KEY` on every
path. Locally:

```bash
UPGRADE_FROM=redis-ai/redis-iris@1.0.0 EXTRACTION=1 LICENSE_PRIVATE_KEY="$(cat signing.pem)" task iris:test:kind
```

The release train runs the same suite (`workflow_call`) on the packaged chart it
publishes and the published release images, without building anything:

```bash
CHART=/tmp/redis-iris-1.0.0-rc.1.tgz IMAGES=published LICENSE_PRIVATE_KEY="$(cat signing.pem)" task iris:test:kind
```

## Limitations

- FIPS is not supported yet; see [Not yet supported](#not-yet-supported).
- There is no support bundle yet; it arrives in 1.1 and includes both Intent Router images. The
  [air-gapped image list](#air-gapped-installs) and each release's evidence name every image.
