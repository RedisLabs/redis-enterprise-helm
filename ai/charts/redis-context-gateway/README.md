# Install Context Gateway with external Identity Service

Use the [release and operations runbook](https://github.com/redislabsdev/iris/blob/main/docs/runbooks/context-gateway-onprem-release.md)
to publish a release, install a pinned public chart, and verify upgrade, rollback,
and uninstall. Release automation does not establish that a version is already
public or that an upgrade pair is compatible; verify the selected versions first.

This chart installs one tenant's control plane and data plane. It does not
install Identity Service, Redis, Vault, CSI drivers, or secret-provider resources.
The intended GA deployment uses a global Helm release for one tenant, with one
Identity Service deployment and one deployment of each enabled product. The
global chart supplies the same tenant ID to the product charts. A second tenant
uses a separate global release. The component installation steps below describe
the configuration contract and support local validation.

Use separately managed metadata Redis, credential Redis, and customer databases.
Use a separate Redis ACL user for credentials. Redis endpoint aliases do not prove
database separation; check the actual Redis deployment.

## Prepare files and install the package

1. Configure the external Identity Service release for product
   `context-gateway`, following the
   [Identity Service product contract](#configure-the-identity-service-release)
   below. In that chart's values:
   - `runtime.serviceCredentials[]` holds the data plane's runtime credential
     with `allowedOperations: [api-key-introspect]` and
     `allowedProducts: [context-gateway]`, from the same Secret as
     `dataplane.runtimeToken`.
   - `productValidation.products.context-gateway.baseURL` reaches the
     control-plane Service. With release name `gateway`, that URL is
     `http://gateway-redis-context-gateway-controlplane:9100` in the same
     namespace. Its `credential` uses the same Secret as
     `controlplane.internalToken`.
   - `runtime.apiKeyTenant.singleTenantID` equals this chart's `tenantId`.
     The control plane refuses grant callbacks that name another tenant.

   Identity Service already knows resource type `gateway` with actions `use`
   and `full`; agent keys carry those grants and need no extra setting.
   Keep the Identity Service Control API credential separate from all three
   Gateway credentials.
2. Prepare two protected YAML files for the default Redis credential backend.
   `metadata.yaml` contains the metadata Redis connection:

   ```yaml
   metadata_db:
     urls: ["rediss://metadata-user:REPLACE@metadata.example.com:6379"]
   ```

   `credential-redis.yaml` contains the separate credential Redis connection:

   ```yaml
   credential_storage:
     redis:
       urls: ["rediss://credential-user:REPLACE@credentials.example.com:6379"]
   ```

   Keep real URLs and passwords only in these protected files. The operator
   provisions the Redis databases and their ACL users. These connections have
   different purposes; a Kubernetes Secret's name does not create either database.
   Also provision at least one customer database and follow the
   [database connection example](#tune-application-defaults-and-kubernetes-workloads)
   below to create its Secret and configure its registry entry before installing.
3. Generate a base64-encoded 32-byte encryption key and create external Secrets.
   Supply a valid Context Gateway license and three distinct credential files.

   ```bash
   umask 077
   openssl rand -base64 32 > k1
   kubectl create secret generic gateway-metadata --from-file=config.yaml=metadata.yaml
   kubectl create secret generic gateway-credential-redis --from-file=config.yaml=credential-redis.yaml
   kubectl create secret generic gateway-keyring --from-file=k1
   kubectl create secret generic gateway-license --from-file=license=/secure/gateway-license
   kubectl create secret generic gateway-admin --from-file=token=/secure/admin-token
   kubectl create secret generic gateway-grant-validation --from-file=token=/secure/grant-token
   kubectl create secret generic gateway-runtime --from-file=token=/secure/runtime-token
   ```

   These commands assume the current Kubernetes namespace is the installation
   namespace. The license must cover this product and deployment. No secret
   content belongs in a Helm `--set` argument.
4. Copy `examples/kubernetes-secret.yaml` and set the tenant, public data-plane
   URL, and external Identity Service URL. The public URL must be reachable by
   MCP clients. The chart exposes ClusterIP Services; configure your own ingress
   or gateway. Preserve both the MCP request and response headers.
5. Install the selected public release after verifying publication through the
   runbook. Set `GATEWAY_VERSION` to that version. The package includes its pinned
   published library and needs no checkout or local image build:

   ```bash
   helm repo add redis-ai https://helm.redis.io/ai --force-update
   helm repo update redis-ai
   helm upgrade --install gateway redis-ai/redis-context-gateway --version "$GATEWAY_VERSION" \
     -f /secure/gateway-values.yaml --wait --timeout 5m
   kubectl rollout status deployment/gateway-redis-context-gateway-controlplane
   kubectl rollout status deployment/gateway-redis-context-gateway-dataplane
   ```

   Public releases use the chart's default image repositories and tags. For local
   development, package `context-gateway/helm` with `helm dependency build` and
   `helm package`, then supply both component images. Development-image checks
   do not establish production license enforcement or public artifact availability.

## Configure the Identity Service release

These are the values to set on the separately installed Identity Service chart
(`identity-service/helm`). The addresses assume both releases share one
namespace, this chart is installed as release `gateway`, and Identity Service is
installed as release `ids`. After changing a release name or Service port,
restate them here.

| Set on the Identity Service release | Value | Matching Context Gateway value |
|---|---|---|
| `runtime.serviceCredentials[]` | `name: context-gateway-dp`, `subject: context-gateway-dataplane`, `allowedOperations: [api-key-introspect]`, `allowedProducts: [context-gateway]`, `existingSecret` + `secretKey` | `dataplane.runtimeToken.existingSecret` + `secretKey`: the same Secret, mounted by the data plane |
| `productValidation.products.context-gateway.baseURL` | `http://gateway-redis-context-gateway-controlplane:9100` | The control-plane Service `<release>-redis-context-gateway-controlplane` on `controlplane.service.port` (default `9100`) |
| `productValidation.products.context-gateway.credential` | The control plane's grant-validation Secret and key | `controlplane.internalToken.existingSecret` + `secretKey` |
| `runtime.apiKeyTenant.singleTenantID` | The Gateway tenant, for example `default` | `tenantId`; they must be equal, or the control plane refuses every grant callback for another tenant |

The Gateway data plane reaches Identity Service through `identityService.baseURL`,
for example `http://ids-iris-identity-service:9200` (set
`identityService.allowInsecureTransport: true` for an in-cluster `http://` URL).

Identity Service configures one grant-validation endpoint per product. The global
release points it at its own Gateway control plane; routing one Identity Service
to independent Gateway deployments is outside this deployment model.

The callback carries a grant-validation credential. Kubernetes operators own
transport protection through the global deployment's service mesh or TLS proxy.
The HTTP examples describe application endpoints; this chart does not configure
transport encryption, and `security.profile: fips` does not encrypt this link.

Gateway agent-key grants need no extra Identity Service setting: it already
knows product `context-gateway`, resource type `gateway` and its actions `use`
(every MCP request on the Gateway) and `full` (implies `use`). Create agent
keys through the Identity Service Control API with a grant such as
`{product: context-gateway, resourceType: gateway, resourceId: <gateway-id>, actions: [use]}`;
grant validation calls the Gateway control plane to check that the Gateway
exists. Gateway service subjects hold no grants, so `subjectGrants.allowed`
needs no Gateway entry.

```yaml
# Identity Service chart values
runtime:
  apiKeyTenant:
    singleTenantID: default
  serviceCredentials:
    - name: context-gateway-dp
      subject: context-gateway-dataplane
      allowedOperations: [api-key-introspect]
      allowedProducts: [context-gateway]
      existingSecret: gateway-runtime
      secretKey: token
productValidation:
  products:
    context-gateway:
      baseURL: http://gateway-redis-context-gateway-controlplane:9100
      credential:
        existingSecret: gateway-grant-validation
        secretKey: token
```

When the Identity Service release also serves Memory or Playbook, add these
entries to its existing `serviceCredentials` list and `productValidation.products`
map; every product uses the one `singleTenantID`.

## Choose the credential backend and file-delivery method

| Choice | Configuration and access |
| --- | --- |
| Encrypted Redis, default | `credentialStorage.provider: redis`; URLs through `credentialStorage.redis.connection`; `credentialStorage.redis.keyring` shared by both planes. CP needs `GET`, `SET`, `DEL`; DP needs `GET`. Both need connection/probe commands allowed by the Redis deployment. Scope ACL key patterns to `context-gateway/*` when using the default base path. |
| Vault KV v2 | Layer `examples/vault.yaml` over the Secret example. Create `gateway-vault-writer` and `gateway-vault-reader` Secrets, each with `config.yaml` containing `credential_storage.vault.token`. CP needs create/read/update/patch on `secret/data/context-gateway/*` and delete on `secret/metadata/context-gateway/*`; DP needs read on the data path. A token-only file is not a YAML overlay. |
| AWS Secrets Manager | Layer `examples/aws.yaml` and replace the IAM role ARNs. CP needs GetSecretValue, CreateSecret, PutSecretValue, and DeleteSecret under the shared namespace; DP needs GetSecretValue. With a customer KMS key, grant the required decrypt/encrypt/data-key permissions. The AWS SDK uses its default credential chain. |
| Kubernetes Secret files | Set each purpose-specific reference's `existingSecret` and `secretKey`. Only the selected key is projected for single-file references; the keyring projects only the `keyFiles` entries into its directory. Mounts are read-only without `subPath`. |
| CSI files | Set `secretProviderClass` and `fileName` instead of `existingSecret`; `examples/csi.yaml` shows each purpose-specific reference. Install the Secrets Store CSI driver, the provider, its CRDs, and provider authentication first. Create each SecretProviderClass in the release namespace. No Kubernetes Secret synchronization is required. |

For CSI, `examples/secret-provider-class.yaml` is a Vault provider example for
`gateway-metadata`. Store the metadata YAML above as field `config` at the stated
KV path. Create a `gateway-credential-redis` class whose `config.yaml` contains
the credential Redis fragment above. Create analogous classes for `license` (file `license`), `keyring`
(file `k1`), `admin`, `internal`, and `runtime` (file `token`). Bind the Vault
role to both generated component ServiceAccounts and the installation namespace.
File permissions must allow UID/GID 65532 to read the files. The Vault example
uses numeric mode `0444` because CSI files can remain owned by root even when
the pod sets a filesystem group. The files are mounted read-only in each pod.
Kubernetes Secret volumes use mode `0440` with filesystem group 65532.
Keep the admin-token, grant-validation-token, and Vault writer CSI classes
separate from every class mounted by the data plane. CSI mounts the whole
provider directory, even when the application reads only one named file.

Follow the [driver installation guide](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation)
and [Vault provider configuration](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi/configurations).
Enable provider rotation if projected files must update without recreating pods.
That updates files; it does not reload application clients initialized at startup.

## Configure file references by purpose

The operator creates the external Secrets or CSI provider objects before
installation. Names such as `gateway-metadata` are examples chosen by the
operator, not special Gateway objects. References may use separate Secrets or
separate keys of one Secret; the chart does not require a Secret per purpose.
Each Kubernetes Secret reference projects only its selected keys. The keyring
mount includes only `credentialStorage.redis.keyFiles`; operators are responsible
for the contents of those files. Rendering fails if both Vault credentials select
the same file.

| Helm reference | File contents | Consuming plane |
| --- | --- | --- |
| `metadataDB` | YAML containing `metadata_db.urls` | Both |
| `credentialStorage.redis.connection` | YAML containing `credential_storage.redis.urls`, when using Redis | Both |
| `credentialStorage.redis.keyring` | Directory of base64-encoded 32-byte AES keys; names match `keyFiles` | Both |
| `credentialStorage.vault.credentials.controlplane` | YAML containing `credential_storage.vault.token`, with write/delete access | Control plane |
| `credentialStorage.vault.credentials.dataplane` | YAML containing `credential_storage.vault.token`, with read access | Data plane |
| `databaseConnections[]` | YAML containing `databases.<id>.urls` for one or more registered databases | Both |
| `controlplane.adminToken` | Raw token sent by operators to the Gateway administration API | Control plane |
| `controlplane.internalToken` | Raw token Identity Service sends to the grant-validation callback | Control plane |
| `dataplane.runtimeToken` | Raw token Gateway sends to Identity Service for agent-key introspection | Data plane |
| `license` | License file as issued | Both |
| `tls.caBundle` | PEM CA bundle | Both |

The admin token is checked directly by Gateway. The internal token must match
the Identity Service chart's `productValidation.products.context-gateway.credential`.
Register the runtime token under the Identity Service chart's
`runtime.serviceCredentials` with `allowedOperations: [api-key-introspect]` and
`allowedProducts: [context-gateway]`. These three values must be distinct.
The two Identity Service HTTP paths currently authenticate shared credentials;
Kubernetes ServiceAccounts do not replace these credentials automatically. MCP
clients use their own agent keys, not any of these service tokens.

Redis URLs and Vault tokens need YAML wrappers because the application loads
configuration files. A raw URL or raw Vault token is not a valid replacement.
License, admin, internal, and runtime files do not use YAML wrappers.

Advanced `shared.overlays` and component `overlays` remain available for
configuration that does not use these references, or for deliberate overrides.

For a Kubernetes Secret:

```yaml
license:
  existingSecret: gateway-license
  secretKey: license
```

For CSI:

```yaml
license:
  secretProviderClass: gateway-license
  fileName: license
```

The default values show Kubernetes Secret fields as active settings and CSI as a
commented alternative. `checksum` is optional for either method. For single-file
CSI references, supply both the provider class and the emitted filename; the
keyring references the provider directory and has no filename selector.

Choose exactly one delivery method per reference. `secretKey` selects a Kubernetes
Secret key; `fileName` selects a file emitted by the CSI provider. When switching
methods in layered values, clear the old selector explicitly. Both delivery
methods accept `checksum` to trigger a rollout after external file changes.
The keyring reference selects a directory; `credentialStorage.redis.keyFiles`
maps key IDs to Secret keys or CSI filenames within it. A Kubernetes Secret
keyring projects only the listed keys, so every key file must exist in the
Secret before its `keyFiles` entry is added; otherwise the pod cannot start.

Kubernetes Secret file references project only the selected key. CSI mounts the
provider class's directory, so scope each class to the files its consuming plane
may read. Runtime credentials must use a different CSI class from control-plane
credentials. The chart does not create SecretProviderClasses or authentication
resources for them.

Use AWS workload identity for Secrets Manager access. `examples/aws.yaml` shows
IRSA with separate IAM roles for the control plane and data plane. Configure the
cluster's identity provider and IAM trust policies before installation. For EKS
Pod Identity, configure the agent and associate each plane's ServiceAccount with
its IAM role outside Helm; role annotations are not required for that method.
The AWS SDK obtains temporary credentials through its default credential chain.
ServiceAccounts accept annotations and an explicit name; automatic API-token
mounting defaults to false. Projected workload-identity tokens are separate from
the agent keys that authenticate MCP callers.

`tls.caBundle` sets `SSL_CERT_FILE` to a mounted PEM bundle for both planes.
It uses the same Secret/CSI fields; leave both selectors empty to disable it.

## Mount additional volumes and private CA certificates

Top-level `volumes` and `volumeMounts` apply to both planes. Each component's
`volumes` and `volumeMounts` are appended to those lists. Entries use Kubernetes
Volume and VolumeMount fields directly, as in the Memory chart. Additional
volume names must be unique within each plane, including managed volume names
and the reserved `config` volume. Mount references must resolve in that plane;
mount paths must be unique and cannot cover `/etc/context-gateway/config` or
`/etc/context-gateway/files` and their descendants.

For a private Redis CA, create `gateway-redis-ca` with a PEM certificate under
key `ca.crt`, then layer `examples/certificates.yaml` over the installation values.
It mounts one read-only certificate file under `/etc/ssl/certs` in both planes,
following Context Retriever's system-trust pattern. Use `rediss://` connection
URLs; the Redis client loads the system certificate pool, including this file.
Mount individual files rather than replacing the whole system certificate
directory, so public CA certificates remain available.

The example uses `subPath` to select the Secret key. Kubernetes does not refresh
these mounts when the Secret changes; restart both planes after certificate
rotation. Changing additional volume or mount definitions changes the pod
template and triggers a rollout. The chart's managed references continue to mount
whole read-only directories without `subPath`.

## Override non-secret configuration

`shared.config` supplies common settings, such as `metadata_db.client`,
`databases` display information, and `opentelemetry`. Component `config`
supplies service-specific settings and overrides shared telemetry. The chart
owns tenant, profile selection, authentication, license paths, backend namespace,
and service ports. Conflicting values fail rendering. Mounted overlays are trusted
operator configuration and can override these settings; keep the two planes'
tenant, registry, keyring, and backend namespace consistent.

Each process receives files in this order:

1. Chart-rendered shared configuration.
2. Chart-rendered component configuration.
3. `metadataDB`, if configured.
4. The active credential backend's connection or per-plane Vault credential file.
5. `databaseConnections`, in list order.
6. Advanced `shared.overlays`, in list order.
7. Advanced component `overlays`, in list order.

Later maps merge and later lists replace earlier lists. Advanced overlays can
replace application values supplied through a purpose-specific reference,
including connection URLs and token-file paths. They do not change the chart's
Kubernetes Secret references or volume mounts. Named connection references are
optional only when `shared.overlays` or the component's `overlays` is set; without
an overlay, rendering fails when one is missing. The real application still
validates those settings at startup.

The application applies environment overrides last. The chart assigns paths
under `/etc/context-gateway/files` to each purpose and ordered overlay.
Inline tokens, passwords, Redis URLs, and removed configuration keys are rejected.
Keep all credential-bearing settings in mounted files; the connection references above are the normal installation interface.

Both planes emit production JSON logs to standard error by default. Set
`profile: dev` for the application's development logging profile. Both profiles
keep agent-key authentication; release images enforce licenses in both profiles.
Prometheus metrics are
available at `/metrics` on each HTTP Service. Set
`shared.config.opentelemetry.enable_tracing: true` and
`otlp_grpc_endpoint: collector.example.com:4317` for OTLP traces. Iris assigns
`service.namespace: context-gateway` and `service.name: controlplane` or
`dataplane` from runtime identity, as Memory and Playbook do. Kubernetes labels
do not supply these values. A conflicting `opentelemetry.service_name` is ignored
with a warning; leave it unset. Pod annotations can configure your metrics scraper. Probes use unauthenticated
operational endpoints; release-build readiness includes license validity.

## Tune application defaults and Kubernetes workloads

`values.yaml` groups each component's settings in operator order: Kubernetes
deployment, application configuration, then configuration files and credentials.
The three application `config` blocks default to `{}`. Commented examples show
current application defaults and optional settings; uncomment only the overrides
you need. Leaving a setting out lets the image's defaults apply after upgrades.
Chart-owned deployment settings, including replicas and probes, remain active. The JSON schema rejects unknown keys in all three `config`
blocks. Durations use Go units such as `100ms`, `2s`, and `15m`; size limits are
integer bytes. Shared configuration supplies metadata Redis client tuning, the
database registry, and telemetry. Component configuration supplies HTTP deadlines,
control-plane discovery, authentication, and data-plane result limits.

A registry entry's map key is its database ID. Put its display `name` and optional
`account_id` and `subscription_id` in `shared.config.databases`. Supply authenticated
URLs through `databaseConnections` with the same IDs. For example, create a
protected `databases.yaml` file:

```yaml
databases:
  customer:
    urls: ["rediss://customer-user:REPLACE@customer.example.com:6379"]
  analytics:
    urls: ["rediss://analytics-user:REPLACE@analytics.example.com:6379"]
```

Create its external Secret:

```bash
kubectl create secret generic gateway-database-connections --from-file=config.yaml=databases.yaml
```

Then configure the registry and file reference:

```yaml
shared:
  config:
    databases:
      customer: {name: Customer database}
      analytics: {name: Analytics database}
databaseConnections:
  - existingSecret: gateway-database-connections
    secretKey: config.yaml
```

One file can hold all connection URLs, or use multiple references for different
ownership and rotation schedules. Do not put the same ID in multiple files unless
you intend the later file to override it. The Gateway operator selects `databaseId`
through the administration API; registration alone does not select it for every
Gateway. These databases store result state, not metadata or Upstream credentials.
Do not use removed `results_db` or `result_policies` settings.

Result caching and result handles each turn on at two levels. The
deployment switch in `dataplane.config` (`result_cache.enabled` and
`result_handles.enabled`, both `false` by default) is the operator's global
flag for every Gateway. Each Gateway then has its own `resultCache` and
`resultHandles` toggle, set through the administration API. A Gateway serves a
feature only when both are on. Configure either capability through
`dataplane.config`, and no overlay is needed. For example, enable both for this
deployment:

```yaml
dataplane:
  config:
    result_cache:
      enabled: true
    result_handles:
      enabled: true
```

Caching still requires a per-tool result-cache policy. Result handles apply to
eligible results above the configured size threshold unless a tool policy
excludes them. Enabling these capabilities alone does not select a database.

Both features store state in the Gateway database, so register that database in
`shared.config.databases` and `databaseConnections` as above, then select it as
the Gateway's `databaseId` through the administration API. A Gateway created
with a `databaseId` has both toggles `enabled` unless the request sets them,
and one created without a database has both `disabled`. The API refuses to
enable a toggle on a Gateway without a `databaseId`. Handles need that
database to run with `maxmemory-policy noeviction` and JSON support. A Gateway
without a database, or with a toggle `disabled`, is served uncached, returns
results whole, and lists no result handle tools. Turning a toggle off deletes
nothing: stored entries expire on their TTL. The `result_cache` and
`result_handles` blocks in `dataplane.config` tune limits and timeouts once the
features are enabled.

`metadata_db.client.client_name` optionally names Redis connections for diagnosis
through `CLIENT LIST`. It does not select a database or change authentication.
It is separate from the application's internal Redis instrumentation name.
Leave it omitted unless operators need a connection label.

`controlplane.config.auth.oidc` enables IdP authentication for administration;
`controlplane.adminToken` remains available, including during an IdP outage.
Follow the [paired control-plane and UI example](#enable-idp-administration-and-shared-ui-sessions) below.
`dataplane.config.auth.oidc` enables MCP caller sign-in alongside agent keys. Supply
the issuer, the API's audience, and JWKS URI. The chart uses `tenantId` as the static
tenant for MCP caller sign-in; Identity Service grants authorize Gateway access.
The data plane's OAuth public URL defaults to `publicBaseURL`.

Each component exposes `startupProbe`, `livenessProbe`, and `readinessProbe` using
native Kubernetes probe fields. Set a probe to `null` to disable it; `{}` merges
with defaults. To replace HTTP with another probe action, set `httpGet: null`.
Startup probes allow 150 seconds by default before liveness checks begin.

Each component's `autoscaling` can create an HPA with CPU and/or memory targets
and native `behavior` policies. It is off by default. Enable Metrics Server and
set `resources.requests.cpu` or `resources.requests.memory` for every selected
target. With autoscaling on, the Deployment omits `replicas`; otherwise
`replicaCount` applies. Set min/max replicas and scaling behavior for the
installation's capacity requirements. The chart does not change the shared
published Helm library.

## Enable IdP administration and shared UI sessions

Apply these auth overlays to an existing, complete installation. Keep
`/secure/gateway-values.yaml`, including its `tenantId`, `publicBaseURL`, images,
license, Identity Service connection and runtime token, metadata Redis, credential
backend and keyring, database registry and connection files, admin token and
internal token. Operator authentication does not call Identity Service; the data
plane still needs it. Enabling OIDC does not change resource ownership.

This example assumes the Gateway release is `gateway`, the UI release is `iris-ui`,
both use namespace `redis-ai`, and the cluster domain is `cluster.local`. Keep the
UI's complete `/secure/ui-values.yaml`, including `image.tag` and the ingress,
DNS and TLS configuration for `https://iris.example.com`. Adjust the upstream
hostname below if your release, namespace or cluster domain differs.

1. Register the confidential IdP client `iris-ui` with callback
   `https://iris.example.com/auth/callback`. Configure the IdP to issue RS256
   access tokens with audience `api://redis-iris`, a `groups` claim containing
   the mapped group names below, and a `tenant_id` claim equal to the existing
   Gateway `tenantId`. `audienceParameter: none` relies on the IdP's configured
   audience mapper. When using this repository's local test realm, also include
   `iris` in `sso.scopes` to request its audience and role claims.
2. Provision the UI Secrets in `redis-ai`. The client-secret file contains the
   IdP credential; the Redis file contains comma-separated session Redis URLs
   (use `rediss://` for TLS). Generate the session key once and retain it across
   upgrades:

   ```bash
   umask 077
   openssl rand -base64 32 > /secure/iris-ui-session-key
   kubectl -n redis-ai create secret generic iris-ui-idp-client \
     --from-file=client-secret=/secure/iris-ui-client-secret
   kubectl -n redis-ai create secret generic iris-ui-session-key \
     --from-file=key=/secure/iris-ui-session-key
   kubectl -n redis-ai create secret generic iris-ui-session-redis \
     --from-file=urls=/secure/iris-ui-session-redis-urls
   ```

3. Save `/secure/gateway-oidc.yaml`:

   ```yaml
   controlplane:
     config:
       auth:
         oidc:
           enabled: true
           issuer: https://idp.example.com/realms/iris
           jwks_uri: https://idp.example.com/realms/iris/protocol/openid-connect/certs
           audience: [api://redis-iris]
           user_id_claim: sub
           tenant_id_claim: tenant_id
           static_tenant_id: ""
           role_claims: [groups]
           allow_unmapped_roles: false
           required_algorithms: [RS256]
           role_mappings:
             iris-suite-admins: suite_admin
             gateway-admins: product_admin
             gateway-operators: operator
             gateway-viewers: viewer
   ```

   `static_tenant_id` takes precedence over `tenant_id_claim`, so clear it for
   this claim-based mode. A missing tenant claim is rejected with `401`; a
   different tenant is rejected with `403`, including for suite administrators.
   For a trusted single-tenant issuer without a tenant claim, instead set
   `static_tenant_id` to the unchanged deployment `tenantId` and clear
   `tenant_id_claim`. The chart injects `tenantId` only when both sources are
   empty. Neither mode changes the deployment tenant or existing resource owners.

4. Save `/secure/ui-gateway-oidc.yaml`. Keep all existing product routes in this
   file's `products` list: Helm replaces lists instead of appending to them.
   Preserve existing products' role mappings too. The example shows the Gateway
   entry to add to that complete list:

   ```yaml
   publicURL: https://iris.example.com
   sso:
     enabled: true
     issuer: https://idp.example.com/realms/iris
     clientId: iris-ui
     clientCredential:
       existingSecret: iris-ui-idp-client
       clientSecretKey: client-secret
     scopes: [openid, offline_access]
     audience: api://redis-iris
     audienceParameter: none
     roleClaims: [groups]
     session:
       existingSecret: iris-ui-session-key
       secretKey: key
     redis:
       existingSecret: iris-ui-session-redis
       urlsKey: urls
     roleMappings:
       context_gateway:
         iris-suite-admins: suite_admin
         gateway-admins: product_admin
         gateway-operators: operator
         gateway-viewers: viewer
   products:
     - key: context-gateway
       label: Context Gateway
       product: context_gateway
       authScheme: bearer
       showInNavigation: false
       healthPath: /health/readiness
       upstream:
         host: gateway-redis-context-gateway-controlplane.redis-ai.svc.cluster.local
         port: 9100
         basePath: ""
         scheme: http
   ```

   The route key `context-gateway` sends `/api/context-gateway/v1/...` to
   `/v1/...` on the control plane. The UI permission prefix is `context_gateway`;
   the backend product identity remains `context-gateway`. No Gateway management
   screen is registered. Keep the UI and control-plane group mappings identical.

5. Upgrade both releases from the repository root, using the Gateway package
   prepared in the installation steps above and the UI chart's pinned dependency:

   ```bash
   helm upgrade gateway /tmp/gateway-charts/redis-context-gateway-0.1.1.tgz -n redis-ai \
     -f /secure/gateway-values.yaml -f /secure/gateway-oidc.yaml --wait
   helm dependency build iris/ui/helm
   helm upgrade iris-ui iris/ui/helm -n redis-ai \
     -f /secure/ui-values.yaml -f /secure/ui-gateway-oidc.yaml --wait
   ```

Verify direct API access with an IdP access token issued for the same audience,
tenant and mapped groups. Forward the control-plane Service locally:

```bash
kubectl -n redis-ai port-forward service/gateway-redis-context-gateway-controlplane 19100:9100
```

In another terminal, supply the token through `GATEWAY_ACCESS_TOKEN` without
printing it, then run this Bash command. A viewer or higher role receives `200`:

```bash
curl --fail-with-body http://127.0.0.1:19100/v1/gateways \
  --header @<(printf 'Authorization: Bearer %s\n' "$GATEWAY_ACCESS_TOKEN")
```

For browser verification, open `https://iris.example.com/auth/login`, sign in,
then open `/auth/me` on the same origin. A mapped viewer has
`context_gateway_get` in `permissions`. Open
`https://iris.example.com/api/context-gateway/v1/gateways` in that browser: it
returns `200` without entering a token. UI Auth keeps access tokens in its
server-side session; nginx forwards the token to Gateway. Do not retrieve or
store access tokens in browser JavaScript. Browser writes retain the shared
same-origin and `X-CSRF-Token` requirements; obtain that CSRF token from `/auth/me`.

Viewers can read; operators can also create, update and refresh; `product_admin`
and `suite_admin` can also delete. Unmapped groups grant no access. These roles
authorize administration only; agent keys and MCP execution keep their existing
Identity Service grants. OIDC is disabled by default, and the static admin token
continues to work whether OIDC is enabled or disabled.

## Rotate credentials and encryption keys

| File or value | Reload behavior and required action |
| --- | --- |
| Admin or grant-validation token | The verifier rereads the file. Secret/CSI projection is eventual. Coordinate grant-token changes with external Identity Service; use a rollout for a predictable deployment boundary. |
| Identity Service runtime credential | Reread on introspection; cached agent-key results can delay its next use. Coordinate accepted credentials with Identity Service and its cache settings. |
| Metadata and credential Redis URLs, registered database URLs, Vault tokens | Restart the consuming planes after changing files. |
| Upstream credentials | Update through the administration API. The application writes the credential backend. Do not create an Upstream volume mount. |
| Encryption keyring | Loaded at startup. Restart both planes whenever files or active key change. Keep all old keys needed to read referenced credentials. |

For startup files, set the affected reference's `checksum` to an operator-computed
digest, then run `helm upgrade` with the complete values. Alternatively run
`kubectl rollout restart` for each consuming Deployment. A Secret name alone
does not detect content changes. Rendered configuration, file references,
overlay order, and explicit digests contribute to rollout annotations.

To rotate encryption keys:

1. Add `k2` to the external keyring and `credentialStorage.redis.keyFiles`. Keep `k1` active.
   Update `credentialStorage.redis.keyring.checksum` and upgrade both planes. Both can now read
   either key. Wait for both rollouts.
2. Set `credentialStorage.redis.activeKeyId: k2` and upgrade. New credential writes use `k2`;
   existing credentials still open with `k1`.
3. Rewrite remaining referenced credentials through the application API before
   considering removal of `k1`. There is no automatic re-encryption or retirement
   check. Keep `k1` if you cannot prove it is unused, including for rollback and
   retained backups.

Uninstall with `helm uninstall gateway`. The chart has no database, Secret,
SecretProviderClass, cleanup hook, or storage deletion resource. External data and
credentials survive. API deletion of a Gateway or Upstream has separate cleanup
behavior; uninstall does not call those APIs.

## Verify a change

- CI and the release workflow use `task context-gateway:test:onprem-e2e` with a
  prepared package, both candidate images, a license file, and a pinned published
  standalone Identity Service. This task runs only Redis credential storage with
  Kubernetes Secret delivery. CI uses development images; release validation uses
  production images and a signed temporary Gateway license. Both run the same
  administration, MCP, and authorization assertions. See the
  [runbook](https://github.com/redislabsdev/iris/blob/main/docs/runbooks/context-gateway-onprem-release.md) for release
  evidence and the separate manual public-install and version-transition checks.
- `task context-gateway:test:chart` checks packaging, rendered files, and startup.
- `task context-gateway:test:chart:e2e` builds development images, creates a
  disposable KinD cluster, installs CSI and its Vault provider, and exercises
  two scenarios: encrypted Redis with Kubernetes Secrets, and Vault credential
  storage with CSI files from the same Vault instance. CSI authenticates through
  Kubernetes; Gateway uses separate control-plane and data-plane Vault tokens
  delivered by CSI. Startup files and Upstream credentials use separate Vault
  paths and policies. It checks authenticated
  registration, discovery, invocation, admin-token and encryption-key rotation,
  and external-state retention after uninstall. It always deletes its cluster.
- `tests/kind-smoke.sh` owns cluster setup, Helm installation, file delivery,
  rotation rollouts, and cleanup. `tests/dependencies.yaml` defines the disposable
  Redis, Vault, Identity Service, and Upstream workloads. `tests/api_smoke.py`
  runs API assertions and reuses the development API smoke test. The harness
  requires Bash, Python 3, jq, OpenSSL, Docker, KinD, kubectl, and Helm.
- `tests/chart_test.go` packages and renders the chart without a cluster. It
  checks generated resources and rejected values; it does not install workloads.
- AWS Secrets Manager remains supported and covered by chart rendering tests,
  but is outside this live deployment suite. Redis with CSI and Vault with
  Kubernetes Secrets are also outside the selected live scenarios.
- Production AWS IAM, external provider availability, and signed release-license
  validation require the corresponding production environment and release build.

## Health probe migration

Chart `0.1.1` uses `/health/liveness` and `/health/readiness` for the
services changed in this chart. Deploy matching service images that expose these
routes; older images and newer chart probes must not be mixed. Update custom
monitoring URLs at the same time.
