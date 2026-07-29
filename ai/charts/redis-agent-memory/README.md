<!-- markdownlint-disable MD013 MD060 -->

# Redis Agent Memory On-Premises Deployment

This chart deploys Redis Agent Memory into a customer-managed Kubernetes cluster.
One release creates:

- `redis-agent-memory` API server
- `redis-agent-memory-worker` background worker
- `redis-agent-memory-controlplane` admin store API — **optional, disabled by default**
  (see [Control Plane (optional)](#control-plane-optional))

The server and worker use the same license Secret and the same application config
carrier (a chart-rendered ConfigMap, or a BYO Secret). The optional control plane
adds its own config carrier and an admin-token Secret, and reuses the same license
Secret.

A deployment is a server and worker serving a static set of stores. Start with
[Install](#install). Credentials (Redis connection URLs, embedder/LLM API keys)
never live in your values or the rendered ConfigMap — you supply them either
embedded in a BYO config Secret, or through one credentials Secret mounted as an
overlay (see [Supplying credentials](#supplying-credentials)). To serve more than
one region, see [Multi-Region Deployment](#multi-region-deployment).

## Before you install

- Kubernetes 1.23+
- Helm 3+
- Redis endpoints reachable from the cluster
- A license is required to use the on-prem version. Contact your Redis account representative. If you do not have one, contact Redis sales: <https://redis.io/meeting/>
- RAM image access from the cluster; see [Image access](#image-access)

Prerequisite matrix:

| Area | Requirement | Notes |
| --- | --- | --- |
| Kubernetes | Kubernetes 1.23+ and Helm 3+ | The chart installs standard `apps/v1` Deployments, Services, optional `autoscaling/v2` HPAs, optional Ingress, and pre-created Secrets. |
| Content store Redis | Redis 7.2.0 through 8.4.x with RedisJSON and RediSearch / Query Engine, reachable from the RAM server and worker pods | Configure content store endpoints in `metadata.stores.<id>.urls`. The content store holds session memory JSON documents and long-term memory hashes, so it must support JSON commands, hashes, TTLs, `FT.CREATE`, `FT.SEARCH`, JSON indexing, and vector `HNSW` fields. The long-term-memory index uses a `VECTOR` field named `text_vector` with `FLOAT64`, `HNSW`, and `COSINE`. When Redis Cloud databases are selected through the control plane, use an active Pro or Essentials database with a public endpoint, default user credentials, non-Active-Active deployment, and a RediSearch module reported as `search` or `searchlight`. |
| Job Redis | Redis 6.2+ reachable from RAM server and worker pods | Configure `background_jobs.redis.urls` to the regional job Redis endpoint, use a non-volatile / `noeviction` policy, and keep exactly one async backend enabled per process. The job Redis does not need RediSearch or RedisJSON unless the same Redis also serves as the content store. |
| Architecture support | Treat RAM on-prem images as `linux/amd64` unless the release notes for your image version explicitly declare a multi-arch manifest | For ARM64 nodes, use a compatible image or schedule RAM pods onto AMD64 nodes. |

Recommended deployment model:

- run one Redis Agent Memory release per namespace
- keep the default in-cluster server address `http://redis-agent-memory:9000`
- if you override `fullnameOverride` or run multiple releases in one namespace, update `dataplane_client.base_url` in the config to match
- if you run more than one region (advanced), render one config per logical region so the server and worker receive the same
  `request_region`, `background_jobs.redis.urls`, `queue_prefix`, and queue ownership settings — see [Multi-Region Deployment](#multi-region-deployment)

The chart requires:

- `license.existingSecret`
- an application config, provided through your Helm values with
  `config.render: true` (see [Install](#install))
- `image.tag`

## Image Access

The published Helm chart is `redis-ai/redis-agent-memory` from
`https://helm.redis.io/ai`. Standard installs use the public Docker Hub
images published by the RAM on-prem release:

```yaml
image:
  repository: redislabs/agent-memory
  tag: "<ram-version>"

controlplane:
  image:
    repository: redislabs/agent-memory-control-plane
    tag: "<ram-version>"

imagePullSecrets: []
```

`imagePullSecrets` is normally not needed for the standard public Docker Hub
path. Configure it only when the cluster uses explicit registry credentials, or
when the images are mirrored to a private/authenticated registry.

For authenticated registries, create an image pull Secret in the target
namespace and reference it with `imagePullSecrets`:

```sh
kubectl -n <namespace-name> create secret docker-registry ram-registry \
  --docker-server=<registry-host> \
  --docker-username=<username> \
  --docker-password=<password>
```

```yaml
imagePullSecrets:
  - name: ram-registry
```

For mirrored images, override `image.repository` and, when the Control Plane is
enabled, `controlplane.image.repository`. Use the image tag supplied for the RAM
release; do not use the source Git tag format as the Docker image tag.

## Required Secrets

Create the license Secret:

```sh
kubectl create namespace <namespace-name>

kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license
```

If your Secret key uses a different name, set `license.secretKey` in your Helm
values.

Redis and embedding-provider credentials are supplied via mounted secret
overlays, covered in [Install](#install).

## Install

**Quick start** — the happy path in three steps:

1. Create the license Secret and one credentials Secret (both detailed below).
2. Copy [`examples/basic/values.yaml`](examples/basic/values.yaml) and set
   `image.tag`, `license.existingSecret`, and `secrets.secretName`.
3. `helm install <release> redis-ai/redis-agent-memory -f values.yaml -n <namespace> --create-namespace`

Each step is explained below; the full config field set is in
[Config Reference](#config-reference).

A deployment is one server and one worker serving a static set of stores. You
configure Redis Agent Memory through your Helm values, using one of two credential
paths:

- **(a) Chart-rendered config + one credentials Secret** (recommended) — the chart
  renders your values into a structure-only **ConfigMap**, and you supply the
  credentials in one Secret mounted as an overlay. See
  [Supplying credentials](#supplying-credentials) and
  [Configuring and installing](#configuring-and-installing) below.
- **(b) BYO full config Secret** — you bring a pre-created Secret holding the
  complete on-prem config file with credentials embedded directly in the Redis
  URLs. No overlay is needed. See
  [Bring your own config Secret](#bring-your-own-config-secret).

A ready-to-copy values file lives in
[`examples/basic/values.yaml`](examples/basic/values.yaml). To serve more than one
region, see [Multi-Region Deployment](#multi-region-deployment).

### Supplying credentials

With the chart-rendered config path (`config.render: true`), the chart renders your
`memory:` values into a **ConfigMap** the server and worker read, and rolls the
pods automatically whenever that config changes. The rendered ConfigMap is
structure only — it holds no Redis connection URLs and no API keys.

Credentials live inside the config's own snake_case paths — API keys under
`embedders_connection_details.*` and full Redis connection strings
(`redis://user:pass@host:port`) under `metadata.stores.<id>.urls`,
`background_jobs.redis.urls`, etc. Rather than putting these in your values, you
place them in one pre-created Secret holding a small YAML **overlay** that the
config loader deep-merges over the base config at runtime:

- **`secrets.secretName`** — the primary credentials overlay. This one Secret
  usually holds everything: the API keys **and** the Redis connection strings.
- **`secrets.additionalSecrets`** — optional ordered list of extra Secrets layered
  on top of `secretName` (later wins the merge). Use it to split credentials across
  Secrets (for example, per region); leave empty otherwise.

The Secret holds one YAML overlay file (default key `overlay.yaml`). Create it from
a plaintext overlay file (its keys mirror the config's own snake_case paths):

```sh
# overlay.yaml:
#   embedders_connection_details:
#     openai: { credentials: { api_key: sk-... } }
#   metadata:
#     stores:
#       "0000...0001": { urls: [redis://user:pass@redis-store:6379] }
#   background_jobs:
#     redis: { urls: [redis://user:pass@redis-jobs:6379] }
kubectl -n <namespace-name> create secret generic ram-secrets \
  --from-file=overlay.yaml=./overlay.yaml
```

Reference the Secret **name** from values:

```yaml
secrets:
  secretName: ram-secrets
```

The chart mounts each overlay read-only at `/etc/ai/overlays/<i>/overlay.yaml`,
0-based in merge order (`secretName` first, then each `additionalSecrets` entry),
and appends one repeatable `--config <path>` arg per overlay in that order (after
the base `--config`) to the container args of the server, worker, and control
plane. With just `secretName` set, that is a single overlay at
`/etc/ai/overlays/0/overlay.yaml`. The loader deep-merges the overlays over the
base config in order (later wins), so the connection string stays whole — you keep
structure in the ConfigMap and the full credentialed URL in the overlay. Rotating
an overlay takes effect on pod restart.

### Configuring and installing

Create a checksum for the license Secret so the pod rolls automatically when the
license file changes:

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
```

Create a values file, e.g., `ram-values.yaml`, with `config.render: true`, one
`secrets.secretName`, and the config fields from
[Config Reference](#config-reference) under `memory:`:

```yaml
license:
  existingSecret: ram-license
  existingSecretChecksum: "<license-checksum>"

config:
  render: true

# One credentials Secret holds the API keys and Redis connection URLs.
secrets:
  secretName: ram-secrets

# See Config Reference for the full field set. Credentials are omitted here —
# the API keys and Redis connection URLs arrive via the mounted overlay above.
# metadata.stores is a MAP keyed by store id; the store's urls come from the
# overlay, merged into the same id at runtime.
memory:
  default_extraction_strategy: instruct
  auth:
    method: none
  background_jobs:
    redis:
      enabled: true            # urls arrive via the overlay
      queue_prefix: ram
      worker_regions: [default]
  request_region:
    default: default
  metadata:
    source: static
    stores:
      "00000000000000000000000000000001":
        short_memory: { ttl_seconds: 86400 }
        long_term_memory:
          embedding_provider: openai
          embedding_model: text-embedding-3-large
          embedding_dimensions: 3072
  embedders_connection_details:
    openai:
      base_url: https://api.openai.com
      credentials: { type: static }   # api_key arrives via the overlay

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

Running more than one region? [Multi-Region Deployment](#multi-region-deployment)
uses this same mechanism, split into a shared base file and a small per-region
file, with each region naming its own credentials Secret via `secrets.secretName`.

### Bring your own config Secret

If you manage the config file outside Helm — for example, it is generated by
Vault or Terraform — you can supply it as a pre-created Secret rather than
rendering it from values. This is the simplest path: with
credentials embedded directly in the Redis URLs inside that file, **no secret
overlay is needed** and the chart adds no overlay `--config` args. Set
`config.existingSecret` and leave `config.render` off; the two cannot be combined,
and the chart fails at install time if both are set.

Build the config file from the [Config Reference](#config-reference) fields and
create the Secret:

```sh
kubectl -n <namespace-name> create secret generic ram-config \
  --from-file=memory-dataplane.config.yaml=./memory-dataplane.config.yaml
```

If your Secret key uses a different name, set `config.secretKey`. Compute a
checksum for both Secrets so pods roll when either file changes:

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
CONFIG_CHECKSUM="$(shasum ./memory-dataplane.config.yaml | awk '{print $1}')"
```

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

If you prefer to keep credentials out of the BYO config file, the mounted secret
overlays (`secrets.secretName` / `secrets.additionalSecrets`) still apply — they
are merged over the BYO config too. Install the chart the same way as above, with
this values file.

## Config Reference

This is the application config the server and worker read, in snake_case. You
provide these fields under `memory:` in your Helm values, and the chart renders
them into a ConfigMap at install time (see [Install](#install)). Credentials
(Redis connection URLs, API keys) are NOT part of these fields — they arrive via
the mounted secret overlays.

The example below uses the Redis-backed async job queue configured under
`background_jobs.redis`.

Global queue concepts are the fixed job slugs, default retries/timeouts, and
observability fields. Regional queue concepts are `request_region`,
`queue_prefix`, and `worker_regions`. In steady state, a deployment writes only
its own logical region's queues. Failover is a config change that adds the
failed logical region to another deployment's `worker_regions`; dual live
ownership of one logical region is unsupported.

Use this as a starting point for the `memory:` block in your Helm values:

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

# This static-mode example disables RAM-layer DP auth.
auth:
  method: none

# Optional configuration for stores that do not set
# metadata.stores.<id>.summarization.
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

# Request-region resolution for regional async queue submission.
request_region:
  # Default logical region used when no configured header rule matches.
  default: eu1
  # Headers evaluated in order to resolve the request's logical region.
  headers:
    - X-RAM-Origin-Region
    - X-Forwarded-Host
    - Host
  # Optional regex rules. First match wins; no match falls back to default.
  rules:
    - pattern: '^memory-eu[.-].*'
      region: eu1
    - pattern: '^memory-us[.-].*'
      region: us1

# Background job execution backend.
background_jobs:
  # Regional Redis queue backend for on-prem deployments.
  redis:
    enabled: true
    # Redis endpoint(s) used for the regional job queues. For Active-Active
    # deployments, use the region-local endpoint and keep steady-state writes
    # region-affine.
    urls:
      - redis://redis-jobs-aa:6379
    # Queue names are <queue_prefix>:<region>:<job_slug>.
    queue_prefix: ram
    # Logical regions this worker deployment is allowed to process.
    # Required by --mode=worker; --mode=server ignores it (and logs an INFO
    # when it is present), so the same file can feed both processes.
    worker_regions:
      - eu1
    defaults:
      concurrency: 4
      max_retry: 3
      timeout: 10m
      completed_retention: 1h
      requeue_without_retry_delay: 5s
      shutdown_timeout: 30s
    jobs:
      promote-instruct:
        concurrency: 2
        timeout: 30m
      summarize-session:
        concurrency: 4
        timeout: 10m
      session-summary-view:
        concurrency: 4
        timeout: 10m
  # Execution idempotency prevents a redelivered successful job from running again.
  idempotency:
    # Enable for production async workers.
    enabled: true
    # Redis endpoint(s) used for done markers and ownership locks.
    urls:
      # This can share the job Redis or use a dedicated Redis with the same regional ownership model.
      - redis://redis-jobs-aa:6379
    # Retention window for successful job done markers.
    done_ttl: 24h
    # Ownership lock TTL for in-flight job execution.
    lock_ttl: 5m
    # How often workers extend owned locks while executing a job.
    lease_extension_interval: 1m
    # Timeout for idempotency Redis operations.
    operation_timeout: 5s

# Memory store definitions exposed by the API. `stores` is a MAP keyed by store
# id (NOT a list), so Helm and the config loader deep-merge per id.
metadata:
  source: static
  stores:
    # Stable store identifier used in API paths and job payloads (the map key).
    "00000000000000000000000000000001":
      # Redis endpoint(s) that store short-term and long-term memory. In a
      # chart-rendered deployment the urls (with credentials) come from the
      # regional secret overlay, merged into this same id at runtime — leave
      # them out of the ConfigMap body. Shown here for a BYO/all-in-one file.
      urls:
        - redis://user:pass@redis-store:6379
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
  # Provider name referenced by metadata.stores.<id>.long_term_memory.embedding_provider.
  openai:
    # Base URL for embedding requests.
    base_url: https://api.openai.com
    credentials:
      # Use static API key authentication for the embedding provider.
      type: static
      # API key presented to the embedding provider. In a chart-rendered
      # deployment this arrives via the shared secret overlay, not the ConfigMap.
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
    # To authenticate worker callbacks with a Kubernetes projected service
    # account token, set workerAuth.enabled=true in Helm values, then set
    # disabled: false, type: service_account_token, and token_file to the
    # projected token path mounted by the chart.
    # type: service_account_token
    # token_file: /var/run/secrets/redis-agent-memory-worker/token
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

- `request_region.*`: request-origin region resolution for regional queue submission
- `background_jobs.redis.urls`: regional Redis queue backend used for async work
- `background_jobs.redis.queue_prefix`: queue namespace prefix; queue names are `<queue_prefix>:<region>:<job_slug>`
- `background_jobs.redis.worker_regions`: logical regions this worker deployment processes; required in `--mode=worker`, ignored (with an INFO log) in `--mode=server`
- `metadata.stores.<id>.urls`: Redis databases that hold short-term and long-term memory
- `metadata.stores.<id>.short_memory.ttl_seconds`: short-term memory retention
- `metadata.stores.<id>.long_term_memory.*`: embedding provider, model, and vector size
- `default_summarisation_config.*`: optional fallback summarisation configuration for stores that do not set it explicitly
- `metadata.stores.<id>.summarization.*`: per-store summarisation configuration
- `embedders_connection_details`: embedding endpoint and credentials
- `session_summarisation.enabled`: service-level summarisation kill switch; Has precedence over store-level configuration.
- `session_summarisation.llm.*`: LLM endpoint, credentials, model, and HTTP client used by the summarisation worker
- `promote_session_memory.strategies.<summary|instruct>.llm.*`: promotion LLM endpoint, auth, and model
- `promote_session_memory.strategies.*.promotion_deduplication_window`: optional per-strategy window for batching rapid session writes into one promotion job; defaults to `5m`; set to `0s` for immediate promotion
- `client_pool.max_size`: connection pool size for higher concurrency
- `dataplane_client.base_url`: worker to server callback URL

## Multi-Region Deployment

> **Advanced.** This section builds on the basic [Install](#install). If you run a
> single region, you do not need anything here.

To serve multiple regions, deploy one release per region and layer two things on
top of the basic setup:

1. **Split** the values into a shared **base** file (identical across regions) and
   a tiny **per-region** override file, deep-merged by Helm at install time — so
   you don't hand-maintain a full config file per region.
2. Each region names its **own credentials Secret** via `secrets.secretName` (the
   same field the basic install uses), holding that region's API keys **and** Redis
   connection strings in one overlay.

The non-secret structure is composed by Helm into a ConfigMap; the credentials
come from that one per-region secret overlay, merged by the loader at runtime.
Shared API keys are duplicated into each region's Secret — with so few of them
that's simpler than a separate shared Secret, but if you'd rather share them,
`secrets.additionalSecrets` can layer an extra Secret on top of `secretName`. See
[Supplying credentials](#supplying-credentials) for the overlay mechanics.

Deploy one Helm release per region (each on that region's cluster), pointing at
its local Active-Active endpoint:

```sh
helm install ram-eu redis-ai/redis-agent-memory \
  -f base-values.yaml -f region-eu.yaml --set image.tag=<RAM_VERSION>

helm install ram-us redis-ai/redis-agent-memory \
  -f base-values.yaml -f region-us.yaml --set image.tag=<RAM_VERSION>
```

The base file carries no secret; each region names its own credentials Secret:

```yaml
# base-values.yaml — no secrets block (structure only)

# region-eu.yaml
secrets:
  secretName: ram-eu-secrets   # this region's API keys + Redis connection strings

# region-us.yaml
secrets:
  secretName: ram-us-secrets
```

The chart mounts that one overlay at `/etc/ai/overlays/0/overlay.yaml` and appends
it as a `--config` arg after the base config, exactly as in the basic install.

Ready-to-copy examples live in [`examples/multi-region/`](examples/multi-region/):
`base-values.yaml`, `region-eu.yaml` / `region-us.yaml`, and the plaintext
overlay contents (`region-<x>.secret-overlay.example.yaml`) to load into each
region's pre-created Secret.

### How the base + region split works

- **Base + region merge** — Helm deep-merges `-f base-values.yaml -f region-<x>.yaml`
  before rendering, so the region file only carries the non-secret deltas:
  `request_region.default`, `worker_regions`, `secrets.secretName`, and the
  ingress host. The Redis endpoints are NOT here — they live in the regional secret
  overlay.
- **`shared`** — structural config common to the data plane and control plane
  (embedder structure, store metadata structure, endpoints) is defined once and
  deep-merged under both `memory` and `controlplane.configData`.
- **Secret overlay** — each region's `secrets.secretName` Secret holds that
  region's API keys **and** Redis connection strings in one overlay, mounted into
  all of that region's services and merged by the loader over the rendered config.
  See [Supplying credentials](#supplying-credentials).

> **Queue backend:** multi-region Active-Active deployments use the regional
> `background_jobs.redis` backend, with each region owning its queues via
> `worker_regions` and `request_region.default`. The examples use
> `background_jobs.redis`.

> **`metadata.stores` is a map keyed by store id.** Its structural fields
> (`short_memory`, `long_term_memory`, ...) live in the base config ConfigMap
> under the store id; the store's `urls` (with credentials) live in the regional
> secret overlay under the *same* id. The loader deep-merges maps per id, so the
> connection string joins the structure at runtime without repeating anything.
> The `urls` list is provided whole by the overlay, which is correct for a single
> per-region Active-Active endpoint.

Each region can also supply its own config Secret
([`config.existingSecret`](#bring-your-own-config-secret)) instead of
rendering from values.

### Regional failover

Failover is a config-only change in the surviving region's deployment: add the
failed logical region to `worker_regions` and roll the worker. Request routing
(`request_region`) stays untouched, so jobs keep landing in their origin
region's queues; the surviving workers simply drain both regions. Revert the
list to fail back.

```yaml
background_jobs:
  redis:
    enabled: true
    urls:
      - redis://redis-jobs-aa:6379
    queue_prefix: ram
    worker_regions:
      - eu1
      - us1 # temporary failover coverage for the failed region
```

Dual live ownership of one logical region is unsupported: exactly one worker
deployment may list a given region at a time.

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
the static `metadata.stores` list to live mode and use the matching auth mode.
The data plane config is supplied as an external Secret, so it does not know
whether the Helm release has `controlplane.enabled=true`. CP-managed live
deployments use `auth.method: agent_key`, or rely on the live-mode default when
`auth.method` is omitted unless the shared config explicitly keeps worker
callback auth disabled:

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
carries its own `metadata.stores.<id>.long_term_memory` and the top-level `embedding:`
block is unused — so existing DP-only installs are unaffected.

## Queue Monitor (optional)

The chart can optionally deploy **Asynqmon** for low-frequency inspection of the
RAM async queues backed by `background_jobs.redis`. It is disabled by default
(`controlplane.queueMonitor.enabled=false`) and is specific to the supported
Redis queue backend.

When enabled, the chart adds a separate low-resource Deployment,
`redis-agent-memory-asynqmon`, plus a ClusterIP Service. If
`controlplane.queueMonitor.ingress.enabled=true`, it also renders a dedicated
host Ingress, for example `ram-jobs.example.com`, protected by ingress Basic
Auth. The chart does not generate or transform Secrets for this monitor.

### Queue monitor Secrets

Create a Redis connection Secret that points at the same Redis endpoint used by
`background_jobs.redis.urls`:

```sh
kubectl -n <namespace-name> create secret generic ram-job-redis \
  --from-literal=REDIS_URL='rediss://:<password>@<job-redis-host>:6379/0' \
  --from-literal=REDIS_TLS='<job-redis-host>'
```

Use `redis://` only when your environment does not require TLS. The optional
`REDIS_TLS` key sets the TLS server name. If your environment intentionally
skips hostname verification, provide `REDIS_INSECURE_TLS=true` as a third key
and document that exception in your deployment record.

Do not include a Redis ACL username in `REDIS_URL` when using the default
`hibiken/asynqmon:0.7.2` image. Upstream Asynqmon accepts password-only Redis
URLs and does not expose a username flag, so named-user ACL deployments must
either provide a monitor credential on Redis' default user or set
`controlplane.queueMonitor.image.repository` to a compatible wrapper image.

Create the Basic Auth Secret separately. Ingress-nginx expects htpasswd content
under the key `auth`. Use the same password value as the control-plane admin
token, but store it in this separate htpasswd-formatted Secret consumed by the
ingress controller:

```sh
read -rs RAM_ADMIN_PASSWORD
printf '\n'
htpasswd -Bbn admin "$RAM_ADMIN_PASSWORD" > asynqmon.htpasswd
kubectl -n <namespace-name> create secret generic redis-agent-memory-asynqmon-basic-auth \
  --from-file=auth=./asynqmon.htpasswd
rm asynqmon.htpasswd
unset RAM_ADMIN_PASSWORD
```

Do not point `controlplane.queueMonitor.auth.existingSecret` at the
control-plane admin-token Secret. Ingress controllers expect htpasswd content,
not the raw token value, and Helm intentionally does not read the admin-token
Secret to generate htpasswd data.

### Enable it

Add to your `ram-values.yaml`:

```yaml
controlplane:
  queueMonitor:
    enabled: true
    readOnly: true
    image:
      repository: hibiken/asynqmon
      tag: 0.7.2
    redis:
      existingSecret: ram-job-redis
      urlKey: REDIS_URL
      tlsServerNameKey: REDIS_TLS
      insecureTLSKey: REDIS_INSECURE_TLS
    auth:
      type: basic
      existingSecret: redis-agent-memory-asynqmon-basic-auth
      secretKey: auth
    ingress:
      enabled: true
      className: nginx
      host: ram-jobs.example.com
      tls:
        secretName: ram-jobs-tls
```

The rendered ingress uses the ingress-nginx Basic Auth annotations
`auth-type=basic`, `auth-secret=<existingSecret>`, and
`auth-secret-type=auth-file`. If your cluster cannot use ingress Basic Auth,
leave the monitor ingress disabled and put your own auth proxy or service-mesh
policy in front of the Asynqmon Service.

### Security posture

- The monitor is opt-in and runs as an isolated Deployment, not inside the RAM
  worker.
- It is read-only by default (`READ_ONLY=true`), so Asynqmon hides and rejects
  mutating actions.
- If you set `readOnly=false`, Asynqmon can mutate queues and tasks; Basic Auth
  is then the only chart-managed access control.
- The default Service is ClusterIP. Public access should go through the
  dedicated admin host ingress or an operator-managed auth proxy.
- The default image is the latest upstream Asynqmon image tag available during
  this change (`0.7.2`, corresponding to Git tag `v0.7.2`). Keep the image tag
  pinned and validate it when changing the repository's Asynq version; use a
  pinned wrapper image if upstream compatibility diverges.
- The upstream image publishes amd64 manifests. Use
  `controlplane.queueMonitor.image.repository` for a mirrored or multi-arch image
  if your cluster needs another architecture.

### Local Docker Compose

The local RAM on-prem compose stack includes Asynqmon in read-only mode against
the same Redis queue backend:

```sh
task memory:run:onprem -- -d
open http://127.0.0.1:9080
curl http://127.0.0.1:9080/api/queues
```

Local development intentionally skips Basic Auth because the port is bound to
`127.0.0.1` only. Do not expose this compose port on shared hosts.

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
| Worker service identity | `workerAuth.enabled`, `worker.serviceAccount.*` | projected service-account token auth for worker callbacks |
| Scheduling | `server.nodeSelector`, `worker.nodeSelector`, `server.affinity`, `worker.affinity`, `server.tolerations`, `worker.tolerations` | placement control in larger clusters |
| Networking | `service.type`, `ingress.*` | expose the API outside the cluster |
| Naming | `fullnameOverride` | multiple RAM releases in one namespace |
| Service account | `serviceAccount.*` | custom namespace security policy |
| Secret rollouts | `license.existingSecretChecksum`, `config.existingSecretChecksum` | force restart after external Secret updates |
| Control plane | `controlplane.enabled`, `controlplane.image.*`, `controlplane.config.existingSecret`, `controlplane.adminToken.*` | enable the optional admin store API (see [Control Plane (optional)](#control-plane-optional)) |
| Queue monitor | `controlplane.queueMonitor.*` | enable the optional Asynqmon UI for `background_jobs.redis` |
| Support package | `supportPackage.enabled`, `supportPackage.logLimits.*`, `supportPackage.healthChecks.*`, `supportPackage.healthCheckImage.*`, `supportPackage.healthCheckImagePullSecretName`, `supportPackage.healthCheckPodTimeout`, `supportPackage.registryImages.*`, `supportPackage.nodeMetrics` | render RAM Troubleshoot support-bundle/redactor specs and default diagnostics |
| Preflight | `preflight.enabled` | render the static RAM Kubernetes preflight spec as a ConfigMap; the same spec is packaged under `support/` for pre-install checks |

Do not use floating image tags in production.

## FIPS-Oriented Posture

Redis Agent Memory ships an opt-in FIPS-oriented posture for regulated on-prem
environments. It is designed to match the expectations most "FIPS mode"
deployments have, without overclaiming the formal compliance status of the
cryptographic module used.

### Compliance scope

- The on-prem image uses Go's native FIPS cryptographic module, linked at build
  time with `GOFIPS140=v1.0.0`. When the posture is
  enabled, the binary runs with `GODEBUG=fips140=on`, which restricts TLS
  negotiation and key generation to the algorithms the FIPS module implements.
- **This chart does not claim formal FIPS 140 compliance or validation.** At the time
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
  (`background_jobs.redis.urls`, `metadata.stores.<id>.urls`).

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

### Worker service-account authentication

The worker can authenticate its callback requests to the RAM API with a
Kubernetes projected service-account token. Set `workerAuth.enabled=true` in
Helm values; by default the chart creates a dedicated
`redis-agent-memory-worker` ServiceAccount, mounts a projected token at
`/var/run/secrets/redis-agent-memory-worker/token`, uses the
`redis-agent-memory` audience, and gives the worker the subject
`system:serviceaccount:<namespace>:redis-agent-memory-worker`. Customize those
defaults with `worker.serviceAccount.name`, `worker.serviceAccount.create`,
`worker.serviceAccount.annotations`, and
`worker.serviceAccount.token.{audience,expirationSeconds,mountPath,fileName}`.
In `memory-dataplane.config.yaml`, set
`dataplane_client.auth.disabled=false`,
`dataplane_client.auth.type=service_account_token`, and
`dataplane_client.auth.token_file` to the mounted token path; also enable
`auth.worker_identity` with the Kubernetes service-account `issuer`,
`jwks_uri`, matching `audience`, and a `subjects` entry for the worker subject
with the required store grants. For the initial single-account MVP, grant the
worker `write` on `mem-store:*`; for stricter isolation, replace that wildcard
with narrower store resources or use separate worker ServiceAccounts. The
worker token proves the pod identity, and RAM still authorizes every request
through the normal Principal role and store-grant checks.

### Hosting access requirement

On-prem Agent Memory can enforce Data Plane access with RAM agent keys when
live metadata and `auth.method: agent_key` are configured. If Data Plane
authentication is disabled, access control for the API **must** be enforced by
your hosting environment. Do not expose an auth-disabled Data Plane to untrusted
callers; any caller that can reach it can use the configured stores. Typical
hosting controls include:

- a Kubernetes `NetworkPolicy` that restricts ingress to the pod,
- an ingress controller or service mesh that authenticates callers, and
- network boundaries (VPC, private subnets, VPN / zero-trust agent) that
  prevent arbitrary workloads from reaching the service.

For worker-enabled deployments with Data Plane auth enabled, configure worker
identity. Set `workerAuth.enabled=true` to mount a projected Kubernetes
service-account token into the worker pod, then configure
`dataplane_client.auth.type=service_account_token` and `auth.worker_identity` in
`memory-dataplane.config.yaml`. The Helm ServiceAccount settings only provide
the Kubernetes credential; RAM access is granted by
`auth.worker_identity.subjects` with store resources such as
`mem-store:<store-id>` or, for the initial single-account MVP, `mem-store:*`.

The binary logs a one-time banner on startup (at `WARN` level) when
`security.profile=fips` is set. The banner is a
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

The supported launch path is the image's entrypoint. If you bypass the
entrypoint (for example by running `/server` directly inside the image, or by
overriding `command:` in a custom manifest), the runtime
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

### Running the chart test

The live `helm test` hooks (the test Pod and the Role / RoleBinding it
needs to read the Deployment) are gated behind `tests.enabled`, which
defaults to `false`. Clusters that never run `helm test` get no extra
RBAC. When you want to run the tests as part of an acceptance gate, enable them
at install / upgrade time:

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
next test run.

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
endpoint, and then best-effort deletes the records it created plus any promoted
smoke records already visible by `sessionId` and `ownerId`. This validates
the API server, content store Redis, RediSearch / Query Engine indexing, and the
configured embedding provider used by long-term memory creation and search.

To also validate the asynchronous worker promotion path, enable the nested
async-promotion smoke setting:

```sh
helm upgrade --install redis-agent-memory redis-ai/redis-agent-memory \
  --values ram-values.yaml \
  --set tests.enabled=true \
  --set tests.smoke.enabled=true \
  --set tests.smoke.asyncPromotion.enabled=true \
  --namespace <namespace-name> \
  --atomic --wait

helm test redis-agent-memory --namespace <namespace-name> --logs
```

Use `tests.smoke.asyncPromotion.enabled=true` during install, upgrade, or
rehearsal validation when you need release evidence that the worker, job Redis,
promotion LLM configuration, and long-term-memory write path are all processing
session writes. Leave it disabled for a faster API-only smoke check, or when the
validation environment intentionally lacks worker/job/LLM connectivity.

The async-promotion path writes a session event phrased as durable information,
polls long-term memory search until an `episodic` memory with the smoke
`sessionId` and `ownerId` appears, then includes any promoted memory IDs in the
best-effort cleanup. Tune `tests.smoke.asyncPromotion.promotionRetries` and
`tests.smoke.asyncPromotion.promotionRetryIntervalSeconds` when worker queues or
LLM calls need more time. The chart defaults cover RAM's default `5m`
`promotion_deduplication_window`; if your deployment sets immediate or shorter
promotion windows, you can lower these retry values and
`tests.smoke.activeDeadlineSeconds` in validation-specific values.

Tune the smoke test image and retry behavior under `tests.smoke.*` if the
cluster uses an internal registry or needs longer indexing/search visibility
windows.

## Preflight Checks and Support Bundles

The Helm chart contains the RAM preflight, support-bundle, and redactor specs.
You do not need a separate diagnostics package.

Both workflows are customer-admin initiated from Kubernetes tooling. You need
`helm`, `kubectl`, and the Troubleshoot kubectl plugins.
If `kubectl krew` is not available, install Krew first:
<https://krew.sigs.k8s.io/docs/user-guide/setup/install/>.

Install the Replicated Troubleshoot plugins on the machine where you run the
checks:

```sh
kubectl krew install preflight
kubectl krew install support-bundle
```

Verify that both commands are available:

```sh
kubectl preflight --help >/dev/null
kubectl support-bundle --help >/dev/null
```

For air-gapped environments, install the `preflight` and `support-bundle`
binaries from your approved internal mirror instead of Krew.

Run the packaged Kubernetes preflight before install or upgrade:

```sh
helm repo add redis-ai https://helm.redis.io/ai
helm repo update

helm pull redis-ai/redis-agent-memory \
  --version <chart-version> \
  --untar \
  --untardir ./ram-chart

kubectl preflight ./ram-chart/redis-agent-memory/support/ram-preflight.yaml
```

The preflight is intentionally not values-aware. It checks Kubernetes readiness:
version, required API groups, default CPU and memory capacity, and node spread.
It does not check namespaces, Secrets, image registries, Ingress, Redis
connectivity, or your selected Helm values.

The chart also renders this static preflight as a ConfigMap when
`preflight.enabled=true`, but the preflight CLI does not discover in-cluster
specs. Use the packaged `support/ram-preflight.yaml` file for pre-install and
upgrade checks.

Generate a support bundle from the release namespace:

```sh
kubectl support-bundle \
  --namespace <namespace-name> \
  --load-cluster-specs \
  -l troubleshoot.sh/kind=support-bundle \
  --metadata supportCase=<case-id> \
  --metadata incident=<incident-id> \
  --metadata release=<release-name> \
  --metadata region=<logical-region>
```

Support bundles are generated locally with your kubeconfig. No archive is
uploaded unless you share the generated `.tar.gz`. The support-bundle and
redactor specs are installed by default with the Helm release.

Run support-bundle collection from an admin `kubectl` context that can read the
RAM release namespace. The chart does not create support-bundle RBAC.

The default spec collects namespace-scoped Kubernetes resources, Helm release
metadata without Helm values, exact-key config and overlay Secret/ConfigMap
values, key-existence checks for non-config Secrets, HTTP health checks,
registry image validation, node metrics, bounded RAM server/worker logs,
optional control-plane logs when `controlplane.enabled=true`, a static manifest,
and Troubleshoot analyzer results. Built-in Troubleshoot redactors and
RAM-specific redactors run against the archive. It intentionally does not
collect Helm values, license contents, admin tokens, Redis keys or values, raw
Redis `INFO`, or business API calls.

The default spec also renders exact-key config value collection, in-cluster HTTP
health checks, registry image validation, Kubernetes node metrics collection,
Kubernetes node resource analyzers, and native Troubleshoot analyzers:

```yaml
supportPackage:
  registryImages:
    imagePullSecretName: regcred
```

`supportPackage.healthChecks.enabled=true` is the default and runs temporary
in-cluster `runPod` probes for server, worker, optional Control Plane, and
optional queue monitor health endpoints. Each probe executes the Troubleshoot
HTTP collector against `*.svc.cluster.local` and analyzes the pod log for HTTP
200. Worker checks use a support-only ClusterIP Service named
`<release>-worker-support`.

Redis dependency failures are covered by the service health probes and bounded
RAM logs. The support package does not run separate Redis client probes, and it
does not collect Redis keys, values, raw `INFO`, memory contents, prompts, or
provider payloads.

`supportPackage.registryImages.enabled=true` is the default and validates
chart-rendered images: server/worker, optional Control Plane, optional queue
monitor, enabled smoke test image, and the Troubleshoot image used by health
probes. Set `registryImages.imagePullSecretName` when the registry requires
credentials.

`supportPackage.nodeMetrics: {}` is the default and collects Kubernetes node
metric JSON. The bundle includes a presence check for `node-metrics/*.json`, one
native Troubleshoot `nodeMetrics` analyzer for PVC usage coverage, and
`nodeResources` analyzers for the default RAM footprint. The default minimum is
2 CPU allocatable and 2Gi memory allocatable across the cluster, with at least
one schedulable node that has 500m CPU and 512Mi memory allocatable for a single
RAM pod. A single-node cluster warns because production deployments should
provide node redundancy for server and worker replicas.

Review the archive before sharing it with Redis Support. The default workflow
collects exact data-plane/Control Plane config and overlay Secret or ConfigMap
keys, then redactors run over the bundle. It must not include license contents,
admin tokens, queue-monitor Redis URLs, TLS Secret values, RAM memory contents,
prompts, provider payloads, Redis keys or values, credentials, or private keys.
If you find any of those, do not share the archive until the file is removed or
redacted.

Render the support-package template when applying the support-bundle specs
outside a Helm install or upgrade:

```sh
helm template <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f ram-values.yaml \
  --show-only templates/support-package.yaml \
  > ram-support-package-specs.yaml

kubectl apply --namespace <namespace-name> -f ram-support-package-specs.yaml
```

OpenShift uses the same workflow from an authenticated `oc`/`kubectl` context.
For platform-wide OpenShift failures, collect `oc adm must-gather` separately;
it is not part of the default RAM package.

For multi-region incidents, run the command once per RAM namespace/release and
use the same `supportCase` and `incident` metadata with each region's
`region=<logical-region>` value. For FIPS deployments, keep using the same
command; the package records the chart `security.profile` and image identity.
For air-gapped deployments, use the Troubleshoot binaries installed from your
internal mirror in the prerequisite step. Mirror
`supportPackage.healthCheckImage.repository:supportPackage.healthCheckImage.tag`
and set `supportPackage.healthCheckImagePullSecretName` when the mirror needs an
image pull Secret. If registry validation is enabled, set
`supportPackage.registryImages.imagePullSecretName` for private registries.

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

## Observability / Metrics

Both the API server and the worker expose Prometheus metrics at `/metrics` on the
service container port (`service.port`, default `9000`). The endpoint is
**unauthenticated** and is intended for **in-cluster scraping only** — do not
expose it outside the cluster.

The async-queue signals are split across the two processes, so collecting the
full picture requires scraping **both**:

- **Server** (`redis-agent-memory` Deployment + Service): emits the submission
  metric `jobqueue_enqueue_total` (with `service_name="dataplane"`) alongside the
  HTTP/runtime metrics. Reachable through the `redis-agent-memory` Service on port
  `9000`.
- **Worker** (`redis-agent-memory-worker` Deployment): emits the job-processing
  metrics (all with `service_name="worker"`) — `jobqueue_processing_duration_seconds`,
  `jobqueue_schedule_to_start_seconds`,
  `jobqueue_size`, `jobqueue_oldest_pending_seconds`,
  and `jobqueue_worker_up`.

Every `jobqueue_*` series also carries the constant identity labels
`service_namespace="ram"` and `service_name` (`dataplane` on the server, `worker`
on the worker), so the emitting process is distinguished by label rather than by
the metric name.

## Update

For every update:

- update the chart version and image tag as needed
- recalculate `LICENSE_CHECKSUM` if the license file changed
- if you're using `config.existingSecret`, recalculate `CONFIG_CHECKSUM` if the
  config file changed (`config.render` checksums the rendered config
  automatically — nothing to recalculate)
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
- credential/overlay rotation: update the pre-created overlay Secret contents,
  then restart the pods (`kubectl rollout restart`) — credentials are read at
  client construction, so the mounted overlay takes effect on pod restart. The
  chart rolls automatically only if the overlay Secret *name* changes.
- control-plane admin-token rotation: edit the admin-token Secret — read-on-use, no redeploy needed

<!-- markdownlint-enable MD013 MD060 -->
