<!-- markdownlint-disable MD013 MD060 -->

# Redis Agent Memory On-Premises Deployment

This chart deploys Redis Agent Memory into a customer-managed Kubernetes cluster.
One release creates:

- `redis-agent-memory` API server
- `redis-agent-memory-worker` background worker
- `redis-agent-memory-controlplane` admin store API — **optional, disabled by default**
  (see [Control Plane (optional)](#control-plane-optional))

The server and worker use the same license Secret and the same shared application
config Secret. The optional control plane adds its own config Secret and an
admin-token Secret, and reuses the same license Secret.

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

# Optional configuration for stores that do not set
# metadata.stores[].summarization.
default_summarisation_config:
  enabled: false
  # Trigger summarisation by active session event count when enabled.
  trigger_strategy: event_count
  event_count:
    # Number of most recent session events to keep unsummarised.
    retain_count: 10
    # Active session event count that triggers summarisation when enabled.
    threshold: 20

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
      # Store-specific summarisation configuration
      summarization:
        enabled: false
        # Trigger summarisation by active session event count.
        trigger_strategy: event_count
        event_count:
          # Number of most recent session events to keep unsummarised.
          retain_count: 10
          # Active session event count that triggers summarisation when enabled.
          threshold: 20

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
    # Dynamic micro-batching for single-text embedding requests. Concurrent
    # single-text embeds sharing this provider are coalesced into fewer provider
    # calls, reducing request overhead under load. Enabled by default.
    batching:
      embeddings:
        # Coalesce concurrent single-text embeds into shared provider calls.
        enabled: true
        # Maximum number of inputs sent in one provider call.
        max_batch_size: 10
        # Maximum time a request waits to coalesce with others before sending.
        max_wait_time: 20ms
        # Number of background workers draining the batch queue.
        num_workers: 10
        # Maximum number of pending requests buffered before backpressure.
        queue_size: 1000

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

# Automatic session summarisation settings.
session_summarisation:
  # Service-level kill switch for summarisation. Override per-store configs.
  enabled: false
  # LLM configuration for the summarisation
  llm:
    # LLM provider used to summarise long sessions.
    provider: openai
    endpoint:
      # Base URL for summarisation LLM requests.
      base_url: https://api.openai.com/v1
      # Request timeout for summarisation calls.
      timeout: 30s
      # Header style used to send credentials.
      auth_format: bearer
    credentials:
      # Use static API key authentication for the summarisation LLM.
      type: static
      # API key used for summarisation requests.
      api_key: "<summarisation-llm-api-key>"
    models:
      # Chat model used to generate session summaries.
      default_chat_model: gpt-4o
    http_client:
      # Keep TLS verification enabled unless you deliberately use self-signed certs.
      skip_verify: false
      # Per-request timeout for summarisation calls.
      timeout: 30s
      # Retry count for transient summarisation LLM failures.
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
- `default_summarisation_config.*`: optional fallback summarisation configuration for stores that do not set it explicitly
- `metadata.stores[].summarization.*`: per-store summarisation configuration
- `embedders_connection_details`: embedding endpoint and credentials
- `session_summarisation.enabled`: service-level summarisation kill switch; Has precedence over store-level configuration.
- `session_summarisation.llm.*`: LLM endpoint, credentials, model, and HTTP client used by the summarisation worker
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

## Control Plane (optional)

The chart can optionally deploy the on-prem **Control Plane (CP)** — an admin API
(`/v1/stores`, admin-token authenticated) that creates and manages memory stores
at runtime, so you can provision stores without editing the data plane's config
and rolling its pods. It is **disabled by default** (`controlplane.enabled=false`);
a deployment that only serves memory from a static config never needs it.

When enabled, the chart adds a third workload, `redis-agent-memory-controlplane`
(Service on port `9100`), alongside the server and worker. The CP writes store
metadata to a **metadata Redis** and provisions each store's RediSearch indexes
in the **store database** at create time. It is paired with the data plane running
in **live store-resolution mode** (`metadata.source: live`), so the data plane
serves the stores the CP creates.

### Control plane Secrets

The CP needs two Secrets in addition to the license Secret it shares with the
server and worker:

- a **config Secret** with key `controlplane-onprem.config.yaml` (the CP config file)
- an **admin-token Secret** — either bring your own (`controlplane.adminToken.existingSecret`),
  or let the chart lookup-or-generate one on first install
  (`controlplane.adminToken.autoGenerate`, the default). A generated token is kept
  stable across upgrades and is never clobbered by a manual edit.

```sh
kubectl -n <namespace-name> create secret generic ram-controlplane-config \
  --from-file=controlplane-onprem.config.yaml=./controlplane-onprem.config.yaml
```

If you want to **bring your own admin token** (instead of letting the chart
generate one), create its Secret too and disable auto-generation in your values:

```sh
kubectl -n <namespace-name> create secret generic ram-controlplane-admin-token \
  --from-literal=token='<your-admin-token>'
```

```yaml
controlplane:
  adminToken:
    existingSecret: ram-controlplane-admin-token
    secretKey: token          # must match the --from-literal key above
    autoGenerate: false
```

The Secret key must equal `controlplane.adminToken.secretKey` (default `token`),
and it is always mounted at `/etc/controlplane-onprem/admin/token` — so the CP
config's `auth.admin_token.token_file` must point there. Rotate the token by
editing this Secret; the control plane reads it on use, so no redeploy is needed.

#### Sourcing these Secrets from the Secrets Store CSI Driver

If you provision the config / admin-token / license Secrets through the Secrets
Store CSI Driver, use its **sync-to-Kubernetes-Secret** feature
(`SecretProviderClass.secretObjects`) and point `controlplane.config.existingSecret`,
`controlplane.adminToken.existingSecret`, and `license.existingSecret` at the
synced Secret names — the chart consumes them like any other `existingSecret`.

One caveat: a CSI-synced Secret only exists while a pod that **mounts the CSI
volume** is running. So the control-plane pod must also mount the
`SecretProviderClass` volume. Use `controlplane.volumes` / `controlplane.volumeMounts`
for that:

```yaml
controlplane:
  volumes:
    - name: secrets-store
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: ram-controlplane-spc
  volumeMounts:
    - name: secrets-store
      mountPath: /mnt/secrets-store
      readOnly: true
```

(Direct CSI file mounts that bypass a Kubernetes Secret are not supported for the
config/admin-token/license paths — those are mounted from `existingSecret`.)

### Control plane config file

Use this as a starting point for `controlplane-onprem.config.yaml`:

```yaml
server:
  host: 0.0.0.0
  # The admin API listens on 9100.
  port: 9100
  read_timeout: 30s
  write_timeout: 35s
  timeout: 30s

# profile: prod (the default) requires the admin token to come from a mounted
# Secret file and rejects an inline token.
profile: prod

# Admin API authentication. The chart mounts the admin-token Secret at
# /etc/controlplane-onprem/admin/token; point token_file at it. The token is
# read on use, so rotating the Secret takes effect with no redeploy.
auth:
  type: admin-token
  admin_token:
    token_file: /etc/controlplane-onprem/admin/token

# Enterprise license — the chart mounts the same license Secret as the
# server/worker at {license.mountDir}/{license.fileName}.
license:
  license_path: /etc/redis-agent-memory/license

# Store-metadata Redis: where store records are persisted, under this key
# namespace. Must match the data plane's metadata.live.namespace.
metadata:
  urls:
    - redis://redis-meta:6379
  namespace: iris:memory

# Shared store database: the CP provisions a store's search indexes here at
# create time; the data plane serves from the same store.
store_db:
  urls:
    - redis://redis-store:6379

# Embedding vector size used to size the long-term-memory index at create time.
# Must match the data plane's embedding.models.dimensions.
embedding:
  dimensions: 3072
```

### Enable it

Add to your `ram-values.yaml`:

```yaml
controlplane:
  enabled: true
  image:
    repository: redislabs/agent-memory-control-plane
    tag: "<ram-version>"
  config:
    existingSecret: ram-controlplane-config
    existingSecretChecksum: "<controlplane-config-checksum>"
  # Auto-generate the admin token on first install (default). To bring your own,
  # set adminToken.existingSecret and adminToken.autoGenerate: false.
  adminToken:
    autoGenerate: true
```

Retrieve the auto-generated admin token (the exact command is also printed in the
`helm status` / `NOTES.txt` output):

```sh
kubectl -n <namespace-name> get secret \
  redis-agent-memory-controlplane-admin-token \
  -o jsonpath='{.data.token}' | base64 -d
```

Rotate it by editing that Secret — the CP reads the token on use, so no redeploy
is needed.

### Pair the data plane with the control plane

For the data plane to serve CP-created stores, switch its shared config file from
the static `metadata.stores` list to live mode:

```yaml
metadata:
  source: live
  live:
    urls:
      - redis://redis-meta:6379    # the same metadata Redis the CP writes to
    namespace: iris:memory          # must match the CP's metadata.namespace
    store_db:
      urls:
        - redis://redis-store:6379  # the shared store database
```

In live mode the store records the control plane writes are **metadata-only**
(TTLs / strategy / summarization) — they carry no embedding. The data plane
**completes** each resolved store from its own config, and the long-term-memory
embedding comes from **two separate blocks** that play different roles:

- **`embedding:`** — the embedding **selection**. Despite being typed as a general
  `llm.Config`, in live mode the data plane reads only three fields from it and
  stamps them onto every store: `provider`, `models.default_embedding_model`, and
  `models.dimensions`. **It is required in live mode — the data plane refuses to
  start without `default_embedding_model` and a non-zero `dimensions`.**
- **`embedders_connection_details:`** — the actual embedder **endpoint +
  credentials**, looked up by the `provider` name from the `embedding:` block.

```yaml
metadata:
  source: live
  live:
    urls:
      - redis://redis-meta:6379    # the same metadata Redis the CP writes to
    namespace: iris:memory          # must match the CP's metadata.namespace
    store_db:
      urls:
        - redis://redis-store:6379  # the shared store database

# embedding SELECTION (provider + model + dimensions); endpoint/creds are NOT read here
embedding:
  provider: openai                  # must match an embedders_connection_details key below
  models:
    default_embedding_model: nomic-embed-text
    dimensions: 768                 # see the dimensions rule below

# embedder ENDPOINT + credentials, keyed by the provider above
embedders_connection_details:
  openai:
    protocol: openai
    base_url: http://your-embedder:11434
    credentials:
      type: none
```

**Dimensions must agree in three places:** the control plane's
`embedding.dimensions` (it sized the RediSearch vector index at store creation),
the data plane's `embedding.models.dimensions` (stamped onto the store), and the
embedding model's real output width. A mismatch produces a wrongly-sized index or
runtime vector errors.

Default (`metadata.source` unset or `static`) behavior is unchanged — each store
carries its own `metadata.stores[].long_term_memory` and the top-level `embedding:`
block is unused — so existing DP-only installs are unaffected.

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
| Control plane | `controlplane.enabled`, `controlplane.image.*`, `controlplane.config.existingSecret`, `controlplane.adminToken.*` | enable the optional admin store API (see [Control Plane (optional)](#control-plane-optional)) |

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

- sets `MEM_SECURITY_PROFILE=fips` on the server and worker containers — and on
  the control-plane container when `controlplane.enabled=true`;
- surfaces the active profile in `helm status` / `NOTES.txt` output;
- triggers the image's entrypoint to set `GODEBUG=fips140=on` at process start.

When the posture is active the binary additionally refuses to start if the
mounted config:

- enables `skip_verify` on any outbound HTTP client (`dataplane_client.http_client`,
  `promote_session_memory.strategies.summary.llm.http_client`,
  `promote_session_memory.strategies.instruct.llm.http_client`,
  `session_summarisation.llm.http_client`, or `embedding.http_client`); or
- uses a non-`rediss://` URL for any Redis connection
  (`background_jobs.redis_streams.urls`, `metadata.stores[].urls`).

All violations are reported together at startup, so you never have to fix
them one restart at a time.

The control plane runs under the same posture (same entrypoint and
`GODEBUG=fips140` contract) and, when enabled, refuses to start if its own Redis
URLs (`metadata.urls`, `store_db.urls`) are not `rediss://`. The CP has no
outbound HTTP clients, so the `skip_verify` checks do not apply to it.

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
from the approved caller selector. It also includes a control-plane stanza that
allows traffic to the CP pods on port `9100` from approved admin clients only
(used when `controlplane.enabled=true`). Review it against your CNI implementation
and cluster ingress path before using it in production.

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

The chart also ships a Helm test (`helm test <release>`) and offline template
tests that exercise these contracts without a cluster; run them in CI to catch
regressions before they reach a cluster:

- `deployment/redis-agent-memory/tests/template-security-profile.sh` — the
  `security.profile` wiring and the `helm test` RBAC/hook gating.
- `deployment/redis-agent-memory/tests/template-controlplane.sh` — the optional
  control plane: off by default, and when enabled it renders the Deployment +
  Service on `9100` + admin-token Secret, honors bring-your-own-token, fails
  closed on missing inputs, and carries the FIPS profile.

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

If the control plane is enabled, verify it on port `9100`:

```sh
kubectl port-forward -n <namespace-name> svc/redis-agent-memory-controlplane 9100:9100
curl http://localhost:9100/v1/health/ready
# Admin endpoints require the token (HTTP 401 without it):
curl -H "Authorization: Bearer <admin-token>" http://localhost:9100/v1/stores
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

- new RAM version: change `image.tag` (and `controlplane.image.tag` if the control plane is enabled)
- chart-only update: change `--version`
- license rotation: update the Secret and `license.existingSecretChecksum`
- config change: update the Secret and `config.existingSecretChecksum` (or
  `controlplane.config.existingSecretChecksum` for the control-plane config)
- control-plane admin-token rotation: edit the admin-token Secret — read-on-use, no redeploy needed

<!-- markdownlint-enable MD013 MD060 -->
