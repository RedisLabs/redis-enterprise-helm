<!-- markdownlint-disable MD013 MD060 -->

# Redis Agent Memory On-Premises Deployment

This chart deploys Redis Agent Memory into a customer-managed Kubernetes cluster.
One release creates:

- `redis-agent-memory` API server
- `redis-agent-memory-worker` background worker

Both workloads use the same license Secret and the same shared application config Secret.

## Before you install

- Kubernetes 1.19+
- Helm 3+
- Redis endpoints reachable from the cluster
- A license is required to use the on-prem version. Please reach out to your Redis account representative. If you don’t have one, you can contact our sales team here: <https://redis.io/meeting/>
- a RAM image accessible from the cluster

Prerequisite matrix:

| Area | Requirement | Notes |
| --- | --- | --- |
| Kubernetes | Kubernetes 1.19+ and Helm 3+ | The chart installs standard `apps/v1` Deployments, Services, optional HPAs, optional Ingress, and pre-created Secrets. |
| Content store Redis | Redis 7.2.0 through 8.4.x with RedisJSON and RediSearch / Query Engine, reachable from the RAM server and worker pods | Configure content store endpoints in `metadata.stores[].urls`. The content store holds session memory JSON documents and long-term memory hashes, so it must support JSON commands, hashes, TTLs, `FT.CREATE`, `FT.SEARCH`, JSON indexing, and vector `HNSW` fields. The long-term-memory index uses a `VECTOR` field named `text_vector` with `FLOAT64`, `HNSW`, and `COSINE`. When Redis Cloud databases are selected through the controlplane, the code also requires an active Pro or Essentials database, a public endpoint, default user credentials, a non-Active-Active deployment, and a RediSearch module reported as `search` or `searchlight`. |
| Job Redis | Redis 6.2+ with Redis Streams, reachable from the RAM server and worker pods | Configure the job Redis endpoint in `background_jobs.redis_streams.urls`. On-prem async work requires `background_jobs.redis_streams.enabled=true`; other async backends are rejected. The job Redis must support Streams and consumer groups (`XADD`, `XGROUP`, `XREADGROUP`, `XACK`, `XDEL`, `XAUTOCLAIM`), strings with TTL for deduplication (`SET NX`, `GET`, `DEL`), and sorted sets for delayed jobs (`ZADD`, range/removal operations). It does not need RediSearch or RedisJSON unless the same Redis also serves as the content store. |
| Architecture support | Released RAM on-prem images should be treated as `linux/amd64` unless the release artifact explicitly declares a multi-arch manifest | The release pipeline currently builds and pushes a single runner-native Linux image. For ARM64 nodes, use a compatible locally built image or schedule RAM pods onto AMD64 nodes. |

Recommended deployment model:

- run one Redis Agent Memory release per namespace
- keep the default in-cluster server address `http://redis-agent-memory:9000`
- if you override `fullnameOverride` or run multiple releases in one namespace, update `dataplane_client.base_url` in the shared config file to match

The chart requires:

- `license.existingSecret`
- `config.existingSecret`
- `image.tag`

## Required Secrets

Create two Secrets:

- a license Secret containing key `license`
- a config Secret containing key `memory-dataplane.config.yaml`

```sh
kubectl create namespace <namespace-name>

kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license

kubectl -n <namespace-name> create secret generic ram-config \
  --from-file=memory-dataplane.config.yaml=./memory-dataplane.config.yaml
```

If your Secret keys use different names, set `license.secretKey` or `config.secretKey`
in your Helm values.

## Shared Config File

The server and worker both consume the same file from the config Secret.

Use this as a starting point for your `memory-dataplane.config.yaml`:

```yaml
# HTTP server timeouts for the API process.
server:
  # Maximum time to read request headers and body.
  read_timeout: 30s
  # Maximum time to write the response.
  write_timeout: 30s
  # Overall request handling timeout.
  timeout: 30s

# Enterprise license. The chart mounts the license Secret as a file at
# {license.mountDir}/{license.fileName} (default: /etc/redis-agent-memory/license).
# Point license_path at that location so the service can read it on startup.
license:
  license_path: /etc/redis-agent-memory/license

# Default extraction behavior for stores that do not set extraction_strategy.
default_extraction_strategy: instruct

# Redis client pool settings shared by the service.
client_pool:
  # Enable pooled Redis clients.
  enable: true
  # Maximum pooled clients across all configured stores.
  max_size: 1000
  # Retry count when opening Redis clients.
  max_retries: 10
  # Wait time for a pooled client before failing a request.
  client_acquisition_timeout_ms: 2000

# Background job execution backend.
background_jobs:
  # Redis Streams is the supported async backend for on-prem deployments.
  redis_streams:
    # Enable Redis Streams processing.
    enabled: true
    # Redis endpoint(s) used for the job queue.
    urls:
      # Replace with the Redis endpoint that backs async jobs.
      - redis://redis-jobs:6379
    # Stream name used by the server and worker.
    stream_name: memory-jobs
    # Interval for scanning delayed jobs that are due.
    delayed_poll_interval: 1s
    # How long a worker blocks waiting for new jobs.
    block_duration: 5s
    # How long a pending job can be idle before another worker can claim it.
    claim_idle_time: 30s
    # Maximum delivery attempts before the job is treated as failed.
    max_delivery_count: 3
    # Retention for deduplication state keyed by job ID.
    deduplication_ttl: 24h
    # Timeout for Redis operations against the job backend.
    operation_timeout: 30s
    # Maximum time allowed for one job handler run.
    handler_timeout: 5m

# Memory store definitions exposed by the API.
metadata:
  stores:
    # Stable store identifier used in API paths and job payloads.
    - id: "00000000000000000000000000000001"
      # Redis endpoint(s) that store short-term and long-term memory.
      urls:
        # Replace with the Redis endpoint for this memory store.
        - redis://redis-store:6379
      # Store-specific extraction strategy. Omit to use default_extraction_strategy.
      extraction_strategy: instruct
      short_memory:
        # Retention period for short-term memory entries, in seconds.
        ttl_seconds: 86400
      long_term_memory:
        # Key that selects a provider from embedders_connection_details.
        embedding_provider: openai
        # Embedding model name expected by the selected provider.
        embedding_model: text-embedding-3-large
        # Embedding vector size produced by the model.
        embedding_dimensions: 3072

# Embedding provider connection settings.
embedders_connection_details:
  # Provider name referenced by metadata.stores[].long_term_memory.embedding_provider.
  openai:
    # Base URL for embedding requests.
    base_url: https://api.openai.com
    credentials:
      # Use static API key authentication for the embedding provider.
      type: static
      # API key presented to the embedding provider.
      api_key: "<embedder-api-key>"

# Worker-to-server callback settings.
dataplane_client:
  # In-cluster address of the RAM API service.
  base_url: http://redis-agent-memory:9000
  auth:
    # Disable worker-to-server auth for typical on-prem deployments.
    disabled: true
    # Shared passphrase to use only if auth is enabled.
    passphrase: ""
  http_client:
    # Keep TLS verification enabled unless you deliberately use self-signed certs.
    skip_verify: false
    # Per-request timeout for worker calls back into the API server.
    timeout: 30s
    # Retry count for transient callback failures.
    max_retry_attempts: 3

# Long-term memory promotion model settings.
promote_session_memory:
  # Optional per-strategy windows used to batch rapid session writes into one
  # promotion job. Each strategy defaults to 5m when omitted; set to 0s to
  # schedule promotion immediately. Override with
  # MEM_PROMOTE_SESSION_MEMORY_STRATEGIES_INSTRUCT_PROMOTION_DEDUPLICATION_WINDOW
  # or MEM_PROMOTE_SESSION_MEMORY_STRATEGIES_SUMMARY_PROMOTION_DEDUPLICATION_WINDOW.
  strategies:
    summary:
      promotion_deduplication_window: 5m
      llm:
        # LLM provider used for summary promotion.
        provider: openai
        endpoint:
          # Base URL for the promotion LLM API.
          base_url: https://api.openai.com/v1
          # Request timeout for promotion calls.
          timeout: 30s
          # Header style used to send credentials.
          auth_format: bearer
        credentials:
          # Use static API key authentication for the promotion LLM.
          type: static
          # API key used for promotion requests.
          api_key: "<promotion-llm-api-key>"
        models:
          # Chat model used to extract long-term memory from conversations.
          default_chat_model: gpt-4o
        http_client:
          # Keep TLS verification enabled unless you deliberately use self-signed certs.
          skip_verify: false
          # Per-request timeout for promotion calls.
          timeout: 30s
          # Retry count for transient promotion LLM failures.
          max_retry_attempts: 3
    instruct:
      promotion_deduplication_window: 5m
      llm:
        # LLM provider used for instruct promotion.
        provider: openai
        endpoint:
          # Base URL for the promotion LLM API.
          base_url: https://api.openai.com/v1
          # Request timeout for promotion calls.
          timeout: 30s
          # Header style used to send credentials.
          auth_format: bearer
        credentials:
          # Use static API key authentication for the promotion LLM.
          type: static
          # API key used for promotion requests.
          api_key: "<promotion-llm-api-key>"
        models:
          # Chat model used to extract long-term memory from conversations.
          default_chat_model: gpt-4o
        http_client:
          # Keep TLS verification enabled unless you deliberately use self-signed certs.
          skip_verify: false
          # Per-request timeout for promotion calls.
          timeout: 30s
          # Retry count for transient promotion LLM failures.
          max_retry_attempts: 3
```

Most important config fields:

- `background_jobs.redis_streams.urls`: Redis Streams backend used for async work
- `metadata.stores[].urls`: Redis databases that hold short-term and long-term memory
- `metadata.stores[].short_memory.ttl_seconds`: short-term memory retention
- `metadata.stores[].long_term_memory.*`: embedding provider, model, and vector size
- `embedders_connection_details`: embedding endpoint and credentials
- `promote_session_memory.strategies.<summary|instruct>.llm.*`: promotion LLM endpoint, auth, and model
- `promote_session_memory.strategies.*.promotion_deduplication_window`: optional per-strategy window for batching rapid session writes into one promotion job; defaults to `5m`; set to `0s` for immediate promotion
- `client_pool.max_size`: connection pool size for higher concurrency
- `dataplane_client.base_url`: worker to server callback URL

## Install

Create checksum values for the external Secrets. Change these values whenever the
license file or config file changes so the pods roll automatically.

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
CONFIG_CHECKSUM="$(shasum ./memory-dataplane.config.yaml | awk '{print $1}')"
```

Create a values file, e.g., `ram-values.yaml`:

```yaml
license:
  existingSecret: ram-license
  existingSecretChecksum: "<license-checksum>"

config:
  existingSecret: ram-config
  existingSecretChecksum: "<config-checksum>"

image:
  repository: redislabs/agent-memory
  tag: "<ram-version>"
```

Install the chart:

```sh
helm repo add redis-ai https://helm.redis.io/ai
helm repo update

helm install <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  --create-namespace \
  -f ram-values.yaml \
  --atomic \
  --wait
```

## Rotate the License

The chart mounts the license Secret into both the server and worker pods, but
Redis Agent Memory reads and validates the license file during process startup.
Its background license checks validate the cached license state; they do not
reread the mounted Secret file. Rotate the license by updating the Secret and
changing `license.existingSecretChecksum` so Helm rolls both Deployments.

Replace the data in the existing license Secret:

```sh
kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license \
  --dry-run=client \
  -o yaml | kubectl apply -f -
```

If the original Secret was created with `kubectl create`, `kubectl apply` may
warn that the Secret is missing the `last-applied-configuration` annotation.
That warning is expected; Kubernetes patches the annotation and updates the
Secret.

If your deployment uses a custom license Secret name, use the value from
`license.existingSecret`. If your Secret uses a custom key, keep using the key
from `license.secretKey`.

Recalculate the checksum from the same license file and update `ram-values.yaml`:

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
```

```yaml
license:
  existingSecret: ram-license
  existingSecretChecksum: "<new-license-checksum>"
```

Apply the change with Helm:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f ram-values.yaml \
  --atomic \
  --wait
```

Confirm both workloads rolled and accepted the new license:

```sh
kubectl -n <namespace-name> rollout status deploy/redis-agent-memory
kubectl -n <namespace-name> rollout status deploy/redis-agent-memory-worker
kubectl -n <namespace-name> logs deploy/redis-agent-memory | grep 'License validated successfully'
kubectl -n <namespace-name> logs deploy/redis-agent-memory-worker | grep 'License validated successfully'
```

For immutable Secrets, create a new Secret name instead, then update both
`license.existingSecret` and `license.existingSecretChecksum` before running the
same `helm upgrade`.

## Critical Helm Parameters

Use these values to tune the deployment:

| Area | Parameters | When to change |
| --- | --- | --- |
| Image | `image.repository`, `image.tag`, `imagePullSecrets` | private registry, mirrored images, version selection |
| Air-gapped installs | `airgap.enabled` | require a non-public image repository |
| API server capacity | `server.resources`, `server.autoscaling.*` | higher request volume or larger memory footprint |
| Worker capacity | `worker.resources`, `worker.autoscaling.*` | higher background job volume |
| Scheduling | `server.nodeSelector`, `worker.nodeSelector`, `server.affinity`, `worker.affinity`, `server.tolerations`, `worker.tolerations` | placement control in larger clusters |
| Networking | `service.type`, `ingress.*` | expose the API outside the cluster |
| Naming | `fullnameOverride` | multiple RAM releases in one namespace |
| Service account | `serviceAccount.*` | custom namespace security policy |
| Secret rollouts | `license.existingSecretChecksum`, `config.existingSecretChecksum` | force restart after external Secret updates |

Do not use floating image tags in production.

## FIPS-Oriented Posture

Redis Agent Memory ships an opt-in FIPS-oriented posture for regulated on-prem
environments. It is designed to match the expectations most "FIPS mode"
deployments have, without overclaiming the formal compliance status of the
cryptographic module used.

### What we claim, and what we do not

- We use Go's native FIPS cryptographic module (linked at build time with
  `GOFIPS140=v1.0.0`) when the on-prem image is built. When the posture is
  enabled, the binary runs with `GODEBUG=fips140=on`, which restricts TLS
  negotiation and key generation to the algorithms the FIPS module implements.
- **We do not claim formal FIPS 140 compliance or validation.** At the time
  this chart is released, Go's documentation states that cryptographic module
  validations are ongoing. This deployment is designed to be compatible with a
  future validated module and with customer-side FIPS requirements, but the
  presence of the posture flag is not by itself a compliance attestation.
- The posture layer is a best-effort guardrail. It does not replace an audit,
  a validated boundary, or a compliance officer's review.

### How to enable it

Apply the bundled `values-fips.yaml` overlay alongside your normal values:

```sh
helm upgrade --install redis-agent-memory redis-ai/redis-agent-memory \
  --values ram-values.yaml \
  --values <path-to-chart>/values-fips.yaml \
  --namespace <namespace-name> \
  --atomic --wait
```

That overlay sets `security.profile=fips`, which is the only knob the chart
needs. The chart rejects any other value at install/upgrade time via
`values.schema.json`, so a typo like `fisp` fails loudly instead of silently
falling back to the default posture.

When `security.profile=fips` the chart:

- sets `MEM_SECURITY_PROFILE=fips` on both the server and worker containers;
- surfaces the active profile in `helm status` / `NOTES.txt` output;
- triggers the image's entrypoint to set `GODEBUG=fips140=on` at process start.

When the posture is active the binary additionally refuses to start if the
mounted config:

- enables `skip_verify` on any outbound HTTP client (`dataplane_client.http_client`,
  `promote_session_memory.strategies.summary.llm.http_client`,
  `promote_session_memory.strategies.instruct.llm.http_client`, or
  `embedding.http_client`); or
- uses a non-`rediss://` URL for any Redis connection
  (`background_jobs.redis_streams.urls`, `metadata.stores[].urls`).

All violations are reported together at startup, so you never have to fix
them one restart at a time.

### TLS ownership

This chart does not terminate TLS on the API service itself. The server
process speaks plain HTTP on its listener. TLS at the edge is the hosting
environment's responsibility — terminate TLS at your ingress, service mesh,
or external load balancer. Outbound TLS (to Redis, to the embedding provider,
to the promotion LLM, and to the worker-to-server callback URL if you
expose it externally) is configured through the shared config file and is
what the FIPS posture enforces.

### Hosting access requirement

On-prem Agent Memory does not implement in-process authentication for the
API. This is a deliberate product decision, and the FIPS posture does not
change it. Access control for the API **must** be enforced by your hosting
environment — typically some combination of:

- a Kubernetes `NetworkPolicy` that restricts ingress to the pod,
- an ingress controller or service mesh that authenticates callers, and
- network boundaries (VPC, private subnets, VPN / zero-trust agent) that
  prevent arbitrary workloads from reaching the service.

The binary logs a one-time banner on startup (at `WARN` level) reminding
operators of this when `security.profile=fips` is set. The banner is a
prompt to verify your network isolation; it is **not** evidence that the
isolation exists.

### NetworkPolicy reference

This chart ships `networkpolicy.reference.yaml` as a reference manifest rather
than a Helm template because allowed callers are environment-specific. Customize
the placeholders before applying it:

- `<namespace>`: the namespace where the chart is installed
- `<release-name>`: the Helm release name (`.Release.Name`). Note that
  `nameOverride` and `fullnameOverride` change rendered resource names but do
  **not** change the `app.kubernetes.io/instance` selector label, which always
  equals `.Release.Name`. Policy names are also release-scoped so that multiple
  RAM releases can coexist in the same namespace without collision.
- `<caller-namespace>` and caller pod labels: the ingress controller, service
  mesh gateway, or application pods that are allowed to call the RAM API

The reference policy first default-denies ingress to the chart pods, then allows
TCP traffic to the server pods on port `9000` from the worker Deployment and
from the approved caller selector. Review it against your CNI implementation and
cluster ingress path before using it in production.

### Two control planes caveat (advanced)

The FIPS runtime posture has two control surfaces:

1. **Build-time** (`GOFIPS140`): linked into the image itself. Without an
   explicit `GODEBUG` override, a binary built with `GOFIPS140=v1.0.0` runs
   with `fips140=on` by default.
2. **Runtime** (`GODEBUG=fips140=on|off`): set by the image entrypoint
   based on `MEM_SECURITY_PROFILE`. This is what makes the profile an
   opt-in toggle rather than a silent behavior change for existing
   deployments.

The supported launch path is the image's entrypoint. If an operator
bypasses the entrypoint (for example by running `/server` directly inside
the image, or by overriding `command:` in a custom manifest), the runtime
falls back to the build-time default, which is `fips140=on`. That is an
unsupported launch path, not a guaranteed non-FIPS mode. If you need
a strictly non-FIPS binary for benchmarking or debugging, keep
`security.profile` unset and use the chart's generated Deployment as-is.

### Verifying the posture at runtime

After install, the Deployment carries `MEM_SECURITY_PROFILE` as a literal
env var. You can confirm both the chart wiring and the image behavior with:

```sh
kubectl -n <ns> get deploy redis-agent-memory \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MEM_SECURITY_PROFILE")].value}'

kubectl -n <ns> logs deploy/redis-agent-memory | grep -i 'FIPS security profile'
```

The chart also ships a Helm test (`helm test <release>`) and an offline
template test (`deployment/redis-agent-memory/tests/template-security-profile.sh`)
that exercise this contract; run the offline test in CI to catch
regressions before they reach a cluster.

### Running the chart test

The live `helm test` hooks (the test Pod and the Role / RoleBinding it
needs to read the Deployment) are gated behind `tests.enabled`, which
defaults to `false`. Clusters that never run `helm test` get no extra
RBAC. When you want to run the tests — for example as part of a customer
acceptance gate — enable them at install / upgrade time:

```sh
helm upgrade --install redis-agent-memory redis-ai/redis-agent-memory \
  --values ram-values.yaml \
  --set tests.enabled=true \
  --namespace <namespace-name> \
  --atomic --wait

helm test redis-agent-memory --namespace <namespace-name>
```

The RBAC is narrowly scoped: it grants only `get` on the two release
Deployments and lives only in the release namespace. The Role and RoleBinding
are regular release-managed resources gated by `tests.enabled` so
`helm test --logs` only collects logs from test Pods. They are removed when
you disable `tests.enabled` on a later upgrade or uninstall the release. Test
Pods are kept after a run so Helm can collect logs and are replaced before the
next test run. The offline template test covers both the
`tests.enabled=false` default (no test resources rendered) and the
`tests.enabled=true` opt-in (test Pod, Role, and RoleBinding all render).

## API Smoke Test

For a live post-installation check of the RAM data path, enable the optional
API smoke test in addition to `tests.enabled`:

```sh
helm upgrade --install redis-agent-memory redis-ai/redis-agent-memory \
  --values ram-values.yaml \
  --set tests.enabled=true \
  --set tests.smoke.enabled=true \
  --set tests.smoke.storeId=00000000000000000000000000000001 \
  --namespace <namespace-name> \
  --atomic --wait

helm test redis-agent-memory --namespace <namespace-name> --logs
```

`tests.smoke.storeId` must match one store ID from the mounted
`memory-dataplane.config.yaml`. The default matches the example config in this
README.

The smoke test calls the in-cluster RAM Service through the public on-prem API:

- `GET /health`
- `POST /v1/stores/{storeId}/session-memory/events`
- `POST /v1/stores/{storeId}/long-term-memory`
- `POST /v1/stores/{storeId}/long-term-memory/search`

It writes one short-term memory session event, writes one long-term memory
record with a unique keyword, searches for that record through the search
endpoint, and then best-effort deletes the records it created. This validates
the API server, content store Redis, RediSearch / Query Engine indexing, and the
configured embedding provider used by long-term memory creation and search.

Tune the smoke test image and retry behavior under `tests.smoke.*` if the
cluster uses an internal registry or needs longer indexing/search visibility
windows.

## Air-Gapped Deployments

For air-gapped deployments:

- mirror `redislabs/agent-memory:<ram-version>` into an internal registry
- create any required image pull Secret in the target namespace
- make sure `memory-dataplane.config.yaml` points only to endpoints reachable from inside the environment

Use the same `ram-values.yaml` approach as the standard install. Add these settings to
that file:

- `airgap.enabled: true`
- `image.repository: registry.example.com/redislabs/agent-memory`
- `image.tag: <ram-version>`
- `imagePullSecrets[0].name: regcred` if your registry requires an image pull Secret

Install with the same values file workflow:

```sh
helm install <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  --create-namespace \
  -f ram-values.yaml \
  --atomic \
  --wait
```

Upgrade with the same values file:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f ram-values.yaml \
  --atomic \
  --wait
```

If your registry does not require an image pull Secret, omit `imagePullSecrets`.

## Verify

```sh
kubectl get pods -n <namespace-name> -l app.kubernetes.io/name=redis-agent-memory
kubectl port-forward -n <namespace-name> svc/redis-agent-memory 9000:9000
curl http://localhost:9000/health/liveness
```

## Update

For every update:

- update the chart version and image tag as needed
- recalculate `LICENSE_CHECKSUM` if the license file changed
- recalculate `CONFIG_CHECKSUM` if the shared config file changed
- update `ram-values.yaml`

Then run:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f ram-values.yaml \
  --atomic \
  --wait
```

Typical update cases:

- new RAM version: change `image.tag`
- chart-only update: change `--version`
- license rotation: update the Secret and `license.existingSecretChecksum`
- config change: update the Secret and `config.existingSecretChecksum`

<!-- markdownlint-enable MD013 MD060 -->
