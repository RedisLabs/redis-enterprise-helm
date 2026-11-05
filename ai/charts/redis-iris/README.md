# redis-iris

The Redis Iris on-prem suite as one Helm release: the Identity Service, Agent
Memory, Agent Playbook, Lens, Context Gateway, Intent Router, and the on-prem UI. Design:
[MOD-19479 TDD](../../docs/tdd/MOD-19479-iris-onprem-global-helm-chart.md).

Status: 0.6.0 adds lifecycle and operations (M6, MOD-20385): data planes roll without dropping
ready capacity, PodDisruptionBudgets keep node drains safe, the suite preflight checks the
cluster, and the [Redis operations](../../docs/runbooks/iris-onprem-redis-operations.md),
[disaster recovery](../../docs/runbooks/iris-onprem-disaster-recovery.md), and
[uninstall](../../docs/runbooks/iris-onprem-uninstall.md) runbooks are tested on KinD. 0.5.0 (M5,
MOD-20384) installs every product. The chart is not published yet; it installs from the
repository's local product chart sources.

## Components

| Alias | Chart | Fixed name | Condition |
| --- | --- | --- | --- |
| `identityService` | `iris-identity-service` | `iris-identity-service` | always installed |
| `memory` | `redis-agent-memory` | `redis-agent-memory` (`-controlplane`, `-worker`) | `global.iris.products.memory.enabled` |
| `playbook` | `redis-agent-playbook` | `redis-agent-playbook-controlplane`, `-dataplane` | `global.iris.products.playbook.enabled` |
| `lens` | `redis-lens` (`lens/helm` until published) | `redis-lens-dataplane` (9000), `-worker`, `-controlplane` (9300) | `global.iris.products.lens.enabled` |
| `contextGateway` | `redis-context-gateway` | `redis-context-gateway-controlplane` (9100), `-dataplane` (8083) | `global.iris.products.contextGateway.enabled` |
| `intent` | `redis-intent-router` (`intent/helm` until published) | `redis-intent-router-controlplane` (9400), `-dataplane` (9401) | `global.iris.products.intent.enabled` |
| `ui` | `redis-iris-ui` (`iris/ui/helm`) | `iris-ui` | always installed |

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
| `ui.sso.enabled` | `true` | `global.iris.auth.oidc.{issuer,jwksURI}`, `global.iris.publicURL`, `ui.sso.{clientId,clientCredential.existingSecret,redis.existingSecret}` | [`single-product.yaml`](examples/single-product.yaml) | IdP login in the UI; `false` is Admin Token mode, the [break-glass path](../../docs/runbooks/iris-onprem-admin-token-break-glass.md) |
| `ui.ingress.enabled` | `true` | `global.iris.publicURL` (the host); `global.iris.ingress.{className,tls.secretName}` | [`single-product.yaml`](examples/single-product.yaml) | The UI Ingress |
| `global.iris.tenantId` | `default` | | | The release's one tenant, in every product and the Identity Service |
| `global.iris.license.{existingSecret,secretKey}` | `iris-license`, `license.key` | The license Secret | [`memory-only.yaml`](examples/memory-only.yaml) | One suite license for every product |
| `global.iris.clusterDomain` | `cluster.local` | | | Completes every in-cluster URL the suite derives and the default workload identity issuer |
| `global.iris.auth.oidc.*` | issuer empty; audience `api://redis-iris`; roleClaims `[groups]` | | [`single-product.yaml`](examples/single-product.yaml) | The IdP, once, for the UI, the control planes, and Identity Service Control; `accessTokenIssuer` defaults to `issuer`. An `http://` `jwksURI` needs `identityService.configData.profile=dev` and makes every product fetch the IdP keys without TLS: development and test clusters only |
| `global.iris.auth.roleBindings` | `[]` | Suite scope: `suite_admin` only; product scope: `product_admin`, `operator`, or `viewer` with `product` | [`single-product.yaml`](examples/single-product.yaml) | Operator policy, translated for every consumer; a disabled product's bindings are kept and emitted again on re-enable |
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
Secrets to create first. With the product
charts not yet published, install from local sources:

```bash
task iris:dev:on
helm install iris iris/helm --namespace redis-ai -f iris/helm/examples/memory-only.yaml -f iris/helm/examples/playbook.yaml \
  -f iris/helm/examples/lens.yaml -f iris/helm/examples/context-gateway.yaml -f iris/helm/examples/intent.yaml \
  --set memory.image.tag=<tag> --set memory.controlplane.image.tag=<tag> \
  --set playbook.controlplane.image.tag=<tag> --set playbook.dataplane.image.tag=<tag> \
  --set lens.dataplane.image.tag=<tag> --set lens.controlplane.image.tag=<tag> \
  --set contextGateway.dataplane.image.tag=<tag> --set contextGateway.controlplane.image.tag=<tag> \
  --set intent.dataplane.image.tag=<tag> --set intent.controlplane.image.tag=<tag> --set ui.image.tag=<tag>
helm test iris --namespace redis-ai --logs
task iris:dev:off
```

`helm test` creates its temporary store in Memory database `1`; if your Memory
`databases` registry uses another key, set `tests.suiteVerify.databaseId`.

## Upgrades, rotation, and recovery

Runbooks: [metadata Redis credential rotation and planned outage](../../docs/runbooks/iris-onprem-redis-operations.md),
[disaster recovery](../../docs/runbooks/iris-onprem-disaster-recovery.md),
[uninstall](../../docs/runbooks/iris-onprem-uninstall.md), and
[break glass](../../docs/runbooks/iris-onprem-admin-token-break-glass.md).

### Upgrading from 0.5.0

0.6.0 changes no input; the 0.5.0 values upgrade unchanged. It fixes the data-plane rollout strategy
and turns on PodDisruptionBudgets (see [Availability](#availability)); a values file that sets
another `strategy` or turns a `podDisruptionBudget` off now fails the render. The Identity Service,
the UI gateway and ui-auth, and the Playbook, Lens, Context Gateway, and Intent Router data planes
move to two replicas, so the cluster runs more Pods: size it with the [suite preflight](#suite-preflight)
first. The preflight now always renders. Memory's Ingress no longer defaults
`nginx.ingress.kubernetes.io/rewrite-target: /`.

### Upgrading from 0.4.0

0.5.0 adds Lens, Context Gateway, and Intent Router, all on by default. With the 0.4.0 values alone
the render fails and names the first missing input; either add their values files or switch them off:

```bash
helm upgrade iris redis-ai/redis-iris -n redis-ai --version 0.5.0 \
  -f examples/memory-only.yaml -f examples/playbook.yaml \
  -f examples/lens.yaml -f examples/context-gateway.yaml -f examples/intent.yaml
```

With the new products switched off only the UI rolls (its routes are now in suite order). Turning
them on creates their Deployments and their generated Secrets (`iris-<product>-dataplane-credential`,
`-internal-token`, `-admin-token`, kept on rollback like the others), and rolls the Identity Service
(their credentials and validators) and the UI (their routes). Memory's and Playbook's Secrets keep
their values.

### Upgrading from 0.3.0

0.4.0 adds `global.iris.extraction.enabled` (default `false`) and the workload identity preflight
(Secret `iris-preflight`). With the 0.3.0 values unchanged no Deployment rolls. Run the preflight
(see [Install-time checks](#workload-identity-preflight)), then turn extraction on with its inputs:

```bash
helm upgrade iris redis-ai/redis-iris -n redis-ai --version 0.4.0 \
  -f examples/memory-only.yaml -f examples/playbook.yaml \
  --set global.iris.extraction.enabled=true \
  --set playbook.worker.existingSecret=<worker Secret> --set playbook.worker.region=<region>
```

The Playbook worker is created, and the Memory data plane, control plane, and worker and the
Playbook control plane and data plane roll once; the Identity Service and the UI do not. Remove any
extraction values a 0.3.0 install set by hand under `playbook.extraction`, `playbook.worker.enabled`,
`playbook.worker.sourceURL`, `memory.memory.auth.jwt_subjects`, or
`memory.controlplane.configData.auth.workload_identity`: a differing value fails the render and
names it.

### Upgrading from 0.2.0

In 0.3.0 `global.iris` is the only input for what the products share, and the
UI signs operators in through the IdP by default. With the 0.2.0 values
unchanged the render fails, names the first missing IdP input
(`global.iris.auth.oidc.issuer`), and nothing is applied. Before upgrading:

- Choose the UI mode: supply the IdP inputs (see
  [`single-product.yaml`](examples/single-product.yaml)), or keep Admin Token
  mode with `ui.sso.enabled: false` and `ui.ingress.enabled: false`, as
  [`memory-only.yaml`](examples/memory-only.yaml) does.
- Move the license to `global.iris.license` (one Secret for every product) and
  remove `memory.license` and `playbook.license`.
- Preserve the installed tenant when choosing `global.iris.tenantId`. Inspect
  `helm get values iris -n redis-ai --all`, including `memory.tenantId`,
  `playbook.tenantId`, and `identityService.runtime.apiKeyTenant.singleTenantID`.
  Check the effective Memory `auth.admin_tenant_id` too, especially if a
  custom configuration Secret or overlay supplies it.
  The documented 0.2.0 install with `examples/memory-only.yaml` sets Memory
  and Identity Service to `default`, and the umbrella sets Playbook to
  `default`. Those installations keep the same tenant with the new
  `global.iris.tenantId` default; do not switch them to `"1"`.
  For an explicitly configured custom tenant, carry that same value into
  `global.iris.tenantId`. Identity Service's `singleTenantID` and both
  products' tenant settings are now derived from that one suite value.
- The legacy Memory fallback `"1"` applies only when its effective
  `auth.admin_tenant_id` was unset or empty. Only those installations would
  move from `"1"` to `default` if the new suite default were accepted.
  Existing stores stay in `"1"`; the upgrade does not migrate them.
  Before selecting `global.iris.tenantId: "1"`, check the Identity Service
  and Playbook tenants and data: Playbook defaults to `default`, so such an
  installation can already have data in two tenants. Reconcile that data
  before selecting one suite tenant. A configuration change does not merge
  tenants or make their existing data accessible from another tenant.
- Remove the values the suite now derives: `memory.tenantId`, `playbook.tenantId`,
  `identityService.runtime.apiKeyTenant.singleTenantID`, the Identity Service
  service credentials and validators, the Memory worker
  identity, `dataplane.identityServiceBaseURL`, and `ui.products`. A differing
  value fails the render and names it.

Record the verified tenant in `tenant-upgrade.yaml` (shown for the documented
0.2.0 installation; use your existing tenant if different):

```yaml
global:
  iris:
    tenantId: default
```

```bash
helm upgrade iris redis-ai/redis-iris -n redis-ai --version 0.3.0 \
  -f examples/memory-only.yaml -f examples/playbook.yaml -f tenant-upgrade.yaml
```

The Identity Service, Memory, and Playbook roll once: their in-cluster URLs are
now fully qualified with `global.iris.clusterDomain`, and the Memory worker's
issuer keys come from `<issuer>/openid/v1/jwks`. Credentials, Secrets, and data
are kept, but data stays under its original tenant; preservation does not
make it accessible from a different suite tenant.

### Upgrading from 0.1.0

Playbook is on by default in 0.2.0, so an upgrade needs its values next to the
0.1.0 ones; without them the render fails, names
`playbook.storage.existingSecret`, and nothing is applied:

```bash
helm upgrade iris redis-ai/redis-iris -n redis-ai --version 0.2.0 \
  -f examples/memory-only.yaml -f examples/playbook.yaml
```

The upgrade creates Playbook's own Secrets and leaves Memory's, rotated or not,
as they are. To stay on Memory alone, set
`global.iris.products.playbook.enabled=false` instead of passing
`playbook.yaml` (see [Product selection](#product-selection)).

### Rotating a credential

Change the Secret in place (see [Credentials](#credentials)). Memory, Playbook,
and the Identity Service re-read the mounted file on each request, so the old
value stops working once the kubelet syncs the volume (about a minute), with no
restart. An upgrade or a rollback keeps the rotated value.

### Rolling back

`helm rollback iris <revision>` restores the workloads and values of that
revision, never a credential: the hook Secrets are not in the release manifest.
Rolling back to 0.1.0 removes Playbook's workloads and keeps its Secrets, so a
later upgrade reuses them. Keep the chart of each installed version for a
rollback without the repository (`helm pull redis-ai/redis-iris --version <v>`,
which `NOTES.txt` prints).

### A failed or interrupted upgrade

- `helm upgrade --atomic` returns to the previous revision by itself when the
  upgrade does not become ready.
- An upgrade whose client was interrupted leaves the release in
  `pending-upgrade`, and every later upgrade is refused. Find the last
  `deployed` revision with `helm history iris -n redis-ai`, then
  `helm rollback iris <that revision> -n redis-ai --wait`.

### Tested baselines

After the KinD run passes, the nightly `iris-onprem-helm-test.yml` uploads the
release it tested (kept 90 days) as `redis-iris-baseline-<chart version>`, so
the next release upgrades from exactly that runtime: `redis-iris-baseline`
from M1 (0.1.0), `redis-iris-baseline-0.2.0` from M2, `redis-iris-baseline-0.3.0`
from M3, `redis-iris-baseline-0.4.0` from M4, `redis-iris-baseline-0.5.0` from M5, and
`redis-iris-baseline-0.6.0` from this chart.

| File | Contents |
| --- | --- |
| `redis-iris-<version>.tgz` | The chart, packaged with the product charts from that commit |
| `oci-*.tar.gz` | The tested images (`docker load`, then `kind load docker-image`): four in 0.1.0, six from 0.2.0, twelve from 0.5.0 |
| `memory-only.yaml`, `playbook.yaml` (from 0.2.0), `lens.yaml`, `context-gateway.yaml`, `kind-context-gateway.yaml`, `intent.yaml` (from 0.5.0), `kind-values.yaml`, `images.yaml` | The values the install used; `images.yaml` holds the image overrides |
| `baseline.json` | The source commit, the run, and each image ID |

The `upgrade-e2e` job installs the `UPGRADE_FROM_VERSION` (0.6.0) baseline from
one pinned run, never the latest: its run ID is in
[`tests/kind/baseline-run`](tests/kind/baseline-run). The job fails when the
file is empty (MOD-20811); keep it on a run that uploaded `redis-iris-baseline-0.6.0`
(the artifact expires after 90 days). The populated upgrade it runs is described
in `tests/kind.sh` (`UPGRADE_FROM`). Locally:

```bash
gh run download <run-id> --name redis-iris-baseline-0.6.0 --dir /tmp/baseline
UPGRADE_FROM=/tmp/baseline BASELINE_RUN=<run-id> EXTRACTION=1 task iris:test:kind
```

The release train runs the same suite (`workflow_call`) on the packaged chart it
publishes and the published release images, without building anything:

```bash
CHART=/tmp/redis-iris-1.0.0-rc.1.tgz IMAGES=published LICENSE_PRIVATE_KEY="$(cat signing.pem)" task iris:test:kind
```

## Limitations

- FIPS is not supported yet; see [Not yet supported](#not-yet-supported).
- The Identity Service, Memory, Playbook, and Context Gateway pins (0.10.2) are not the product
  charts the umbrella needs (the published Context Gateway and Identity Service charts lack the
  suite values, the Lens and Context Gateway wiring, and the rollout strategy and PodDisruptionBudget
  inputs); they move once those are published (M7). Lens
  and Intent Router are not published at all, so they are local sources (`file://`). Until then
  install from local sources (`task iris:dev:on`).
- There is no support bundle, air-gapped image list, or release inventory yet (M7, M8); when they
  land they include both Intent Router images.
