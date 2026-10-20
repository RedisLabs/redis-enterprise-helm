# iris-identity-service

Helm chart for the Iris Identity Service (IdS): runtime authentication and
API-key management shared by Iris products. The chart is installed as its own
release, and product charts connect to it as an external service. It carries no
product defaults: the operator supplies every credential and validator, each
value is used as written, and misconfiguration fails at `helm install`, not at
pod start.

## What it deploys

- One Deployment and one ClusterIP Service on `service.port` (default 9200).
- A ServiceAccount with `automountServiceAccountToken: false`.
- A ConfigMap with the rendered service config and the final credential
  wiring file (token file paths only, no secrets).
- The Control API admin token Secret, `<fullname>-control-token`, unless
  `control.existingSecret` is set. Runtime credential Secrets, only for
  entries with `autoGenerate: true`: `<fullname>-runtime-<name>`, or the
  entry's `generatedSecretName`.
  Generated Secrets are created once and kept across upgrades and uninstalls
  (`helm.sh/resource-policy: keep`).
- One `helm test` Pod that checks `/v1/health/ready`.

It does not deploy Redis, a product control plane or data plane, an Ingress, a
NetworkPolicy, a SecretProviderClass, an HPA, or a metrics port.

## Secret ownership

A Secret that another workload also mounts is owned by that workload and
arrives here as `existingSecret` + `secretKey`. The chart generates only what
IdS alone reads.

| Secret | Who owns it | Values |
|---|---|---|
| Control API admin token | This chart (generated), or you | `control.autoGenerate`, or `control.existingSecret` |
| Metadata Redis config | You | `metadata.existingSecret` (required) |
| Runtime service credential | Your deployment automation, shared with the calling workload (for example a product data plane); this chart only in development | `existingSecret`; `autoGenerate` (+ `generatedSecretName`) in development |
| Product validator credential | The product control plane (its internal token) | `credential.existingSecret` only |

In production and GitOps installs, deployment automation provisions every
runtime credential and both this release and the calling workload reference it
through `existingSecret`.

`autoGenerate` is for development and manual testing only. A generated runtime
credential's Secret is private (`<fullname>-runtime-<name>`) unless
`generatedSecretName` names it. Set `generatedSecretName` when a development
product data plane in the same namespace must mount the token: point the
product chart at that Secret, and do not let the product chart generate a
second credential. `generatedSecretName` requires `autoGenerate: true`, cannot
be combined with `existingSecret`, and must not name any other Secret this
chart references, because the generated Secret replaces it.

No Secret/key pair may be shared between the control token, runtime
credentials and validator credentials.

## Prerequisites

Create these Secrets in the release namespace first.

1. **Metadata Redis config** (required). A Secret whose key (default
   `metadata.yaml`) holds an IdS config overlay:

   ```bash
   cat > metadata.yaml <<'EOF'
   metadata:
     urls: ["redis://metadata-db:6379"]
   EOF
   kubectl create secret generic ids-metadata --from-file=metadata.yaml
   ```

2. **At least one runtime service credential**: the token a product data
   plane presents when calling the IdS Runtime API. The data plane mounts the
   same Secret. Skip this if the entry uses `autoGenerate: true`.

   ```bash
   kubectl create secret generic memory-dp-credential --from-literal=token="$(openssl rand -hex 24)"
   ```

3. **At least one product validator credential**: the product control plane's
   internal token, which IdS presents when validating grants. The control plane
   mounts the same Secret.

   ```bash
   kubectl create secret generic memory-internal-token --from-literal=token="$(openssl rand -hex 24)"
   ```

In production, deployment automation creates the shared Secrets in steps 2 and
3, and both releases reference them. See [Product contracts](#product-contracts)
for the matching product values.

## Install

```bash
helm repo add redis-ai https://helm.redis.io/ai
helm install ids redis-ai/iris-identity-service -f values-ids.yaml
```

With `values-ids.yaml`:

```yaml
metadata:
  existingSecret: ids-metadata
runtime:
  apiKeyTenant:
    singleTenantID: default
  serviceCredentials:
    - name: memory-dp
      subject: memory-dp
      allowedOperations: [api-key-introspect]
      allowedProducts: [memory]
      existingSecret: memory-dp-credential
      secretKey: token
  unscopedGrantsProduct: memory
productValidation:
  products:
    memory:
      enabled: true
      baseURL: http://redis-agent-memory-controlplane:9100
      credential:
        existingSecret: memory-internal-token
        secretKey: token
```

Pin a release with `--version <version>`; list them with
`helm search repo redis-ai/iris-identity-service --versions`.

For development, install from a source checkout instead:
`helm dependency build identity-service/helm`, then
`helm install ids identity-service/helm -f values-ids.yaml`.

## Versions

The chart `version`, its `appVersion`, and the image tag move in lockstep: chart
`0.10.0` deploys `redislabs/iris-identity-service:0.10.0` by default
(`image.tag: ""` resolves to `appVersion`). Every change to a packaged chart file raises the version (files `.helmignore`
excludes, such as `tests/*.sh`, do not count),
and CI (`task identity:test:chart:bump-guard`) fails a change that does not, or
whose `version` and `appVersion` differ.

The first published version is `0.10.0`, the next minor after the `0.7`–`0.9`
image tags that product release trains already pushed. The chart stays `0.x` until
its values and product contracts are stable; until then a minor release may change
them. Releases follow the `.skills/ids-helm-release` runbook.

## Use it

```bash
# Control API admin token
kubectl get secret ids-iris-identity-service-control-token -o jsonpath='{.data.token}' | base64 -d

# Health
helm test ids
```

`helm status ids` prints the same commands for your release name and namespace,
including a custom `control.existingSecret`.

## What `helm test` proves

`helm test` proves that the pod answers HTTP and reaches metadata Redis:
readiness pings metadata Redis (bounded to 500 ms) and fails while it is
unreachable; liveness does not, so a Redis outage takes the pod out of service
without restarting it. Readiness does not probe the product control planes, so
one product's outage never withdraws the shared service; grant validation still
needs them. A passing `helm test` is not proof that the install can mint API
keys. The cross-product KinD harness (`task test:kind`) is: its standalone flow
creates a key through a stub grant validator, introspects it and revokes it.

## Product contracts

Each product release connects to this release as an external service, so the
two releases must agree on Secret names, Service addresses and the tenant.
Neither chart reads the other's values or checks them against its own. Keeping
the releases consistent is the deployment automation's job, and the end-to-end
KinD harness proves that a consistent pair works. `helm test` does not.

The tested layout puts the product release and this release in one namespace,
because each mounts the shared Secrets. The addresses below assume each product
chart's default naming (Memory's `fullnameOverride: redis-agent-memory`, and
Playbook installed as release `playbook`). After changing a product's
`fullnameOverride`, release name or Service port, restate them here.

### Agent Memory

| Set on this release | Value | Matching Memory value |
|---|---|---|
| `runtime.serviceCredentials[]` | `name: memory-dp`, `subject: memory-dp`, `allowedOperations: [api-key-introspect]`, `allowedProducts: [memory]`, `existingSecret` + `secretKey` | `identityService.credential.existingSecret` + `secretKey`: the same Secret, mounted by the data plane |
| `productValidation.products.memory.baseURL` | `http://redis-agent-memory-controlplane:9100` | The control-plane Service `<fullname>-controlplane` on `controlplane.service.port` (default `9100`) |
| `productValidation.products.memory.credential` | The control plane's internal-token Secret and key | `controlplane.internalToken.existingSecret` + `secretKey` (development only: the chart generates `<fullname>-controlplane-internal-token`) |
| `runtime.unscopedGrantsProduct` | `memory` | None: agent keys stored before grants carried a product belong to Memory |
| `runtime.apiKeyTenant.singleTenantID` | Memory's tenant, for example `default` | `tenantId` |

The Memory data plane reaches this release through
`dataplane.identityServiceBaseURL`, for example
`http://ids-iris-identity-service:9200`.

```yaml
runtime:
  unscopedGrantsProduct: memory
  apiKeyTenant:
    singleTenantID: default
  serviceCredentials:
    - name: memory-dp
      subject: memory-dp
      allowedOperations: [api-key-introspect]
      allowedProducts: [memory]
      existingSecret: memory-dp-credential
      secretKey: token
productValidation:
  products:
    memory:
      baseURL: http://redis-agent-memory-controlplane:9100
      credential:
        existingSecret: memory-internal-token
        secretKey: token
```

### Playbook

| Set on this release | Value | Matching Playbook value |
|---|---|---|
| `runtime.serviceCredentials[]` | `name: playbook-dp`, `subject: playbook-dataplane`, `allowedOperations: [api-key-introspect]` (plus `subject-grant-lookup` with `extraction.connection.enabled`), `allowedProducts: [playbook]`, `existingSecret` + `secretKey` | The data plane's runtime credential: the same Secret |
| `productValidation.products.playbook.baseURL` | `http://playbook-redis-agent-playbook-controlplane:9200` | The control-plane Service `<fullname>-controlplane` on `controlplane.service.port` (default `9200`) |
| `productValidation.products.playbook.credential` | The control plane's internal-token Secret and key | `controlplane.internalToken.existingSecret` + `secretKey` (development only: the chart generates `<fullname>-controlplane-internal-token`) |
| `runtime.apiKeyTenant.singleTenantID` | Playbook's tenant, for example `default` | `tenantId` |
| `subjectGrants.allowed` | `{product: playbook, resourceType: playbook, actions: [read, propose]}`, with `extraction.connection.enabled` | Extraction workers read and propose to destination Playbooks |

Playbook extraction reading Agent Memory stores also needs these on the IdS
release that serves Memory (the same release when one IdS serves both):

- The `subjectGrants.allowed` entry
  `{product: memory, resourceType: mem-store, actions: [read]}`. The empty
  default denies every service-subject grant.
- `subject-grant-lookup` in the `memory-dp` credential's `allowedOperations`,
  so the Memory data plane can resolve the Playbook workers' grants.

Playbook's control plane creates those grants through that release's Control
API with its own ServiceAccount JWT (MOD-19110), so that release must also trust
its subject through `controlAuth.workloadIdentity` with `roles:
[subject_grant_admin]` (see [Operator login and subject
grants](#operator-login-and-subject-grants)). No Control token is copied to the
Playbook namespace.

```yaml
runtime:
  apiKeyTenant:
    singleTenantID: default
  serviceCredentials:
    - name: playbook-dp
      subject: playbook-dataplane
      allowedOperations: [api-key-introspect, subject-grant-lookup]
      allowedProducts: [playbook]
      existingSecret: playbook-dp-credential
      secretKey: token
productValidation:
  products:
    playbook:
      baseURL: http://playbook-redis-agent-playbook-controlplane:9200
      credential:
        existingSecret: playbook-internal-token
        secretKey: token
subjectGrants:
  allowed:
    - {product: memory, resourceType: mem-store, actions: [read]}
    - {product: playbook, resourceType: playbook, actions: [read, propose]}
```

When one release serves both products, merge the two blocks: one
`serviceCredentials` list (with `subject-grant-lookup` on `memory-dp`), both
validators, and `unscopedGrantsProduct: memory`. Every product served by one
release uses the same tenant.

## Values

`values.schema.json` is closed: an unknown key, product or operation fails the
install.

| Key | Default | Description |
|---|---|---|
| `global` | `{}` | Shared Iris globals. Only `global.imagePullSecrets`, `global.security.profile` and `global.tls.caCertSecret` are read, as fallbacks for the local keys. |
| `nameOverride` | `""` | Replaces the chart name in resource names. |
| `fullnameOverride` | `""` | Replaces `<release>-iris-identity-service`, and so the Service DNS name. |
| `replicaCount` | `1` | Deployment replicas. |
| `image.repository` | `redislabs/iris-identity-service` | Image repository. |
| `image.tag` | `""` | Empty uses the chart `appVersion`. |
| `image.pullPolicy` | `IfNotPresent` | `Always`, `IfNotPresent` or `Never`. |
| `imagePullSecrets` | `[]` | Pod pull Secrets. Empty falls back to `global.imagePullSecrets`. |
| `tls.caCertSecret` | `""` | Secret with a PEM CA bundle for outbound TLS, mounted at `/etc/ssl/custom` with `SSL_CERT_DIR` set. Empty falls back to `global.tls.caCertSecret`. |
| `tls.caCertKey` | `ca.crt` | Key of the bundle in that Secret. |
| `service.type` | `ClusterIP` | Service type. |
| `service.port` | `9200` | Service and container port; also rendered as the config's `server.port`. |
| `security.profile` | `""` | `""` or `fips`. Empty falls back to `global.security.profile`. See [FIPS](#fips). |
| `configData` | `{}` | Extra IdS config merged underneath the rendered config. See [Config overlay](#config-overlay). |
| `secrets.secretName` | `""` | First policy overlay Secret, loaded after metadata. See [Policy overlays](#policy-overlays). |
| `secrets.additionalSecrets` | `[]` | Further policy overlay Secrets, loaded in order. |
| `secrets.overlayKey` | `overlay.yaml` | Key read from every policy overlay Secret. |
| `secrets.checksum` | `""` | Change to roll the pod after editing policy Secret contents. |
| `metadata.existingSecret` | `""` | **Required.** Secret holding the metadata Redis overlay. |
| `metadata.secretKey` | `metadata.yaml` | Key of the overlay in that Secret. |
| `metadata.existingSecretChecksum` | `""` | Optional; set to roll the pod when the Secret changes. |
| `control.existingSecret` | `""` | Your own Control API token Secret. Empty generates one. |
| `control.secretKey` | `token` | Key of the token. |
| `control.autoGenerate` | `true` | Generate the token when no `existingSecret` is set. |
| `control.existingSecretChecksum` | `""` | Optional checksum for your own Secret. |
| `runtime.cache.softTtlSeconds` | `180` | Introspection cache soft TTL. Must not exceed the hard TTL. |
| `runtime.cache.hardTtlSeconds` | `300` | Introspection cache hard TTL. |
| `runtime.unscopedGrantsProduct` | `""` | Product that owns grants stored before grants carried a product. When set, it must name an enabled validator. |
| `runtime.apiKeyTenant.singleTenantID` | `""` | The installation's one tenant, for example `"default"`. An agent-key grant that names no tenant gets this one, and a grant naming any other tenant is rejected. Empty means strict: every grant must name its tenant, and all grants on a key must name the same one. See [Tenancy](#tenancy). |
| `runtime.serviceCredentials` | `[]` | **At least one.** See [Runtime service credentials](#runtime-service-credentials). |
| `productValidation.products` | `{}` | **At least one enabled.** See [Product validators](#product-validators). |
| `apiKeys.maxRotateGraceSeconds` | `604800` | Longest grace period an API-key rotation may keep the old key alive. |
| `controlAuth.oidc` | `{}` | Operator login to IdS Control with your IdP's JWTs, copied as is into `auth.oidc`. See [Operator login and subject grants](#operator-login-and-subject-grants). |
| `controlAuth.roleBindings` | `[]` | Rendered as `auth.role_bindings`. Requires `controlAuth.oidc.enabled`. |
| `controlAuth.workloadIdentity` | `{}` | Workloads, such as the Playbook control plane, call IdS Control with their own ServiceAccount JWT. Copied into `auth.workload_identity`. See [Operator login and subject grants](#operator-login-and-subject-grants). |
| `subjectGrants.allowed` | `[]` | Service-subject grants this IdS may hold, as `{product, resourceType, actions}`. Empty allows none. |
| `serviceAccount.annotations` | `{}` | ServiceAccount annotations. |
| `podAnnotations` | `{}` | Extra pod annotations. |
| `podLabels` | `{}` | Extra pod labels. |
| `podSecurityContext` | restricted, UID 65532 | Pod security context. |
| `securityContext` | read-only root, no privilege escalation, all capabilities dropped | Container security context. |
| `livenessProbe` | `GET /v1/health/live` | Container liveness probe. |
| `readinessProbe` | `GET /v1/health/ready` | Container readiness probe. |
| `resources` | limits `500m` / `512Mi`, requests `100m` / `128Mi` | Container resources. |
| `volumes` | `[]` | Extra pod volumes, appended to the chart's own. |
| `volumeMounts` | `[]` | Extra container mounts, appended to the chart's own. |
| `nodeSelector` | `{}` | Pod node selector. |
| `affinity` | `{}` | Pod affinity. |
| `tolerations` | `[]` | Pod tolerations. |
| `tests.image` | `curlimages/curl:8.17.0` | Image of the `helm test` Pod. |

### Runtime service credentials

Each `runtime.serviceCredentials[]` entry is a token a caller presents to the
IdS Runtime API:

| Field | Description |
|---|---|
| `name` | **Required.** `^[a-z0-9-]{0,43}[a-z0-9]$` (1–44 characters, no trailing dash), unique. Mounted at `/etc/identity-service/runtime/<name>/token`. |
| `subject` | **Required.** Subject the caller authenticates as. |
| `allowedOperations` | **Required.** Any of `api-key-introspect`, `auth-introspect`, `auth-me`, `subject-grant-lookup`. |
| `allowedProducts` | **Required.** Any of `memory`, `langcache`, `context`, `playbook`, `lens`, `context-gateway`. |
| `existingSecret` | Secret holding the token. Set exactly one of `existingSecret` and `autoGenerate`. |
| `secretKey` | Key of the token (default `token`). |
| `autoGenerate` | Development and manual testing only. Generate the token when `existingSecret` is empty, in `<fullname>-runtime-<name>`. |
| `generatedSecretName` | With `autoGenerate: true` only: name the generated Secret instead, so a development data plane can mount it. |
| `existingSecretChecksum` | Optional checksum for the Secret. |

Helm replaces lists instead of merging them: to add a credential with
`--set` or a second values file, restate the existing entries too.

### Product validators

Each `productValidation.products.<product>` entry, keyed by one of `memory`,
`langcache`, `context`, `playbook`, `lens` or `context-gateway`, is a product
control plane that IdS calls before persisting API-key grants:

| Field | Description |
|---|---|
| `enabled` | Default `true`. A disabled entry renders nothing. |
| `baseURL` | **Required.** Absolute `http://` or `https://` URL with no user info, query or fragment. |
| `credential.existingSecret` | **Required.** The product control plane's internal-token Secret. |
| `credential.secretKey` | Key of the token (default `token`). |
| `credential.existingSecretChecksum` | Optional checksum for the Secret. |

### Config overlay

The chart renders the IdS config and owns `server.port`, `auth.type`,
`auth.control`, `runtime.service_credentials`, `runtime.cache`,
`runtime.unscoped_grants_product`, `runtime.api_key_tenant`,
`product_validation`, `api_keys` and `subject_grants`. A chart-owned key the
chart leaves empty is removed from `configData` too, so `configData` cannot
bypass its guards. `configData` is merged underneath: its
other keys (for example `runtime.oidc`, `opentelemetry`, or other `server` and
`auth` fields) pass through, and a chart-owned key in `configData` is replaced by the
chart's value. There is no bring-your-own full config.

Credential wiring has exactly one source. Supplying `auth.control`,
`runtime.service_credentials` or `product_validation` in `configData` fails
rendering; use `control`, `runtime.serviceCredentials` and
`productValidation` instead. Operator policy also has one source: use either
`configData.auth.oidc` and `configData.auth.role_bindings` (passed through as
written), or `controlAuth`. Setting `configData.auth.oidc` together with
`controlAuth.oidc`, or role bindings or workload identity in both places, fails
rendering.

### Policy overlays

Operator policy that changes after install, such as `runtime.oidc` role
bindings, can live in Secrets instead of values. Each Secret named by
`secrets.secretName` and `secrets.additionalSecrets` holds an IdS config
overlay under `secrets.overlayKey`. IdS loads its config files in this order:

1. The rendered config (`identity-service.yaml`).
2. The metadata Secret.
3. Each policy overlay, in `secrets` order; later files win.
4. The chart's `wiring.yaml`.

Role bindings merge by `(issuer, claim_value, scope, product)`: a later entry
replaces the matching binding, and `role: none` removes it. The final
`wiring.yaml` reapplies `auth.control`, `runtime.service_credentials` and
`product_validation`, so an overlay cannot redirect the Control token, the
runtime credentials or the product callbacks to unmounted token files.

```yaml
secrets:
  secretName: ids-policy
  additionalSecrets: [ids-policy-emergency]
```

A Secret edited in place is mounted as a whole volume, so the file updates,
but IdS reads config only at startup. Change `secrets.checksum` (or restart
the pod) to apply the new contents.

### Tenancy

Every agent key carries a tenant:

- A single-tenant installation sets `runtime.apiKeyTenant.singleTenantID`, for
  example `default`. IdS stamps it on every grant at write time.
- A multi-tenant installation leaves it empty. Requests made with the static
  Control admin token must name the tenant in every grant; IdS rejects a grant
  without one. For operator login, enable `controlAuth.oidc` with
  `tenant_id_claim`, so each operator token names its tenant, or with
  `static_tenant_id`. Rendering fails when an enabled `oidc` has no tenant
  source, because its operators could never create a key.

OIDC set through `configData.auth.oidc` instead of `controlAuth.oidc` counts
the same: it is a tenant source, gets `singleTenantID` stamped in, and fails the
same conflict checks.

`runtime.apiKeyTenant.allowTenantlessGrants` was removed (MOD-19463): the
schema rejects it, and IdS refuses to start with `allow_tenantless_grants` in
its config.

### Operator login and subject grants

`controlAuth` lets operators sign in to IdS Control with their IdP's JWTs.
`controlAuth.oidc` uses the binary's snake_case fields and is checked by the
binary at startup. The chart adds the tenant rule:

- An enabled `oidc` needs a tenant source (see [Tenancy](#tenancy)): `runtime.apiKeyTenant.singleTenantID`,
  `tenant_id_claim` or `static_tenant_id`.
- A set `singleTenantID` is the deployment's one tenant. It is stamped in as
  `static_tenant_id`, and rendering fails if `tenant_id_claim` or a different
  `static_tenant_id` is also set.
- `roleBindings` requires `oidc.enabled`.

```yaml
runtime:
  apiKeyTenant:
    singleTenantID: "default"
controlAuth:
  oidc:
    enabled: true
    issuer: https://idp.example.com
    jwks_uri: https://idp.example.com/jwks
    audience: [api://identity-service]
  roleBindings:
    - {claim_value: memory-admins, scope: product, product: memory, role: product_admin}
```

`controlAuth.workloadIdentity` (MOD-19110) lets a workload call IdS Control with
its own projected ServiceAccount JWT instead of the control token. The Playbook
control plane uses it to provision subject grants for extraction. The binary
validates the block and requires `subject_grant_admin`-style roles in one tenant
per subject, never `suite_admin`. A subject without a `tenant` gets
`runtime.apiKeyTenant.singleTenantID`; a different `tenant` fails rendering. The
same applies to `configData.auth.workload_identity`, the alternative single
source. With
no `singleTenantID`, set `tenant` on every subject. It must be the Playbook
chart's `tenantId`, because the Playbook control plane requests every grant in
that tenant.

```yaml
controlAuth:
  workloadIdentity:
    enabled: true
    issuer: https://kubernetes.default.svc.cluster.local
    jwks_uri: https://kubernetes.default.svc/openid/v1/jwks
    audience: [api://memory-identity-control]   # Playbook sourceControlAudience
    subjects:
      - subject: system:serviceaccount:<namespace>:<playbook-fullname>-controlplane
        roles: [subject_grant_admin]
```

The Identity Service pod must reach that JWKS and trust its CA
(`tls.caCertSecret`). The control token stays the rescue credential.

`subjectGrants.allowed` lists the service-subject grants this IdS may hold, for
example Playbook extraction reading Agent Memory stores. The schema checks the
product; the binary refuses to start if a resource type or action is outside
what that product allows for service subjects.

```yaml
subjectGrants:
  allowed:
    - {product: memory, resourceType: mem-store, actions: [read]}
```

### Checksums

The pod carries `checksum/config` over the rendered config,
`checksum/policy-overlays` over the `secrets` values, plus one annotation
per Secret: a hash of the token for Secrets this chart generates, and the
matching `existingSecretChecksum` for Secrets you own (omitted when empty).
Deleting a generated Secret rotates its token on the next `helm upgrade`, which
also rolls the pod.

## GitOps

`helm template` (and Argo CD or Flux, which render the same way) has no cluster
access, so the lookup that keeps a generated token across upgrades finds
nothing: every render mints a new control token and new `autoGenerate` runtime
tokens, and every sync rolls the pod. Under GitOps, deployment automation
creates the Secrets out of band (for example with Sealed Secrets or External
Secrets): set `control.existingSecret`, and `existingSecret` on every runtime
credential. Shared credentials are already automation-owned: the product
release references the same runtime-credential and internal-token Secrets, so
neither chart generates them.

## Private CA trust

To reach a `rediss://` metadata Redis or an `https://` product control plane
signed by a private CA, put the PEM bundle in a Secret and set
`tls.caCertSecret` (or `global.tls.caCertSecret`). IdS trusts it
in addition to the system CAs. The chart offers no way to skip certificate
verification.

```bash
kubectl create secret generic ids-certificate-authority --from-file=ca.crt=./my-ca.pem
helm upgrade --install ids redis-ai/iris-identity-service -f values-ids.yaml --set tls.caCertSecret=ids-certificate-authority
```

## Delegated control-plane auth

Delegated auth needs no special values. Deployment automation provisions the
delegated-auth token Secret, which the product control plane also mounts, and
this release references it through an ordinary `existingSecret` entry:

```yaml
runtime:
  serviceCredentials:
    - name: memory-delegated-auth
      subject: memory-controlplane
      allowedOperations: [auth-introspect]
      allowedProducts: [memory]
      existingSecret: memory-delegated-auth
      secretKey: token
```

## FIPS

`security.profile` (or `global.security.profile`) is passed through only: it
sets `IDS_SECURITY_PROFILE` and `GODEBUG=fips140=on`. The chart adds no FIPS
guards and ships no FIPS values file.

The policy (G6,
[MOD-19254](https://redislabs.atlassian.net/browse/MOD-19254)):

- FIPS is allowed without an IdS TLS listener. Like every Iris service, IdS
  leaves inbound TLS to the hosting environment (ingress, service mesh or load
  balancer).
- Bearer-carrying hops must be `https://` under FIPS, with no opt-out. That
  includes IdS→product validator calls, which carry the control plane's internal
  token.
- The binary is the authority. `ValidateFIPSPosture` in
  `identity-service/internal/infrastructure/fips_posture.go` refuses to start on
  a non-`rediss://` metadata URL, a Runtime OIDC product with
  `allow_insecure_transport` or `skip_verify`, or (from
  [MOD-19267](https://redislabs.atlassian.net/browse/MOD-19267)) a non-`https://`
  `productValidation.products.*.baseURL`.
- Product charts keep fail-fast `https://` guards on the URLs they author.
