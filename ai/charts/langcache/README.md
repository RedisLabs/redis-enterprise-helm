# LangCache on-prem Helm chart

One `helm install` of this chart creates:

- the LangCache **Data Plane** (`redislabs/iris-langcache-data`) — the
  semantic-cache API your applications call, with autoscaling and optional
  ingress;
- the LangCache **Control Plane** (`redislabs/iris-langcache-control`) — the
  operator/administration API for creating and managing caches;
- either a **bundled Identity Service** (`redislabs/iris-identity-service`,
  the default) or a wire-up to an **external** one your suite already runs.

The chart never installs Redis, an embedding server, the cloud Control Plane,
or LangCache metrics — those are operator-provided or out of scope. It
depends internally on the shared `redis-iris-onprem-lib` Helm library (also
used by Redis Agent Memory); that dependency is not published separately and
is vendored automatically wherever this chart is packaged.

## Before you install

| Area | Requirement | Notes |
| --- | --- | --- |
| Metadata Redis | Redis 6.2+ | LangCache CP and DP cache metadata store. Can be the same Redis instance for both, in separate keyspaces/namespaces of your choosing. |
| Cache database registry | One or more Redis instances with the search module | Where cache entries and their vectors actually live. Registered by ID in `dataplane.secrets`/`controlplane.secrets` overlays. |
| Embedding endpoint | An OpenAI-compatible embeddings API | Public endpoint URL and model/dimensions are chart values; the credential (if any) is a Secret. |
| Kubernetes | 1.23+ | The chart renders an `autoscaling/v2` HorizontalPodAutoscaler by default. |

The chart requires, at minimum:

- `dataplane.image.tag` and `controlplane.image.tag`;
- `dataplane.license.existingSecret` (LICENSE material, shared by DP and CP);
- `dataplane.secrets.secretName` and `controlplane.secrets.secretName`
  (pre-created overlay Secrets — see "Supplying credentials" below);
- `dataplane.embedding.endpoint.baseURL`, `dataplane.embedding.models.defaultEmbeddingModel`,
  and `dataplane.embedding.models.dimensions`;
- `identityService.mode` (`bundled` or `external`; defaults to `bundled`),
  plus that mode's own required inputs (see "Identity Service" below).

## Image access

```yaml
dataplane:
  image:
    repository: redislabs/iris-langcache-data
    tag: "1.0.0"
controlplane:
  image:
    repository: redislabs/iris-langcache-control
    tag: "1.0.0"
identityService:
  bundled:
    image:
      repository: redislabs/iris-identity-service
      tag: "1.0.0"
imagePullSecrets:
  - name: my-registry-secret
```

```bash
kubectl create secret docker-registry my-registry-secret \
  --docker-server=<registry> --docker-username=<user> --docker-password=<password>
```

## Required Secrets

LICENSE material, shared by the Data Plane and Control Plane:

```bash
kubectl create secret generic langcache-license --from-file=license=./langcache.key
```

## Supplying credentials

Metadata Redis URLs, the cache database registry, and (when
`dataplane.embedding.credentials.type=static`) the embedding credential never
go in `values.yaml` or the rendered ConfigMap. Each of the Data Plane and
Control Plane reads its own pre-created overlay Secret, deep-merged over its
rendered config by the loader at runtime:

```bash
kubectl create secret generic dp-overlay --from-file=overlay.yaml=./dp-overlay.yaml
kubectl create secret generic cp-overlay --from-file=overlay.yaml=./cp-overlay.yaml
```

`dp-overlay.yaml`:

```yaml
metadata:
  urls:
    - rediss://user:pass@metadata-redis:6380
databases:
  target-a:
    name: Target A
    urls:
      - rediss://user:pass@cache-db-a:6380
embedding:
  credentials:
    api_key: sk-...
```

`cp-overlay.yaml` (no embedding credential — the Control Plane never
receives one):

```yaml
metadata:
  urls:
    - rediss://user:pass@metadata-redis:6380
databases:
  target-a:
    name: Target A
    urls:
      - rediss://user:pass@cache-db-a:6380
```

Point the chart at them:

```yaml
dataplane:
  secrets:
    secretName: dp-overlay
controlplane:
  secrets:
    secretName: cp-overlay
```

Rotate a Secret's contents by editing it and bumping the matching
`existingSecretChecksum` value (e.g. `dataplane.config.existingSecretChecksum`,
`dataplane.secrets.existingSecretChecksum`) to force a rollout on the next
`helm upgrade` — the chart cannot see BYO Secret contents at render time, so
this is how "rotate = update value + checksum + upgrade" works. This applies
to `helm install`/`helm upgrade` against a live cluster; `helm template`
(and other offline/dry-run renders) can't see existing auto-generated token
Secrets either, so those always mint a fresh random value in that mode —
harmless for previewing manifests, but don't use `helm template` output to
recover a token.

## Install

The commands below assume your working directory is this chart's root
(`langcache/helm/`), matching the relative paths used throughout this file.

Quick start:

```bash
kubectl create secret generic langcache-license --from-file=license=./langcache.key
kubectl create secret generic dp-overlay --from-file=overlay.yaml=./dp-overlay.yaml
kubectl create secret generic cp-overlay --from-file=overlay.yaml=./cp-overlay.yaml
kubectl create secret generic ids-metadata --from-file=metadata.yaml=./ids-metadata.yaml

helm install langcache . -f examples/basic/values.yaml --atomic --wait
```

See `examples/basic/values.yaml` for a complete bundled-Identity-Service
install, and `examples/external-identity-service/values.yaml` for wiring the
Data Plane to an Identity Service the suite already runs.

## Identity Service

The Data Plane always authenticates by introspecting agent-key API keys
against an Identity Service. Choose exactly one mode:

### Bundled (default)

`identityService.mode: bundled` renders the Identity Service Deployment and
Service, auto-generates its control token and the Data Plane's own runtime
credential (scoped to `api-key-introspect` on product `langcache` only), and
wires its `product_validation.langcache` to this release's own Control Plane
internal endpoint and `internalToken`. Requires
`identityService.bundled.image.tag` and
`identityService.bundled.metadata.existingSecret` (a Secret holding the
bundled Identity Service's own metadata Redis URL, e.g. `metadata: {urls: [...]}`).

```bash
kubectl create secret generic ids-metadata --from-file=metadata.yaml=./ids-metadata.yaml
```

### External

`identityService.mode: external` renders no Identity Service workload. Set:

```yaml
identityService:
  mode: external
  external:
    baseURL: https://suite-identity-service.example.com
    credential:
      existingSecret: langcache-dp-ids-credential
      secretKey: token
```

`langcache-dp-ids-credential` is minted out of band by the suite-level
Identity Service owner. **You must also ask them to configure that Identity
Service's own `product_validation.langcache` against this release's Control
Plane internal Service** (`<release>-controlplane:<controlplane.service.port>`)
and `controlplane.internalToken` Secret — this chart has no way to reach
into an Identity Service it doesn't own.

## FIPS-oriented posture

`security.profile: fips` sets `GODEBUG=fips140=on` on every container
(Data Plane, Control Plane, and — in bundled mode — Identity Service), and:

- refuses to render with `identityService.mode=bundled` — the bundled
  Identity Service Service has no TLS termination of its own, so its
  in-cluster address is always `http://`, which the profile exists to
  forbid. Use `identityService.mode=external` with a TLS-fronted Identity
  Service instead;
- refuses `identityService.external.baseURL` unless it is `https://` (or
  `allowInsecureTransport: true` is explicitly set, which is not
  recommended under `fips`).

This is **not** a formal FIPS compliance claim — it is an opt-in posture
that activates the Go runtime's FIPS module and closes the specific gaps
listed above.

## Testing

`tests.enabled: false` by default. Enabling it renders the shared
security-profile GODEBUG check (one per workload this release actually
renders) and the minimal Deployment-read RBAC those checks need:

```bash
helm test langcache --logs
```

`tests.smoke.enabled: false` independently gates an additional `helm test`
hook that proves authenticated set/search/delete of one uniquely generated
cache entry. It expects a cache and API key to already exist — this hook
never creates them:

```bash
kubectl exec -it <control-plane-pod> -- curl -X POST http://localhost:9100/v1/caches ...   # create a READY cache
# mint an Iris API key through the Identity Service scoped to langcache/lc-cache,
# then store its plaintext token:
kubectl create secret generic langcache-smoke-key --from-literal=token=<plaintext-token>
```

```yaml
tests:
  enabled: true
  smoke:
    enabled: true
    cacheID: <the cache ID you created>
    apiKey:
      existingSecret: langcache-smoke-key
```

## Support bundles and preflight

`supportPackage.enabled: true` (default) ships a namespace-scoped
[Troubleshoot](https://troubleshoot.sh) spec as a ConfigMap. Collect it with:

```bash
kubectl support-bundle --namespace <namespace> --load-cluster-specs -l troubleshoot.sh/kind=support-bundle
```

The bundle excludes Secret contents, LICENSE data, Redis URLs,
admin/internal/runtime credentials, API-key material, prompts, responses,
vectors, and cache records — see the redactor spec in the same namespace
(`langcache-support-redactors`) for the exact rules.

`preflight.enabled: true` (default) ships a cluster preflight check as both
a ConfigMap and a standalone file (`support/langcache-preflight.yaml`) for
`kubectl preflight` before you install:

```bash
kubectl preflight support/langcache-preflight.yaml
```

## Verify

```bash
kubectl rollout status deployment/langcache
kubectl rollout status deployment/langcache-controlplane
kubectl rollout status deployment/langcache-identity-service   # bundled mode only
```

## Update

Run from this chart's root (`langcache/helm/`), same as Install:

```bash
helm upgrade langcache . -f my-values.yaml --atomic --wait
```
