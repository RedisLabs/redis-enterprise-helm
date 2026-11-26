# redis-lens

Helm chart for on-prem Redis Iris Lens. One release runs three workloads and
connects to a separately installed Identity Service release (see
[Connecting to the Identity Service](#connecting-to-the-identity-service)):

| Workload | Image | Port | Probes |
|---|---|---|---|
| Data plane, `--mode server`: OTLP ingest and the read API | `dataplane.image` | 9000 | `/health/liveness`, `/health/readiness` |
| Worker, `--mode worker`: turn assembly. Same image, no Service | `dataplane.image` | 9000 (probes only) | `/health/liveness`, `/health/readiness` |
| Control plane: the single instance record and grant validation | `controlplane.image` | 9300 | `/health/liveness`, `/health/readiness` |

Design: the On-Prem Edition section of `docs/tdd/MOD-17930-iris-lens.md`. Install, upgrade, and
runbook documentation is tracked in MOD-18980.

## Prerequisites

Install the Identity Service release first, and create the Secrets before
installing. `examples/basic/prerequisites.example.yaml` shows them.

**Storage** (`storage.existingSecret`). One key per process, each a config
overlay the chart mounts as a later `--config` file:

| Key | Process | Holds |
|---|---|---|
| `lens-dataplane-storage.yaml` | data plane and worker | `storage.streams`, `storage.content`, `storage.index`, `storage.metadata` URLs |
| `lens-controlplane-storage.yaml` | control plane | `storage.metadata` URLs, optional `dram.urls` |

The four data-plane roles map onto the customer databases like this:

- **Records** (`streams` and `index`) need a RAM database, not Flex.
  It must use `maxmemory-policy noeviction` or `volatile-lru`; any other policy
  can evict a whole stream. `index` needs RediSearch and RedisJSON. A Flex records database fails index creation with a clear error.
- **Content** (`content`) can be Flex, RAM, or the records database.
- **Metadata** is a separate small Redis for the instance record. Do not put it
  on a telemetry database. The Identity Service release keeps its own metadata.

The records database user needs these commands and keys from this version on.
A user created with `+@all`, as the
[Redis operations runbook](../../docs/runbooks/iris-onprem-redis-operations.md)
does, needs no change.

| Needed for | Commands | Keys |
|---|---|---|
| The open-trace index (required: without them no trace is stored or finalized) | `ZADD`, `ZREM`, `ZRANGEBYSCORE`, `ZCARD` | `lens:{<instance>}:assembler:open` |
| Size measurement (optional: without them assembly is slower) | `STRLEN`, `MEMORY USAGE` | `lens:{<instance>}:assembly:*`, `lens:{<instance>}:turn:*` |
| The deleted-instance check (required: the assembler writes that create a key read it; only Neptune's control plane sets it) | `EXISTS` | `lens:{<instance>}:deleted` |

Grant the required commands before upgrading; nothing checks them at startup.

Helm cannot see inside the Secret. A key that omits a role fails at startup
with the missing key named, for example
`create Lens streams Redis client from storage.streams.urls: redis url list is empty`.

**License** (`license.existingSecret`, key `license`). Release images refuse
to start without a valid Lens license, and readiness stays false while the
license is in its grace period.

**Identity Service credentials.** The data plane's runtime credential
(`identityService.credential.existingSecret`) and the control plane's internal
token (`controlplane.internalToken.existingSecret`) are shared with the
Identity Service release; see [Secret ownership](#secret-ownership).

The control-plane admin token is generated on first install and kept across
upgrades; set `controlplane.adminToken.existingSecret` to bring your own.

## Install

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm dependency build lens/helm
helm upgrade --install lens lens/helm \
  --set tenantId=default \
  --set storage.existingSecret=lens-storage \
  --set license.existingSecret=lens-license \
  --set dataplane.image.tag=<version> \
  --set controlplane.image.tag=<version> \
  --set dataplane.identityServiceBaseURL=http://iris-identity-service:9200 \
  --set identityService.allowInsecureTransport=true \
  --set identityService.credential.existingSecret=lens-dp-credential \
  --set controlplane.internalToken.existingSecret=lens-internal-token \
  --set ingest.enabled=true
```

The control plane creates the instance `instance.id` (default `default`) at
startup. There is no create call.

## Connecting to the Identity Service

The **Iris Identity Service (IdS)** mints Lens agent keys and answers the data
plane's key introspection calls. This chart deploys none: install the
[`iris-identity-service`](../../identity-service/helm/README.md) chart as its
own release first, then connect this release to it. The minimum Identity
Service chart is expected to be `0.10.0` or later. The KinD harness tests this
chart against the in-repo Identity Service chart. The release workflow tests the
packaged chart against published Identity Service `0.10.2`; see the
[release runbook](../../docs/runbooks/lens-onprem-release.md).

Only the data plane calls the Identity Service. The control plane never does:
the Identity Service calls it to validate a grant before it stores a key. The
worker has no Identity Service credential.

Neither chart reads the other's values or checks them against its own. Keeping
the two releases consistent is the deployment automation's job. The KinD
harness (`task lens:test:onprem-kind`) proves that a consistent pair works;
`helm test` does not.

### Connection values

| Key | Default | Purpose |
| --- | --- | --- |
| `dataplane.identityServiceBaseURL` | `""` | The Identity Service release's URL. The data plane introspects agent keys there. Required. Must be `https://` unless `identityService.allowInsecureTransport=true`. |
| `identityService.allowInsecureTransport` | `false` | Accept an `http://` Identity Service URL, for example the in-cluster Service. |
| `identityService.credential.existingSecret` | `""` | The data plane's runtime credential (`lens-dataplane`), mounted at `/etc/identity-service/runtime/lens-dataplane/token`. Required. |
| `identityService.credential.secretKey` | `token` | Key in that Secret. |
| `identityService.credential.existingSecretChecksum` | `""` | Set to roll the data plane when the Secret's content changes. |
| `controlplane.internalToken.existingSecret` | `""` | The control plane's internal token, which the Identity Service release presents to the grant validator. |
| `tls.caCertSecret` | `""` | A CA bundle every workload trusts; see [TLS trust](#tls-trust). |

`identityService.*` no longer holds Identity Service values: the schema rejects
any key other than `allowInsecureTransport` and `credential`, and rejects
`storage.identityServiceKey`.

### Secret ownership

A Secret that both releases mount is owned by deployment automation and reaches
each chart as `existingSecret` + `secretKey`.

| Secret | Who owns it | Lens value | Identity Service value |
| --- | --- | --- | --- |
| Data-plane runtime credential (`lens-dataplane`) | Deployment automation | `identityService.credential.existingSecret` | `runtime.serviceCredentials[].existingSecret` |
| Control-plane internal token | Deployment automation (this chart generates `<fullname>-controlplane-internal-token` in development only) | `controlplane.internalToken.existingSecret` | `productValidation.products.lens.credential.existingSecret` |
| Control-plane admin token | Deployment automation, or this chart | `controlplane.adminToken.existingSecret` | None |
| Identity Service metadata Redis config | You | None | `metadata.existingSecret` |
| Identity Service Control token | The Identity Service release, or you | None | `control.*` |

The chart refuses to mount one Secret key as two of its credentials. It cannot
compare values held in differently named Secrets.

### Product contracts

This mirrors "Product contracts" in the
[Identity Service chart README](../../identity-service/helm/README.md#product-contracts).
The addresses assume this chart installed as release `lens` (fullname
`lens-redis-lens`) and an Identity Service release named
`iris-identity-service`. After changing either, `fullnameOverride`, or a
Service port, restate them on both releases.

| Set on this release | Value | Matching Identity Service value |
| --- | --- | --- |
| `dataplane.identityServiceBaseURL` + `identityService.allowInsecureTransport=true` | `http://iris-identity-service:9200` (the release's Service on its `service.port`, default `9200`; it speaks plain http) | None |
| `identityService.credential.existingSecret` + `secretKey` | The data plane's runtime credential | `runtime.serviceCredentials[]` entry `name: lens-dataplane`, `subject: lens-dataplane`, `allowedOperations: [api-key-introspect]`, `allowedProducts: [lens]`, the same `existingSecret` + `secretKey` |
| `controlplane.internalToken.existingSecret` + `secretKey` | The control plane's internal token | `productValidation.products.lens.credential` |
| `controlplane.service.port` | `9300` | `productValidation.products.lens.baseURL`: `http://lens-redis-lens-controlplane:9300` |
| `tenantId` | `default` | `runtime.apiKeyTenant.singleTenantID` |

The introspection cache (`runtime.cache.*`, 180 s soft and 300 s hard by
default) is now set on the Identity Service release; the removed
`identityService.runtimeCache` had the same defaults.

The matching Identity Service values:

```yaml
runtime:
  apiKeyTenant:
    singleTenantID: default
  serviceCredentials:
    - name: lens-dataplane
      subject: lens-dataplane
      allowedOperations: [api-key-introspect]
      allowedProducts: [lens]
      existingSecret: lens-dp-credential
      secretKey: token
productValidation:
  products:
    lens:
      baseURL: http://lens-redis-lens-controlplane:9300
      credential:
        existingSecret: lens-internal-token
        secretKey: token
```

Lens needs no unscoped-grants product. It needs a `subjectGrants.allowed`
entry only for tenant IdP users. See "Tenant IdP users".

### Cross-namespace

The Identity Service release can run in another namespace. Then:

- point `dataplane.identityServiceBaseURL` at its fully qualified Service, for
  example `http://iris-identity-service.<identity-service-namespace>.svc:9200`;
- set its `productValidation.products.lens.baseURL` to
  `http://lens-redis-lens-controlplane.<namespace>.svc:9300`;
- provision both shared Secrets with the same values in both namespaces, since a
  Pod mounts Secrets only from its own namespace;
- allow the Identity Service pods to reach the control plane on port `9300`, and
  the data plane to reach the Identity Service (see
  [`networkpolicy.reference.yaml`](networkpolicy.reference.yaml)).

The KinD harness tests the same-namespace layout only.

### TLS trust

Neither chart terminates TLS; put a mesh, gateway or TLS-terminating proxy in
front of the Identity Service for an `https://` URL. When its certificate is
signed by a private CA, set `tls.caCertSecret` to a Secret holding the CA bundle.
Every workload mounts it at `/etc/ssl/custom` and `SSL_CERT_DIR` points there.
The workloads trust these CAs on top of the image's system CAs, for the
Identity Service and `rediss://` storage endpoints alike. Set
`tls.caCertSecretChecksum` to roll the workloads when the bundle changes. An
empty `tls.caCertSecret` falls back to `global.tls.caCertSecret`, so an umbrella
chart can set one CA bundle for Lens and the Identity Service release.

`security.profile` (`""` or `fips`) and `imagePullSecrets` likewise fall back to
`global.security.profile` and `global.imagePullSecrets` when empty.

### Redis client certificates

For a Redis Enterprise database that requires a client certificate (mutual TLS (Transport Layer
Security)), set `redisClientTLS.existingSecret` to a Secret with `tls.crt` and `tls.key`:

```yaml
redisClientTLS:
  existingSecret: lens-redis-client          # default for every rediss:// client
  extraCertificates:                         # optional per-connection certificates
    - name: store-1
      existingSecret: store-1-redis-client
```

The data plane, worker and control plane mount the Secrets read-only at `/etc/redis-client-tls` (without `subPath`), and the
chart sets `redis_client_tls` in the service config to `/etc/redis-client-tls/tls.crt` and
`/etc/redis-client-tls/tls.key`. An extra certificate is mounted at
`/etc/redis-client-tls/<name>/tls.crt` and `tls.key`; name those paths in the `tls:` block
(`cert_path`, `key_path`) of the connection it is for. 

For certificate-only login (a certificate-based database user), use a `rediss://` URL with no
username or password; with a password in the URL the client sends both. The server CA is still
trusted through the CA setting above. When the Secret is renewed, new connections use the new
certificate within about 30 seconds, without a restart. See the
[Redis client certificate runbook](../../docs/runbooks/iris-onprem-redis-mtls.md) for the Redis Enterprise setup, rotation and CA rotation.

### Running under redis-iris

When the chart runs as the `lens` dependency of the `redis-iris` umbrella
(`global.iris` is set), the umbrella sets `fullnameOverride: redis-lens` and
points `controlplane.adminToken` at `iris-lens-admin-token`. The suite-wide
settings come from `global.iris` (TDD MOD-19479, "Values precedence"):

| Value | Under redis-iris |
| --- | --- |
| `tenantId` | `global.iris.tenantId` (default `default`) |
| `license.existingSecret`, `license.secretKey` | `global.iris.license.*` (defaults `iris-license`, `license.key`) |
| `auth.oidc.audience` | `global.iris.auth.oidc.audience` (default `api://redis-iris`) |
| `dataplane.identityServiceBaseURL`, `identityService.allowInsecureTransport` | the suite's Identity Service, `http://iris-identity-service.<namespace>.svc.<clusterDomain>:9200` |
| `identityService.credential` | `global.iris.secrets.dataplaneServiceCredentials.existingSecret`, else generated `iris-lens-dataplane-credential`; key `lens-dp` |
| `controlplane.internalToken` | `global.iris.secrets.controlplaneInternalTokens.existingSecret`, else generated `iris-lens-internal-token`; key `lens`. The chart generates none |
| `dataplane.oidc`, `controlplane.oidc.enabled` | from `global.iris.auth.oidc` when an issuer is set and `global.iris.auth.roleBindings` map a group for `lens` (or suite-wide): the access-token issuer, JWKS, role claims, the mappings, and the tenant as static tenant |

Leave these unset: a value that differs fails the render and names the `lens.`
field. Each Deployment mounts only its own credential key, and the reads stay
read-only (ingest is agent-key only). `storage`, `instance`, `ingest` and the
image tags stay yours to set. Without `global.iris` nothing changes.

### Upgrading from `0.1.x`

`helm upgrade` from a `0.1.x` chart, which bundled the Identity Service, is
unsupported. The following manual migration is untested guidance:

1. Preserve the control plane's internal token. A chart-generated one lives in
   `<fullname>-controlplane-internal-token`, key `token`. The data plane's
   runtime credential becomes a new `lens-dataplane` Secret; you can reuse the
   value of the generated `<fullname>-identity-service-runtime-token`.
2. Hand both values to deployment automation, which creates the shared Secrets.
3. Install the Identity Service release with those Secrets registered as in
   [Product contracts](#product-contracts). Point `metadata.existingSecret` at
   the metadata Redis and key namespace the bundled service used (the old
   `storage.identityServiceKey` overlay) to keep existing agent keys; otherwise
   re-mint every key on the new release.
4. Uninstall the `0.1.x` release, delete the bundled Identity Service Secrets
   Helm keeps (`<fullname>-identity-service-*`), and install this chart with the
   connection values. Remove every old `identityService.*` key and
   `storage.identityServiceKey` from your values; the schema rejects them.
5. Keep the tenant your existing keys use: set `tenantId` and the Identity
   Service release's `runtime.apiKeyTenant.singleTenantID` to it.

## Ingest is off by default

With `ingest.enabled=false` the data plane answers `POST /iris/data/v1beta1/lens/v1/traces` with 503.
Nothing trims the span streams yet, and stream keys carry no TTL, so neither
`noeviction` nor `volatile-lru` removes them: enabled ingest grows the streams
without bound. Turn it on
deliberately and watch the streams database's memory.

## Keys

Mint keys on the Identity Service release with its control token. A key's
grant names `lens-instance:<instance.id>` and one or more of `ingest`, `read`,
and `full`. The control plane validates the grant before the key is stored.

```bash
CONTROL_TOKEN=$(kubectl get secret iris-identity-service-control-token \
  -o jsonpath='{.data.token}' | base64 -d)
curl -sS -X POST http://<identity-service>:9200/v1/api-keys \
  -H "Authorization: Bearer $CONTROL_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"agent-ingest","grants":[{"product":"lens","resourceType":"lens-instance","resourceId":"default","actions":["ingest"]}]}'
```

An agent sends OTLP/HTTP protobuf to `http://<dataplane>:9000/iris/data/v1beta1/lens/v1/traces`
(an OTLP exporter configured with a base endpoint takes
`http://<dataplane>:9000/iris/data/v1beta1/lens` and appends `/v1/traces` itself) with
the ingest key in `Authorization: Bearer` or `X-Api-Key`. Reads need a `read`
key. An ingest key gets 403 on the read API.

## Operator IdP tokens

The data plane can validate operator IdP access tokens locally, beside agent keys,
so operators signed in through the on-prem UI can read Lens sessions and traces.
Set `dataplane.oidc.enabled=true` with `issuer`, `jwksURI` and `roleMappings`
(IdP group to Iris role: `viewer`, `operator`, `product_admin`, `suite_admin`).
Unmapped values are never accepted, and an empty `roleMappings` is refused. The
resolved tenant must equal `tenantId`: set `dataplane.oidc.tenantIDClaim` to read
it from a claim, or leave it empty to treat every token as `tenantId`'s. Without
`tenantId`, see [Multi-tenant mode](#multi-tenant-mode).

An operator token is accepted on the read API only, and only with a read role
(`viewer` or above). It gets 403 on `POST /v1/traces`: ingest always needs an
agent key. Agent keys keep working unchanged.

The control plane validates operator tokens against the same settings. Set
`controlplane.oidc.enabled=true` as well (it requires `dataplane.oidc.enabled`);
the admin token keeps working beside it. One block feeds both planes, so they
cannot disagree on issuer, tenant source or role mappings. This replaces the
earlier `controlplane.oidc.issuer`, `jwksURI`, `tenantIDClaim`, `roleClaims`,
`roleMappings` and `allowInsecureTransport`: move them to `dataplane.oidc`, or
the render fails naming the leftover key.

`issuer` may be `http://` or `https://`: it is an identifier compared with the
token's `iss` and never fetched, so an `http://` issuer needs no
`allowInsecureTransport`. On AD FS set it to the discovery document's
`access_token_issuer` (`http://<host>/adfs/services/trust`). `jwksURI` is fetched,
so it must stay `https://` unless `allowInsecureTransport=true`.

The accepted audience is `auth.oidc.audience`, default `api://redis-iris`, the one
Iris API audience shared by every Iris service (the API identifier on most IdPs;
the API's Application (client) ID GUID on Entra ID v2). There is no per-service
override; use the same value in every Iris chart (the UI sign-in setting for it arrives with MOD-19450).
The chart refuses an empty or wildcard value.

### Multi-tenant mode

Leave `tenantId` empty to serve more than one tenant with one release. Then
enable `dataplane.oidc` and `controlplane.oidc`, and set
`dataplane.oidc.tenantIDClaim`. The chart refuses an empty `tenantId` with
other settings. Without SSO, use the single-tenant mode.

Under the `redis-iris` umbrella, set `global.iris.auth.oidc.tenantIdClaim`
instead of `global.iris.tenantId`. The umbrella supplies the OIDC settings
and the hidden UI control-plane route for tenant instance discovery.

In this mode:

- Each caller keeps the tenant of its agent key or of its operator token. A
  caller can read only the instance of its own tenant.
- Each tenant gets its own instance with a random ID. The control plane
  creates it on the first control plane call of the tenant: a visit to the
  Lens page of the UI, or `GET /iris/v1beta1/lens/instance`. `instance.id` is
  not used. You can mint agent keys for the instance only after that call.
- The worker finds the instance of each tenant in the metadata Redis, so the
  chart renders no `assembler.instance_ids`.
- The Identity Service release must be multi-tenant: leave
  `runtime.apiKeyTenant.singleTenantID` empty.
- The control plane refuses the admin token, because the token has no tenant
  of its own. Health and readiness still work. Automation and tests must use an
  IdP token with the tenant claim. While the IdP is down, no operator can call
  the control plane in this mode.
- A change of an existing single-tenant release to the multi-tenant mode does
  not move the old instance. Its data stays under the old instance ID, and
  each tenant gets a new instance. No worker assembles the old instance after
  the change, and the Identity Service accepts no new keys for it. Before the
  change, revoke the agent keys that name `lens-instance:<instance.id>`: else
  they can still send spans to the old instance.
- The worker polls every instance on each poll, so the chart sets the worker
  poll interval to 1s instead of 100ms. All tenants share the storage.
  Thus the readiness of the worker reports the errors of each poll. These are
  the errors of the instance discovery and of the work on each instance. An
  outage of the shared storage thus makes the worker not ready.
- Do not share the metadata Redis or its key prefix with a Neptune Lens
  deployment. Both modes use the same per-tenant index.

In the UI gateway, leave `instanceId` of the `lens` entry unset: the console
gets the instance ID of the signed-in tenant from the control plane. For that
call, add a hidden entry that points at the control plane:

```yaml
products:
  - key: lens
    label: Lens
    product: lens
    authScheme: bearer
    healthPath: /health/readiness
    upstream:
      host: lens-redis-lens-dataplane.<namespace>.svc.cluster.local
      port: 9000
      basePath: ""
      scheme: http
  - key: lens-cp
    label: Lens control plane
    product: lens
    authScheme: bearer
    showInNavigation: false
    healthPath: /health/readiness
    upstream:
      host: lens-redis-lens-controlplane.<namespace>.svc.cluster.local
      port: 9300
      basePath: ""
      scheme: http
```

### Operator token troubleshooting

Agent keys and operator tokens fail for different reasons, so check which one the caller sent:

| Symptom | Likely cause |
| --- | --- |
| Agent keys fail, operator tokens work | The data plane cannot reach the Identity Service, or its runtime credential (`identityService.credential`) is wrong. Check `dataplane.identityServiceBaseURL` and the data-plane logs for introspection errors. |
| Operator tokens fail, agent keys work | Validation against the IdP: an unreachable `dataplane.oidc.jwksURI` (the data plane fetches it directly, so egress to the IdP is needed), an `issuer` or `auth.oidc.audience` that does not match the token's `iss` or `aud`, a role claim that `roleMappings` does not map (403, not 401), a token from another tenant than `tenantId` (also 403), or a token that names no tenant when `tenantIDClaim` is set (401). |
| Operator tokens fail right after the IdP rotated its signing keys | A token with an unknown key ID refreshes the key set at most once every 30 seconds (`auth.oidc.jwks_forced_refresh_min_interval`), so wait that long and retry. |
| An operator gets 403 on `POST /v1/traces` | Expected: operator tokens never ingest. Use an ingest agent key. |

Access follows each credential's own lifetime. Revoking an agent key in the Identity Service ends that key (after the
Identity Service's runtime cache expires) but does not affect operator tokens, and removing an operator's role in the
IdP takes effect only when their current token expires.


## Tenant IdP users

In a standalone Lens release, set `dataplane.tenantIdentityProviders.enabled=true`
to accept users of the IdP records that the Identity Service holds for each
tenant (MOD-19515). The
read API accepts such a user with a `read` grant on the instance. Ingest stays
agent keys only. On the Identity Service release:

- Add `identity-provider-resolve` and `subject-grant-lookup` to the
  `allowedOperations` of the `lens-dataplane` runtime credential.
- Allow the Lens read grants. IdS removes each grant that this list does not
  allow from the grant lookup.

```yaml
subjectGrants:
  allowed:
    - product: lens
      resourceType: lens-instance
      actions: [read]
```

## UI gateway entry

Reads are served by the data plane, so the `iris/ui/helm` gateway's `lens`
entry points at the data-plane Service root. Set its `instanceId` to this
chart's `instance.id`; the console puts it in every read path. For the
multi-tenant mode, see [Multi-tenant mode](#multi-tenant-mode).

```yaml
products:
  - key: lens
    label: Lens
    product: lens
    authScheme: bearer
    healthPath: /health/readiness
    instanceId: default
    upstream:
      host: lens-redis-lens-dataplane.<namespace>.svc.cluster.local
      port: 9000
      basePath: ""
      scheme: http
```

`/api/lens/iris/data/v1beta1/lens/instances/default/sessions/<id>` then reaches
`/iris/data/v1beta1/lens/instances/default/sessions/<id>` on the data plane.

## Tests

```bash
task lens:test:chart        # lint and offline render checks
task lens:test:onprem-kind  # standalone Identity Service + Lens + UI gateway on KinD:
                            # mint keys, ingest, read through the gateway
```

## Health probe migration

Chart `0.1.1` uses `/health/liveness` and `/health/readiness` for the
services changed in this chart. Deploy matching service images that expose these
routes; older images and newer chart probes must not be mixed. Update custom
monitoring URLs at the same time.
