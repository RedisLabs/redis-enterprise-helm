<!-- markdownlint-disable MD013 MD060 -->

# Redis Agent Memory On-Premises Deployment

Identity policy ownership and loading are defined by the
[on-prem identity configuration contract](../../docs/specs/identity-service/onprem-product-identity-configuration-mod-18639.md).
The [identity values example](examples/identity/values.yaml) shows local CP role
mapping and the connection to the Identity Service release. Identity Service
bindings and policy overlays are values of that release (`configData`,
`secrets.*`); see its [chart README](../../identity-service/helm/README.md).
Conflicting local role mappings fail startup rather than silently changing
access.

This chart deploys Redis Agent Memory into a customer-managed Kubernetes cluster.
One release creates:

- `redis-agent-memory` API server
- `redis-agent-memory-worker` background worker
- `redis-agent-memory-controlplane` bundled admin store API

The server and worker use the same license Secret and application config carrier
(a chart-rendered ConfigMap, or a BYO Secret). The control plane adds its own
config carrier and token Secrets, and reuses the same license Secret.

This chart deploys no Identity Service (IdS). Agent keys are minted and
introspected by a separately installed `iris-identity-service` release, which
you install first and connect this release to; see
[Connecting to the Identity Service](#connecting-to-the-identity-service).

A deployment is a bundled control plane, server, and worker serving dynamically
managed stores. Start with
[Install](#install). Credentials (Redis connection URLs, embedder/LLM API keys)
never live in your values or the rendered ConfigMap — you supply them either
embedded in a BYO config Secret, or through one credentials Secret mounted as an
overlay (see [Supplying credentials](#supplying-credentials)). To serve more than
one region, see [Multi-Region Deployment](#multi-region-deployment).

## Before you install

- Kubernetes 1.28+
- Helm 3+
- Redis endpoints reachable from the cluster
- A license is required to use the on-prem version. Contact your Redis account representative. If you do not have one, contact Redis sales: <https://redis.io/meeting/>
- RAM image access from the cluster; see [Image access](#image-access)
- An Iris Identity Service release, chart `0.10.0` or later, installed first
  (required for agent-key auth, the default); see
  [Connecting to the Identity Service](#connecting-to-the-identity-service)

Prerequisite matrix:

| Area | Requirement | Notes |
| --- | --- | --- |
| Kubernetes | Kubernetes 1.28+ and Helm 3+ | The chart installs standard `apps/v1` Deployments, Services, optional `autoscaling/v2` HPAs, optional Ingress, and pre-created Secrets. |
| Content store Redis | Redis 7.2.0 through 8.4.x with RedisJSON and Redis Search 2.10.0 or later, reachable from RAM | Configure endpoints in `databases.<id>.urls`. The store indexes require `INDEXMISSING` and `INDEXEMPTY` from Redis Search 2.10.0. The content store holds session memory JSON documents and long-term memory hashes, so it must support JSON commands, hashes, TTLs, `FT.CREATE`, `FT.SEARCH`, JSON indexing, and vector `HNSW` fields. |
| Job Redis | Redis 6.2+ reachable from RAM server and worker pods | Configure `background_jobs.redis.urls` to the regional job Redis endpoint, use a non-volatile / `noeviction` policy, and keep exactly one async backend enabled per process. The job Redis does not need RediSearch or RedisJSON unless the same Redis also serves as the content store. |
| Metadata Redis | Redis 6.2+ reachable from the control plane, server, and worker | Configure `metadata.urls` and a shared `metadata.namespace`. It stores dynamic store records. Agent-key records live in the Identity Service release's own metadata Redis, which may be the same Redis. |
| Architecture support | Releases built by `memory-onprem-release.yml` publish one multi-platform tag (`linux/amd64` and `linux/arm64`) for each RAM image; earlier releases are `linux/amd64` only | On a mixed or ARM64 cluster the node pulls its own platform from the same tag. A private-registry mirror must copy every platform (`skopeo copy --all` or `crane copy`); `docker pull`/`tag`/`push` mirrors only the host platform. The optional `ghcr.io/jpedrosouza/asynqdash` console image publishes both platforms. |

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
- `controlplane.image.tag` and a control-plane config
- with agent-key auth: `dataplane.identityServiceBaseURL` and
  `identityService.credential.existingSecret` — the Identity Service release's
  Runtime URL and the data plane's runtime credential registered there

In production also set `controlplane.internalToken.existingSecret`, the control
plane's internal token shared with the Identity Service release. When it is
empty the chart generates one, which suits development only.

The data plane defaults an unspecified `memory.auth.method` to `agent_key`,
which needs an Identity Service to introspect against. Without one, for
development only, set `memory.auth.method: none` with `memory.profile: dev`.
The data plane refuses `auth.method: none` with any other profile, and the
chart refuses to render it. With a chart-rendered config, the chart refuses to
render agent-key auth without the connection values rather than letting the
pod CrashLoopBackOff. Service subjects with the `identity_service` authority
(`auth.service_subjects`) look
their grants up in the Identity Service too, so they need the same connection
values even when another auth flavour leaves `memory.auth.method` unset.

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

Image pull Secrets are normally not needed for the standard public Docker Hub
path. Configure them only when the cluster uses explicit registry credentials, or
when the images are mirrored to a private/authenticated registry.

For authenticated registries, create an image pull Secret in the target
namespace and reference it with `imagePullSecrets` (or `global.imagePullSecrets`,
read when `imagePullSecrets` is empty). The Identity Service release takes its
own pull Secret:

```sh
kubectl -n <namespace-name> create secret docker-registry ram-registry \
  --docker-server=<registry-host> \
  --docker-username=<username> \
  --docker-password=<password>
```

```yaml
global:
  imagePullSecrets:
    - name: ram-registry
```

For mirrored images, override `image.repository` and
`controlplane.image.repository`. Mirror the Identity Service image through that
release's own `image.*` values. Use the image tag supplied for each release; do
not use the source Git tag format as the Docker image tag.

## Required Secrets

Create the license Secret:

```sh
kubectl create namespace <namespace-name>

kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license
```

If your Secret key uses a different name, set `license.secretKey` in your Helm
values.

Create the two Secrets this release shares with the Identity Service release.
Both releases mount them, so deployment automation owns them; neither chart
generates them in production:

```sh
# The data plane's runtime credential, registered on the Identity Service release.
kubectl -n <namespace-name> create secret generic memory-dp-credential \
  --from-literal=token="$(openssl rand -hex 32)"
# The control plane's internal token, presented by the Identity Service release
# when it validates grants.
kubectl -n <namespace-name> create secret generic memory-internal-token \
  --from-literal=token="$(openssl rand -hex 32)"
```

Reference them with `identityService.credential.existingSecret` and
`controlplane.internalToken.existingSecret`. The Identity Service release needs
its own metadata Secret; see its
[chart README](../../identity-service/helm/README.md#prerequisites).

Redis and embedding-provider credentials are supplied via mounted secret
overlays, covered in [Install](#install).

## Install

**Quick start** — the happy path in four steps:

1. Create the license Secret, one credentials Secret, and the two Secrets
   shared with the Identity Service release (all detailed below).
2. Install the Identity Service release in the same namespace; see
   [Connecting to the Identity Service](#connecting-to-the-identity-service).
3. Copy [`examples/basic/values.yaml`](examples/basic/values.yaml) and set
   `image.tag`, `controlplane.image.tag`, `license.existingSecret`,
   `secrets.secretName`, `dataplane.identityServiceBaseURL`,
   `identityService.credential.existingSecret`, and
   `controlplane.internalToken.existingSecret`.
4. `helm install <release> redis-ai/redis-agent-memory -f values.yaml -n <namespace>`

Each step is explained below; the full config field set is in
[Config Reference](#config-reference).

A deployment is one bundled control plane, server, and worker serving dynamic stores. You
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
(`redis://user:pass@host:port`) under `metadata.urls`, `databases.<id>.urls`,
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
#   metadata: { urls: [redis://user:pass@redis-metadata:6379] }
#   databases:
#     "1": { urls: [redis://user:pass@redis-store:6379] }
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
# Metadata and database URLs arrive through the shared overlay.
shared:
  databases:
    "1":
      name: default

memory:
  default_extraction_strategy: instruct
  namespace_features:
    api: true
    routing:
      policy_api: true
      automatic: true
      admission: true
  # This starter assumes the Data Plane is infrastructure-isolated. The data
  # plane accepts auth.method none only with profile dev. Before you expose it,
  # use agent_key auth, remove profile dev, and configure worker identity.
  profile: dev
  auth:
    method: none
  background_jobs:
    redis:
      enabled: true            # urls arrive via the overlay
      queue_prefix: ram
      worker_regions: [default]
  request_region:
    default: default
  dataplane_client:
    # Replace <release-name> if you choose a different Helm release name.
    base_url: http://<release-name>-redis-agent-memory:9000
    auth:
      disabled: true
  embedding:
    provider: openai
    models:
      default_embedding_model: text-embedding-3-large
      dimensions: 3072
  embedders_connection_details:
    openai:
      base_url: https://api.openai.com
      credentials: { type: static }   # api_key arrives via the overlay

image:
  repository: redislabs/agent-memory
  tag: "<ram-version>"

controlplane:
  image:
    repository: redislabs/agent-memory-control-plane
    tag: "<ram-version>"
  config:
    render: true
  configData:
    profile: prod
    auth:
      type: admin-token
      admin_token:
        token_file: /etc/controlplane-onprem/admin/token
      internal_token:
        token_file: /etc/controlplane-onprem/internal/token
    license:
      license_path: /etc/redis-agent-memory/license
    embedding:
      dimensions: 3072
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

With `config.existingSecret` the chart validates none of the config content:
the render-time guards (the agent-key connection requirements and
`auth.method: none` being allowed only with `profile: dev`) do not apply, and
the data plane enforces them at startup instead — a violating pod refuses to
start.

Build the config file from the [Config Reference](#config-reference) fields and
create the Secret:

```sh
kubectl -n <namespace-name> create secret generic ram-config \
  --from-file=memory-dataplane.config.yaml=./memory-dataplane.config.yaml

kubectl -n <namespace-name> create secret generic ram-controlplane-config \
  --from-file=controlplane-onprem.config.yaml=./controlplane-onprem.config.yaml
```

If your Secret key uses a different name, set `config.secretKey`. Compute a
checksum for both Secrets so pods roll when either file changes:

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
CONFIG_CHECKSUM="$(shasum ./memory-dataplane.config.yaml | awk '{print $1}')"
CONTROLPLANE_CONFIG_CHECKSUM="$(shasum ./controlplane-onprem.config.yaml | awk '{print $1}')"
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

controlplane:
  image:
    repository: redislabs/agent-memory-control-plane
    tag: "<ram-version>"
  config:
    existingSecret: ram-controlplane-config
    existingSecretChecksum: "<controlplane-config-checksum>"
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

# Namespace lifecycle and routing. Omit this block to keep both off.
namespace_features:
  api: true
  routing:
    policy_api: true
    automatic: true
    admission: true

# Omit this block to use the agent_key default. The data plane accepts
# auth.method none only with profile dev, so use it only for development.
profile: dev
auth:
  method: none

# Optional fallback for CP-managed stores that omit summarization.
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

# Metadata Redis shared with the bundled control plane.
metadata:
  urls:
    - redis://user:pass@redis-metadata:6379

# Store database registry shared with the control plane. New stores snapshot the
# selected database; legacy records with invalid URLs fall back by database ID.
databases:
  "1":
    name: default
    urls:
      - redis://user:pass@redis-store:6379

# Deployment-level embedding defaults stamped onto every resolved store.
embedding:
  provider: openai
  models:
    default_embedding_model: text-embedding-3-large
    dimensions: 3072

# Embedding provider connection settings.
embedders_connection_details:
  # Provider name referenced by embedding.provider.
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

# Connection registry for LLM providers. Every llm block below selects an
# entry by its provider key; endpoint settings live only here, so several
# strategies can share one connection definition. The http_client settings
# here are defaults — an llm block can override them per field.
# OpenAI non-streaming generation defaults to the Responses API. Set
# endpoint.generation_api to chat_completions for rollback; streaming remains
# on Chat Completions.
inference_providers:
  # The key doubles as the wire protocol (openai, oip, vertex-ai, noop) unless
  # an explicit `protocol` field is set (useful for alias keys like openai-eu).
  openai:
    endpoint:
      # Base URL for LLM requests to this provider.
      base_url: https://api.openai.com/v1
      # Request timeout for LLM calls.
      timeout: 30s
      # Header style used to send credentials.
      auth_format: bearer
    http_client:
      # Keep TLS verification enabled unless you deliberately use self-signed certs.
      skip_verify: false
      # Per-request timeout for LLM calls.
      timeout: 30s
      # Retry count for transient LLM failures.
      max_retry_attempts: 3

# Automatic session summarisation settings.
session_summarisation:
  # Service-level kill switch for summarisation. Override per-store configs.
  enabled: false
  # LLM configuration for the summarisation: which inference_providers entry
  # to call, the credentials to call it with, and the models to select.
  llm:
    # Key into inference_providers. A key that is not defined there fails at
    # startup.
    provider: openai
    credentials:
      # Use static API key authentication for the summarisation LLM.
      type: static
      # API key used for summarisation requests.
      api_key: "<summarisation-llm-api-key>"
    models:
      # Chat model used to generate session summaries.
      default_chat_model: gpt-4o
    # Optional per-strategy override of the provider's http_client defaults.
    # Set fields replace the registry values; unset fields keep them.
    # http_client:
    #   timeout: 120s

# Platform LLM for fast classification tasks.
classification:
  llm:
    # Key into inference_providers.
    provider: openai
    credentials:
      type: static
      api_key: "<classification-llm-api-key>"
    models:
      default_chat_model: gpt-5.6-luna

# Long-term memory promotion model settings.
promote_session_memory:
  # Optional per-strategy windows used to batch rapid session writes into one
  # promotion job. Each strategy defaults to 5m when omitted; set to 0s to
  # schedule promotion immediately. Override with
  # MEM_PROMOTE_SESSION_MEMORY_STRATEGIES_INSTRUCT_PROMOTION_DEDUPLICATION_WINDOW.
  strategies:
    instruct:
      promotion_deduplication_window: 5m
      llm:
        # Key into inference_providers.
        provider: openai
        credentials:
          # Use static API key authentication for the promotion LLM.
          type: static
          # API key used for promotion requests.
          api_key: "<promotion-llm-api-key>"
        models:
          # Chat model used to extract long-term memory from conversations.
          default_chat_model: gpt-4o
```

### Migrating to inference_providers (chart 0.0.14)

From chart 0.0.14 the service reads `endpoint` and `protocol` only from the
root `inference_providers` registry; it ignores those keys (and the dropped
`batching` key) inside an `llm` block and logs a startup warning that names
them when the block is used.
Move each connection into the registry and keep `provider`,
`credentials`, `models`, `reasoning_mappings`, and `error_handling` in the
`llm` blocks. An
`llm` block may keep an `http_client` section: it now overrides the provider
entry's `http_client` defaults per field for that block alone. This tolerance
is limited to those three legacy keys: any other unrecognised key in an `llm`
block (for example the typo `model` instead of `models`) fails startup with an
error naming the key.

```yaml
# Before (chart <= 0.0.13)
session_summarisation:
  llm:
    provider: openai
    endpoint:
      base_url: https://api.openai.com/v1
    credentials:
      type: static
      api_key: "<key>"

# After (chart >= 0.0.14)
inference_providers:
  openai:
    endpoint:
      base_url: https://api.openai.com/v1
session_summarisation:
  llm:
    provider: openai
    credentials:
      type: static
      api_key: "<key>"
```

A fully migrated values file works only with chart 0.0.14 binaries, and an
unmigrated one only with chart 0.0.13 binaries: the old binary requires
`endpoint` inside the block, and the new binary fails startup when the
registry entry is missing. If you must keep one values file valid for both
versions — for example to keep a rollback path open, or while a shared GitOps
values file still serves both — use a transitional shape: add the
`inference_providers` registry and keep the old `endpoint` and `protocol`
keys inside each `llm` block, with identical values. Chart 0.0.13 binaries
use the block keys and ignore the unknown `inference_providers` section;
chart 0.0.14 binaries use the registry and log a warning naming the stale
block keys. Delete the block keys once you no longer plan to roll back.

Outbound LLM HTTP metrics keep their per-strategy client tags
(`promote_instruct_llm`, `custom_extraction_llm`, `summarise_session_llm`), so
existing token-spend dashboards keep working. The session summary view worker,
previously not instrumented, now reports under `session_summary_view_llm`.
Each strategy keeps its own HTTP client and connection pool: clients are
cached per strategy tag and resolved configuration.

### Using Vertex AI for embeddings

Memory can embed with Google's `gemini-embedding-001` through the `vertex-ai`
embedding protocol, authenticated with a Google service account. See
`examples/vertex-ai/` for a values file and credentials overlay. Chat models are
configured separately; see the Gemini chat section of
[`pkg/inference/README.md`](../../pkg/inference/README.md).

```yaml
embedding:
  provider: vertex            # the embedders_connection_details key below
  models:
    default_embedding_model: gemini-embedding-001
    dimensions: 1536
embedders_connection_details:
  vertex:
    protocol: vertex-ai
    base_url: https://us-central1-aiplatform.googleapis.com/v1/projects/<project>/locations/us-central1/publishers/google/models/gemini-embedding-001:predict
    embeddings_input_field: content
    credentials:
      type: gcp-service-account   # the key itself arrives through the overlay
```

- **URL and dimension.** `base_url` is the full `:predict` URL, and the model in
  it is the model used. In `content` mode `dimensions` is sent as `outputDimensionality`
  and checked against every returned vector (in `text` mode it is neither); `gemini-embedding-001` accepts 768,
  1536 and 3072. `gemini-embedding-2` is not supported. Set the same width in
  `controlplane.configData.embedding.dimensions`, which sizes the index.
- **Layering over `examples/basic`.** Helm merges maps, so `examples/basic`
  keeps its `openai` embedder entry, and Memory validates every embedder at
  startup. The overlay therefore also carries a placeholder `openai` key (an
  `openai: null` override does not remove the entry). Set both widths:
  `memory.embedding.models.dimensions` and
  `controlplane.configData.embedding.dimensions`; the control plane sizes the
  vector index from its own value.
- **Request shape.** `embeddings_input_field: content` is the shape Google's
  published models expect. Leave it out for a Model Garden endpoint that takes
  `text`.
- **Credentials.** Put the service-account key in the credentials overlay under
  `embedders_connection_details.vertex.credentials.gcp.service_account_json`,
  never in values. The account needs permission to call Vertex AI
  (`roles/aiplatform.user` is the usual role). After you replace the key, run
  `kubectl rollout restart` on the Memory data plane and worker workloads.
- **Batches.** At most 250 texts go in one request. The shared client splits a
  larger call into ordered requests.
- **Over-limit input is rejected.** `gemini-embedding-001` reads about 2,048
  tokens, roughly 8,000 English characters, while Memory accepts up to 50,000
  characters. In `content` mode Memory sends `autoTruncate: false`, so Vertex
  refuses an over-limit input and Memory returns a client error. The text is not
  stored and is never silently cut. The limit is in tokens, so token-dense text
  fails sooner than plain English. A `text`-mode endpoint is sent no
  `autoTruncate` and keeps its own behavior.

| Symptom | Cause |
| --- | --- |
| Client error on a long memory | The text is over the model's token limit. Shorten or split it. |
| HTTP 500 "The service could not complete a model request"; the data-plane log says "platform model credentials rejected by provider" with `invalid_grant` | The service account is unknown or disabled. Replace the key. |
| Startup error about the service-account key | `service_account_json` is missing, empty or malformed. |
| Vector width mismatch (`ErrInvalidResponse`) | `dimensions` is not one the model accepts, or the endpoint serves a different model. |

#### Gemini chat for the LLM roles

Vertex's OpenAI-compatible endpoint serves the Memory LLM roles. The registry
entry uses the `openai` protocol under an alias key, and each `llm` block that
names it carries the service-account credential. `examples/vertex-ai/` configures
the instruct, summarisation and classification roles this way.

```yaml
inference_providers:
  vertex-gemini:
    protocol: openai
    endpoint:
      base_url: https://aiplatform.googleapis.com/v1/projects/<project>/locations/global/endpoints/openapi
      base_url_as_is: true          # otherwise Iris appends /v1 and Google answers 404
      generation_api: chat_completions   # the endpoint has no Responses API
promote_session_memory:
  strategies:
    instruct:
      llm:
        provider: vertex-gemini
        credentials:
          type: gcp-service-account   # the key arrives through the overlay
        models:
          default_chat_model: google/gemini-3.6-flash
```

- Use the `global` location. Model names are `google/<model>`.
- Set `generation_api: chat_completions` on the entry: only summary views default
  to it, and every other role would call the Responses API, which Vertex does not serve.
- Use `google/gemini-3.6-flash`. Gemini reasoning models such as
  `google/gemini-3.8-flash` spend output tokens on reasoning and answer slowly for
  namespace routing, which has a fixed 3-second deadline. Memory sends no output
  cap unless you set `promote_session_memory.strategies.instruct.max_completion_tokens`;
  set it for these models (the example uses 4096).
- Put each role's key in the overlay under that role's
  `credentials.gcp.service_account_json`, then run `kubectl rollout restart`.

### Using Anthropic for LLM roles

Anthropic can serve every Memory LLM role (promotion, custom extraction,
session summarisation, classification, summary views) through its
OpenAI-compatible endpoint. Anthropic has no embeddings API, so it never
replaces the embedder: keep `embedding` on another provider such as OpenAI. A
config that selects `anthropic` as an embedder fails at startup with
`embedder "<name>": protocol: must be one of cohere, noop, oip, openai, vertex-ai`
(`key must be one of ... when protocol is unset` when the entry is keyed `anthropic`).

Register the connection once, set `generation_api: chat_completions`
explicitly, and point each LLM role at it. Keep the key in the credentials
overlay, not in values. See `examples/anthropic/` for a complete values file
and overlay.

```yaml
inference_providers:
  anthropic:
    endpoint:
      base_url: https://api.anthropic.com/v1/
      generation_api: chat_completions
      auth_format: bearer
promote_session_memory:
  strategies:
    instruct:
      llm:
        provider: anthropic
        credentials:
          type: static   # api_key arrives through the overlay
        models:
          default_chat_model: claude-haiku-5-5
```

Behavior to know before you switch a role to Anthropic:

- **Credential changes.** Memory reads the key when it builds its client.
  After you change the Secret, run `kubectl rollout restart` on the Memory
  data plane and worker workloads.
- **Missing and invalid keys.** An invalid key returns `401 Invalid Anthropic API Key`.
  A missing key never reaches Anthropic: with a `static` credential and an empty
  `api_key`, Memory fails when it builds the client ("api_key is required for
  static credentials"). If you see that error, check that the overlay holds the
  key under the right role.
- **Anthropic as an embedder.** Anthropic has no embeddings API, so it can
  never be an embedder. An embedder endpoint that names the `anthropic`
  protocol, or is declared under the key `anthropic`, fails at startup. An
  Anthropic URL configured as an `openai` embedder cannot be recognised,
  because a proxy can hide the host. It passes startup and fails on the first
  embedding call with a `404` whose body contains `not_found_error`. If you see
  that error, point the embedder at a provider that embeds, such as OpenAI.
- **Summary views.** Anthropic accepts only strict, closed response formats,
  and those cannot describe a summary view with optional fields or free-form
  objects. For Anthropic, Memory sends no response format. It puts the view
  schema in the prompt, asks for one JSON object, and checks the reply against
  the schema before it stores the value. Other providers keep today's response
  format. Custom memory types and extraction are not affected.
  - Optional fields and free-form `object` fields work. A field the model
    cannot support from the memories is left out of the value. It is not
    filled with a placeholder.
  - When a view is built from several batches of memories, a value stated in a
    newer batch replaces an older one, including `false`, `0` and an empty
    list. A field a newer batch does not mention keeps its older value.
  - The provider does not enforce the shape of the reply. A reply that is not
    one valid JSON object matching the schema fails the refresh with
    `OUTPUT_VALIDATION_FAILED`. A code fence or a sentence around the object is
    removed first.
  - Avoid a catch-all free-form `object` field such as "anything else". The
    model can copy unrelated memories into it, so every partial result stays as
    large as its input and the refresh fails or times out. This can happen with
    other providers too. A test with OpenAI needed many more model calls and
    returned a truncated, less accurate value.
- **Numeric bounds and list sizes.** Anthropic rejects `minimum`, `maximum`,
  `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`,
  `maxLength` and `maxItems` in response formats and tool schemas, so Memory
  removes them from those. A summary view schema travels as prompt text, so
  bounds it declares stay there as guidance. The response validation inside
  Memory enforces all of these limits.
- **Model limits and pricing.** Context size, output limit and pricing are the
  provider's; check its current figures for `claude-haiku-5-5`.

### Using Cohere for LLM roles and embeddings

Cohere can serve every Memory LLM role and the embedder through its
OpenAI-compatible endpoint, with a static API key. See `examples/cohere/` for a
values file and overlay.

```yaml
inference_providers:
  cohere:
    endpoint:
      base_url: https://api.cohere.ai/compatibility/v1
      generation_api: chat_completions   # Cohere serves no Responses API
embedding:
  provider: cohere
  models:
    default_embedding_model: embed-v5.0-pro
    dimensions: 2048
embedders_connection_details:
  cohere:
    protocol: cohere
    base_url: https://api.cohere.ai/compatibility/v1
    credentials:
      type: static   # api_key arrives through the overlay
```

- **Role models.** Use `command-a-plus-05-2026` for extraction and summarisation
  and set `promote_session_memory.strategies.instruct.max_completion_tokens`
  (the example uses 4096): Memory sends no output cap by default. Use
  `command-a-plus-05-2026` for `classification.llm` too: Memory uses it for
  classification and namespace routing. Do not use `command-r7b-12-2024` for
  either: it is faster, but it left routing cases unmatched in testing and can
  return invalid JSON for document extraction.
- **Embedding width.** Cohere is not sent a `dimensions` setting, so the
  configured `dimensions` must be the model's own width, and a different width
  fails the call. `embed-v5.0-pro` and `-fast` return 2048; set the same width in
  `controlplane.configData.embedding.dimensions`, which sizes the index. No Cohere model
  reaches 3072, the Memory default, so a Cohere deployment is a separate vector
  space. Changing the model or width does not migrate or re-embed existing
  vectors.
- **Layering over `examples/basic`.** Helm merges maps, so `examples/basic`
  keeps its `openai` embedder entry, and Memory validates every embedder at
  startup. The overlay therefore also carries a placeholder `openai` key (an
  `openai: null` override does not remove the entry). Set both widths:
  `memory.embedding.models.dimensions` and
  `controlplane.configData.embedding.dimensions`; the control plane sizes the
  vector index from its own value.
- **Batches.** At most 96 texts go in one request; the shared client splits
  larger calls in order.
- **Long input.** Cohere trims over-limit input on its side without an error,
  after Iris's own 15,000-byte cut. Token-dense text can be shortened silently.
  Cohere's compatible endpoint cannot be told to reject it.
- **Summary views.** Cohere rejects an object with no required fields, so for
  Cohere Memory sends no response format, puts the view schema in the prompt and
  checks the reply before it stores the value, as it does for Anthropic.
- **Credential changes.** Run `kubectl rollout restart` on the Memory data plane
  and worker workloads after you change the Secret.
- **Failures.** A wrong key returns `401 Incorrect API key provided`. A missing
  key fails when Memory builds the client ("api_key is required for static
  credentials"). A request with more than 96 texts that
  bypasses the shared client returns `400 total number of texts must be at most 96`.

### Enabling summary views

Summary views are off by default. Enable them in `summary_views` and give them
explicit limits; Memory refuses to start with `enabled: true` and any of these
unset or zero:

```yaml
summary_views:
  enabled: true
  llm:                      # a full client block, not an inference_providers entry
    provider: openai        # anthropic, cohere, or openai with a Vertex endpoint
    endpoint:
      base_url: https://api.openai.com
    credentials:
      type: static          # api_key arrives through the overlay
    models:
      default_chat_model: gpt-5.6-luna
  page_size: 10
  max_definitions: 100
  max_partitions: 100
  max_concurrent_refreshes: 2
  max_concurrent_refreshes_per_store: 1
  max_input_tokens: 8000
  max_source_records: 100
  max_source_tokens: 100000
  default_debounce: 1s
  min_debounce: 1s
  max_debounce: 1m
  default_reconcile_interval: 1h
  min_reconcile_interval: 1s
  max_reconcile_interval: 24h
  schedule_repair_interval: 1m
  cleanup_batch_size: 100
  cleanup_timeout: 5s
  generation:
    max_output_tokens: 4000
    timeout: 90s
dataplane_client:
  base_url: http://redis-agent-memory:9000   # the worker calls the data plane for view maintenance
```

- `summary_views.llm` carries its own `endpoint`. For Anthropic and Cohere set
  `endpoint.base_url` and `endpoint.generation_api: chat_completions`; for Vertex
  use `provider: openai` with the Vertex `base_url`, `base_url_as_is: true` and
  `credentials.type: gcp-service-account`. Keys go in the overlay under
  `summary_views.llm.credentials`.
- The worker needs `dataplane_client.base_url`; without it view maintenance jobs
  fail and retry.
- Anthropic and Cohere answer in prompt-guided mode, as described above.

### Enabling custom extraction and document ingestion

Both are off by default and need the worker to run. Custom extraction uses the
instruct strategy's LLM unless `promote_session_memory.strategies.custom_extraction.llm`
is set.

```yaml
custom_extraction:
  enabled: true
document_ingestion:
  enabled: true
  max_decoded_bytes: 1048576
  max_input_tokens: 8000
  max_reconciliation_input_tokens: 32000
  max_chunks: 32
  max_output_records: 100
  max_queued_bytes_per_store: 10485760
  max_retries: 3
  max_execution_seconds: 900
  source_retention_seconds: 86400       # required; Memory refuses to start without it
  checkpoint_retention_seconds: 86400   # required; Memory refuses to start without it
```

Register a custom memory type with an `extractionStrategy.prompt` on the control
plane, then write session events: the worker extracts memories of that type with
their attributes. For documents, create an extractor (`source: DOCUMENTS`,
`strategy: CUSTOM`, a registered `memoryType`) and post the document to
`document-ingestions`; the worker chunks it and writes the extracted memories.
Both work with OpenAI, Anthropic, Cohere and Vertex.

Most important config fields:

- `request_region.*`: request-origin region resolution for regional queue submission
- `background_jobs.redis.urls`: regional Redis queue backend used for async work
- `background_jobs.redis.queue_prefix`: queue namespace prefix; queue names are `<queue_prefix>:<region>:<job_slug>`
- `background_jobs.redis.worker_regions`: logical regions this worker deployment processes; required in `--mode=worker`, ignored (with an INFO log) in `--mode=server`
- `metadata.urls`, `metadata.namespace`: metadata Redis shared with the control plane
- `databases.<id>.urls`: registered Redis databases that hold short-term and long-term memory
- `embedding.*`: deployment-level embedding provider, model, and vector size
- Control Plane `longTermMemoryExclusions`: optional store-level exclusions — `enabled`, the
  semantic prompt (`semantic.{enabled,prompt}`), the built-in detector selection
  (`builtInDetectors.{enabled,detectors}`), and customer-authored detectors
  (`customDetectors.{enabled,detectors}`); omit to disable
- Control Plane `longTermMemoryExclusions.builtInDetectors.detectors[]`: `id` (from the platform
  catalog: `email`, `credit-card`, `us-ssn`, `phone`, `ip-address`), `enabled`, and `action`
  (`redact` or `drop`, default `redact`). Enforced by the extraction worker on every LLM-mediated
  promotion path — instruct promotion, custom extraction and the session summary view — over each
  candidate memory's text, topics and attributes — values at any depth, and the keys inside an
  `object` field — before the write reaches the data plane, so nothing matched is embedded or
  stored. **Not** enforced on direct Create-LTM API writes, which
  bypass the worker: a caller writing a memory itself is asserting exactly what to store.
  When several matching detectors disagree about one memory, drop wins, and a dropped update leaves
  the stored memory unchanged. Two surfaces have no room for the `[REDACTED]` placeholder, because
  writing a string into them would break a declared type or overwrite a sibling: a **numeric**
  attribute field and a **key inside an `object` field**. Under `redact` the matched value is not
  written — the attribute, or that one nested entry, is left out — and the memory keeps its text, its
  topics and everything else; an absent attribute is already ordinary, since a model fills whatever
  subset of the declared fields it found. Under `drop` the memory goes, as configured. One
  consequence worth knowing: a field left out leaves no trace, where a redacted string leaves a
  visible `[REDACTED]`.
  **On a new memory that means the field is absent. On an update it means the field is not changed**,
  so if that attribute was already stored — written before this policy was enabled, before a detector
  was added to it, or through the direct Create-LTM API — the previously stored value stays. Screening
  governs what is written from here on; it does not clean up what is already there, which is a
  deliberate non-goal (no retroactive cleanup, no migration). Cleaning stored data on whichever
  memories a model happens to revisit would be partial and unpredictable, so it is not attempted at
  all rather than half done.
  A numeric field is only ever matched by a detector whose digits carry their own evidence — a
  credit-card number, which Luhn confirms. It is not treated as a phone number, a social security
  number or an IP address, because those need surrounding words that a numeric field has none of:
  a Unix timestamp, an order id and a customer id are all valid telephone numbers in some country,
  so screening them on shape alone would delete ordinary data. A decimal point is the one mark a
  numeric field does carry, and it is deliberately not read as the group separator of a written
  phone number — so a coordinate, a price and a measurement are left alone too. The same rule
  applies in `text`, where the surrounding words are available and are used, and where a number
  written with two or more separators, parentheses or a country code is matched on its shape.
- Control Plane `longTermMemoryExclusions.customDetectors.detectors[]`: `name`, `enabled`,
  `action` (`redact` or `drop`, default `redact`), and `matcher`. For organization-specific
  identifiers no built-in detector covers. Enforced by the same worker, on the same paths, over
  the same surfaces, and with the same rules as the built-in group above — the two resolve into
  one flat set, so a match by either applies that detector's action and drop still wins when
  they disagree.
  - `matcher`: `{kind: regex, regex: {pattern: "..."}}`. `regex` is the only kind today; the
    field is tagged so further kinds are additive.
  - `pattern` is evaluated by **RE2**, which runs in linear time — so an expensive pattern is not
    a denial-of-service risk, but lookaround and backreferences are unavailable. Rejected on
    write if it does not compile, or if it can match without consuming text (`\b`, `a*`): such a
    pattern matches at every position, so it would exclude every memory the store writes.
  - Per store: at most 32 detectors, each pattern at most 512 characters. `name` must be 1-64
    characters, start with a letter, and contain only letters, digits, underscores or dashes; it
    must be unique within the store and must not be one of the built-in catalog ids. The name
    appears in the exclusions log line, which is why its shape is an identifier and not free
    text. It is **not** a metric attribute: `iris_agentmemory_worker_extraction_exclusions_total` reports
    every custom detector under `detector="custom"`, keeping that label bounded by the build,
    so per-rule volume is read from the log rather than from a dashboard.
- `default_summarisation_config.*`: optional fallback summarisation configuration for stores that do not set it explicitly
- Control Plane `summarization`: per-store summarisation configuration
- `embedders_connection_details`: embedding endpoint and credentials
- `inference_providers.<key>.*`: LLM provider connection registry (protocol, endpoint, HTTP client) that every `llm.provider` key resolves against
- `session_summarisation.enabled`: service-level summarisation kill switch; Has precedence over store-level configuration.
- `session_summarisation.llm.*`: provider key, credentials, and model used by the summarisation worker
- `promote_session_memory.strategies.instruct.llm.*`: promotion LLM provider key, credentials, and model
- `promote_session_memory.strategies.*.promotion_deduplication_window`: optional per-strategy window for batching rapid session writes into one promotion job; defaults to `5m`; set to `0s` for immediate promotion
- `client_pool.max_size`: connection pool size for higher concurrency
- `dataplane_client.base_url`: worker to server callback URL

### MemoryETL document extraction

MemoryETL accepts UTF-8 text or Markdown through the document-ingestion REST API.
Create a store custom memory type and an Extractor before submitting a document.
Each request supplies the Extractor ID, document ID, revision, and idempotency key.
The accepted run snapshots the extraction configuration. Source bytes are temporary;
the extracted memories and source references remain after cleanup.

The feature is disabled when `document_ingestion` is omitted. With
`config.render: true`, configure it under `memory` in Helm values; the server and worker receive
the same settings:

```yaml
memory:
  document_ingestion:
    enabled: true
    max_decoded_bytes: 1048576
    max_input_tokens: 8000
    max_chunks: 32
    max_output_records: 100
    max_queued_bytes_per_store: 10485760
    max_retries: 3
    max_execution_seconds: 900
    source_retention_seconds: 86400
    checkpoint_retention_seconds: 86400
  background_jobs:
    redis:
      jobs:
        document-ingestion:
          concurrency: 1
          timeout: 15m
          max_retry: 3
```

For a BYO config Secret, put `document_ingestion` at the application config root.
Use the existing custom-extraction inference provider configuration and credential
overlay. All numeric limits must be positive when enabled. The input-token limit
uses a four-bytes-per-token estimate; both the byte limit and chunk limit apply.
Keep job retries and timeout aligned with the ingestion limits. Set `enabled: false`
to reject new ingestion operations.

Store provisioning adds the source-link search index and missing compatible fields
without removing existing records. Store health reports incompatible index schemas;
provisioning leaves those indexes intact.

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
  -f base-values.yaml -f region-eu.yaml \
  --set image.tag=<RAM_VERSION> --set controlplane.image.tag=<RAM_VERSION>

helm install ram-us redis-ai/redis-agent-memory \
  -f base-values.yaml -f region-us.yaml \
  --set image.tag=<RAM_VERSION> --set controlplane.image.tag=<RAM_VERSION>
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

Each regional overlay supplies `metadata.urls`, `databases.<id>.urls`, and job
Redis URLs. Stores are created through the bundled Control Plane and become
visible to the Data Plane through the shared metadata namespace.

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

## Bundled Control Plane

The chart always deploys the on-prem **Control Plane (CP)** — an admin API
(`/iris/v1/agent-memory/stores`, admin-token authenticated) that creates and manages memory stores
at runtime, so you can provision stores without editing the data plane's config
and rolling its pods. DP-only and externally managed CP topologies are not
supported.

The chart adds `redis-agent-memory-controlplane`
(Service on port `9100`), alongside the server and worker. The CP writes store
metadata to a **metadata Redis** and provisions each store's RediSearch indexes
in the **store database** at create time. The data plane reads the records from
the same metadata Redis. Store create and update requests can also set
`longTermMemoryExclusions` for sensitive-data filtering — the advisory semantic
prompt, the deterministic built-in detectors, and customer-authored custom
detectors, each independently toggleable. `GET /iris/v1/agent-memory/detectors` lists the built-in
detector ids a store may select, so an id never has to be copied from
documentation.

### Control plane Secrets

The CP needs three Secrets in addition to the license Secret it shares with the
server and worker:

- a **config Secret** with key `controlplane-onprem.config.yaml` (the CP config file)
- an **admin-token Secret** — either bring your own (`controlplane.adminToken.existingSecret`),
  or let the chart lookup-or-generate one on first install
  (`controlplane.adminToken.autoGenerate`, the default). A generated token is kept
  stable across upgrades and is never clobbered by a manual edit.
- an **internal-token Secret** for RAM CP internal validation, configured via
  `controlplane.internalToken.*`. It must be distinct from the admin-token Secret/key.
  The Identity Service release presents it to the control plane's grant
  validator, so in production set `controlplane.internalToken.existingSecret` to
  the Secret both releases reference; see
  [Connecting to the Identity Service](#connecting-to-the-identity-service).

> **Upgrading an existing install:** the internal token is optional. A config that
> carries only `auth.admin_token` keeps starting unchanged. The control plane
> refuses each request to the `/internal/v1/grants/validate` route with 401. Add `auth.internal_token` only when you connect an Identity Service
> release and want it to validate grants against this control plane. If you manage the CP
> config yourself through `controlplane.config.existingSecret`, adding the token to
> chart values is not enough: the config file must also point at the mounted path
> (`token_file: /etc/controlplane-onprem/internal/token`).

```sh
kubectl -n <namespace-name> create secret generic ram-controlplane-config \
  --from-file=controlplane-onprem.config.yaml=./controlplane-onprem.config.yaml
```

If you want to **bring your own admin token** (instead of letting the chart
generate one), create its Secret too and disable auto-generation in your values.
Do the same for the internal token if you do not want the chart to generate it:

```sh
kubectl -n <namespace-name> create secret generic ram-controlplane-admin-token \
  --from-literal=token='<your-admin-token>'

kubectl -n <namespace-name> create secret generic ram-controlplane-internal-token \
  --from-literal=token='<your-internal-token>'
```

```yaml
controlplane:
  adminToken:
    existingSecret: ram-controlplane-admin-token
    secretKey: token          # must match the --from-literal key above
    autoGenerate: false
  internalToken:
    existingSecret: ram-controlplane-internal-token
    secretKey: token
    autoGenerate: false
```

The Secret key must equal `controlplane.adminToken.secretKey` (default `token`),
and it is always mounted at `/etc/controlplane-onprem/admin/token` — so the CP
config's `auth.admin_token.token_file` must point there. Rotate the token by
editing this Secret; the control plane reads it on use, so no redeploy is needed.
The internal token follows the same rules with `controlplane.internalToken.secretKey`
and is mounted at `/etc/controlplane-onprem/internal/token`.

#### Sourcing these Secrets from the Secrets Store CSI Driver

If you provision the config / admin-token / internal-token / license Secrets through the Secrets
Store CSI Driver, use its **sync-to-Kubernetes-Secret** feature
(`SecretProviderClass.secretObjects`) and point `controlplane.config.existingSecret`,
`controlplane.adminToken.existingSecret`, `controlplane.internalToken.existingSecret`,
and `license.existingSecret` at the synced Secret names — the chart consumes them
like any other `existingSecret`.

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
  internal_token:
    token_file: /etc/controlplane-onprem/internal/token

# Enterprise license — the chart mounts the same license Secret as the
# server/worker at {license.mountDir}/{license.fileName}.
license:
  license_path: /etc/redis-agent-memory/license

# Store-metadata Redis: where store records are persisted, under this key
# namespace. Must match the data plane's metadata.namespace.
metadata:
  urls:
    - redis://redis-meta:6379

# Store database registry: the unchanged create API selects ID "1" and persists
# this name and URL snapshot with each store.
databases:
  "1":
    name: default
    # Optional metric attribution; each omitted value defaults to "1".
    account_id: "12345"
    subscription_id: "67890"
    urls:
      - redis://redis-store:6379

# Embedding vector size used to size the long-term-memory index at create time.
# Must match the data plane's embedding.models.dimensions.
embedding:
  dimensions: 3072
```

### Configure it

Add to your `ram-values.yaml`:

```yaml
controlplane:
  image:
    repository: redislabs/agent-memory-control-plane
    tag: "<ram-version>"
  config:
    existingSecret: ram-controlplane-config
    existingSecretChecksum: "<controlplane-config-checksum>"
  # Auto-generate the admin token on first install (default). To bring your own,
  # set adminToken.existingSecret and adminToken.autoGenerate: false. The internal
  # validation token has the same defaults under internalToken.
  adminToken:
    autoGenerate: true
  internalToken:
    autoGenerate: true
```

Retrieve the auto-generated admin or internal token (the exact commands are also
printed in the `helm status` / `NOTES.txt` output):

```sh
kubectl -n <namespace-name> get secret \
  redis-agent-memory-controlplane-admin-token \
  -o jsonpath='{.data.token}' | base64 -d

kubectl -n <namespace-name> get secret \
  redis-agent-memory-controlplane-internal-token \
  -o jsonpath='{.data.token}' | base64 -d
```

Rotate it by editing that Secret — the CP reads the token on use, so no redeploy
is needed.

## Connecting to the Identity Service

The **Iris Identity Service (IdS)** mints agent keys and answers the data
plane's introspection calls. This chart deploys none: install the
[`iris-identity-service`](../../identity-service/helm/README.md) chart as its
own release, then connect this release to it. The minimum Identity Service
chart version validated with this chart is `0.10.0`.

Neither chart reads the other's values or checks them against its own. Keeping
the two releases consistent is the deployment automation's job. The end-to-end
KinD harness (`task test:identity:integration FLOW=memory`; see
[the harness README](../../tests/kind/README.md)) proves that a consistent pair works;
`helm test` does not.

### Running under redis-iris

When the chart runs as the `memory` dependency of the `redis-iris` umbrella
(`global.iris` is set), both Identity Service credentials come from the suite:
the supplied aggregate Secrets, or else the umbrella's generated Secrets for
Memory. Each Deployment mounts only Memory's key:

| Reference | Secret | Key |
| --- | --- | --- |
| `identityService.credential` | `global.iris.secrets.dataplaneServiceCredentials.existingSecret`, generated `iris-memory-dataplane-credential` | `memory-dp` |
| `controlplane.internalToken` | `global.iris.secrets.controlplaneInternalTokens.existingSecret`, generated `iris-memory-internal-token` | `memory` |

The chart generates no internal token then. Leave both `existingSecret` values
empty: one naming another Secret fails the render and names the field.

The suite-wide settings also come from `global.iris` (TDD MOD-19479, "Values
precedence"):

| Value | Under redis-iris |
| --- | --- |
| `tenantId` | `global.iris.tenantId` (default `default`). With `global.iris.auth.oidc.tenantIdClaim`, no tenant |
| `license.existingSecret`, `license.secretKey` | `global.iris.license.*` (defaults `iris-license`, `license.key`) |
| `auth.oidc.audience` | `global.iris.auth.oidc.audience` (default `api://redis-iris`) |
| `dataplane.identityServiceBaseURL`, `identityService.allowInsecureTransport` | the suite's Identity Service, `http://iris-identity-service.<namespace>.svc.<clusterDomain>:9200` |
| `controlplane.configData.auth.oidc` | `global.iris.auth.oidc` (issuer = access-token issuer) with `role_mappings` from `global.iris.auth.roleBindings` for `agent_memory`, only when an issuer is set. `tenant_id_claim` is `global.iris.auth.oidc.tenantIdClaim` |
| `memory.auth.oidc` `enabled`, `issuer`, `jwks_uri`, `role_claims`, `role_mappings`, `tenant_id_claim`, `allow_insecure_transport` | The suite enables data-plane OIDC when `global.iris.auth.oidc.issuer` is set, using the same IdP settings as the control plane. `tenant_id_claim` is `global.iris.auth.oidc.tenantIdClaim`, and a local `static_tenant_id` with it fails the render. `role_mappings` come from `global.iris.auth.roleBindings` for `agent_memory`. A different local value fails the render. Enabled OIDC without an issuer or `jwks_uri` also fails, standalone too; with `config.existingSecret`, supply the OIDC block in that Secret |
| `workerAuth.enabled`, `memory.dataplane_client`, `memory.auth.worker_identity` | the worker's projected ServiceAccount token, trusted against `global.iris.workloadIdentity` for subject `system:serviceaccount:<namespace>:<worker ServiceAccount>` |

Leave these unset: a value that differs fails the render and names the field.
Without `global.iris` nothing changes.

### Two-step install

The tested layout puts both releases in one namespace, because both mount the
shared Secrets. With the two Secrets from [Required Secrets](#required-secrets)
and the Identity Service metadata Secret in place:

1. Install the Identity Service release with the Memory entries from
   [Product contracts](#product-contracts):

   ```bash
   helm install iris-identity-service redis-ai/iris-identity-service \
     --namespace <namespace-name> -f values-ids.yaml
   ```

2. Install this chart with the connection values:

   ```yaml
   tenantId: default
   dataplane:
     identityServiceBaseURL: http://iris-identity-service:9200
   identityService:
     # The in-cluster Service speaks http; refused under fips.
     allowInsecureTransport: true
     credential:
       existingSecret: memory-dp-credential
   controlplane:
     internalToken:
       existingSecret: memory-internal-token
   ```

[`examples/basic/values.yaml`](examples/basic/values.yaml) is a complete values
file for this layout.

### Connection values

| Key | Default | Purpose |
| --- | --- | --- |
| `dataplane.identityServiceBaseURL` | `""` | The Identity Service release's Runtime URL the data plane introspects against. Must be `https://` unless `identityService.allowInsecureTransport=true`. |
| `identityService.allowInsecureTransport` | `false` | Accept an `http://` URL, for example the in-cluster Service. Refused under the fips profile. |
| `identityService.credential.existingSecret` | `""` | The data plane's runtime credential (`memory-dp`), mounted at `/etc/identity-service/runtime/memory-dp/token`. |
| `identityService.credential.secretKey` | `token` | Key in that Secret. |
| `identityService.credential.existingSecretChecksum` | `""` | Set to roll the data plane when the Secret's content changes. |
| `controlplane.internalToken.existingSecret` | `""` | The control plane's internal token, which the Identity Service release presents to the grant validator. |

The URL and credential are required with `config.render=true` and agent-key
auth: `memory.auth.method: agent_key` or `memory.auth.agent_keys.enabled: true`,
or an unset method with no other auth flavour (SM Cloud, OIDC, worker identity, service
subjects, `jwt_subjects`) enabled, which the data plane then
defaults to `agent_key`. In that case the chart owns
`memory.auth.agent_keys.introspection.base_url`, `credential` and
`allow_insecure_transport`, and refuses values set for them by hand, in
`memory.auth` or in `shared.auth`, which merges under it. The rest of
that block, such as the [cache settings](#introspection-cache), passes through.
With `config.existingSecret`, write the introspection block into your config
file yourself.

`identityService.*` no longer holds Identity Service values: the schema rejects
any key other than `allowInsecureTransport` and `credential`, and rejects
`identityService.enabled` and `externalIdentityService`.

### Secret ownership

A Secret that both releases mount is owned by deployment automation and
reaches each chart as `existingSecret` + `secretKey`.

| Secret | Who owns it | Memory value | Identity Service value |
| --- | --- | --- | --- |
| Data-plane runtime credential (`memory-dp`) | Deployment automation | `identityService.credential.existingSecret` | `runtime.serviceCredentials[].existingSecret` |
| Control-plane internal token | Deployment automation (this chart generates `<fullname>-controlplane-internal-token` in development only) | `controlplane.internalToken.existingSecret` | `productValidation.products.memory.credential.existingSecret` |
| Identity Service metadata Redis config | You | None | `metadata.existingSecret` |
| Identity Service Control token | The Identity Service release, or you | None | `control.*` |

[Required Secrets](#required-secrets) has the `kubectl create secret` pair for
the two shared Secrets. Keep every token distinct: the internal token must not
reuse the control plane's admin token, and no Secret/key pair may be shared
between the Identity Service's control token, runtime credentials and validator
credentials.

### Product contracts

This mirrors "Product contracts" in the
[Identity Service chart README](../../identity-service/helm/README.md#product-contracts).
The addresses assume this chart's default `fullnameOverride: redis-agent-memory`
and an Identity Service release named `iris-identity-service`. After changing
either, or a Service port, restate them on both releases.

| Set on this release | Value | Matching Identity Service value |
| --- | --- | --- |
| `dataplane.identityServiceBaseURL` | `http://iris-identity-service:9200` (the release's Service on its `service.port`, default `9200`) | None |
| `identityService.credential.existingSecret` + `secretKey` | The data plane's runtime credential | `runtime.serviceCredentials[]` entry `name: memory-dp`, `subject: memory-dp`, `allowedOperations: [api-key-introspect]`, `allowedProducts: [memory]`, the same `existingSecret` + `secretKey` |
| `controlplane.internalToken.existingSecret` + `secretKey` | The control plane's internal token | `productValidation.products.memory.credential` |
| `controlplane.service.port` | `9100` | `productValidation.products.memory.baseURL`: `http://redis-agent-memory-controlplane:9100` |
| `tenantId` | `default` | `runtime.apiKeyTenant.singleTenantID` |
| None | | `runtime.unscopedGrantsProduct: memory` |

The matching Identity Service values:

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

The Identity Service asks the control plane to validate every grant before it
persists a key, at `/internal/v1/grants/validate`, presenting the internal
token. With `controlplane.config.render=true` the chart adds
`auth.internal_token.token_file: /etc/controlplane-onprem/internal/token` to
the rendered control-plane config. With `controlplane.config.existingSecret`,
include that setting in your config Secret.

`runtime.unscopedGrantsProduct: memory` decides which product inherits grants
written before grants carried an explicit product. Every API key minted before
the Identity Service has such grants, so if no product claims them they resolve
to zero product grants and the whole pre-existing key population is denied the
moment a data plane switches to introspection.

Every agent key carries a tenant. With `tenantId` set, set the Identity Service
release's `runtime.apiKeyTenant.singleTenantID` to the same value; stores
created with the admin token also belong to `tenantId` (the control plane's
`auth.admin_tenant_id`). Neither chart can check that the two values match.

### Cross-namespace

The Identity Service release can run in another namespace. Then:

- point `dataplane.identityServiceBaseURL` at its fully qualified Service, for
  example `http://iris-identity-service.<identity-service-namespace>.svc:9200`;
- set its `productValidation.products.memory.baseURL` to
  `http://redis-agent-memory-controlplane.<namespace>.svc:9100`;
- provision both shared Secrets with the same values in both namespaces, since
  a Pod mounts Secrets only from its own namespace;
- allow the Identity Service pods to reach the control plane on port `9100`
  (see [NetworkPolicy reference](#networkpolicy-reference)) and, if you
  restrict egress, the data plane to reach the Identity Service.

The KinD harness tests the same-namespace layout only.

### GitOps

`helm template` (and Argo CD or Flux, which render the same way) has no cluster
access, so the lookup that keeps a generated token across upgrades finds
nothing and every sync mints a new admin or internal token. Under GitOps,
deployment automation creates the Secrets out of band (for example with Sealed
Secrets or External Secrets): set `controlplane.internalToken.existingSecret`,
`controlplane.adminToken.existingSecret` and
`identityService.credential.existingSecret`, and reference the shared Secrets
from the Identity Service release too.

### FIPS and TLS trust

Under the fips profile the data plane's Identity Service hop must be TLS, with
no opt-out: `dataplane.identityServiceBaseURL` must be `https://` and the chart
refuses `identityService.allowInsecureTransport=true`. Neither chart terminates
TLS; put a mesh, gateway or TLS-terminating proxy in front of the Identity
Service. The data plane trusts `tls.caCertSecret` (or `global.tls.caCertSecret`)
for that URL, on top of the system CAs.

The validator hop is configured on the Identity Service release: under fips its
`productValidation.products.memory.baseURL` must be an `https://` control-plane
endpoint (the service refuses to start otherwise), trusted through that
release's own `tls.caCertSecret`. Set `security.profile` (or
`global.security.profile`) on both releases.

### Upgrading from `0.0.x`

`helm upgrade` from a `0.0.x` chart, which bundled the Identity Service, is
unsupported. The following manual migration is untested guidance:

1. Preserve the `memory-dp` runtime credential's value. A chart-generated one
   lives in `redis-agent-memory-identity-service-runtime-memory-dp`, key
   `token`. Preserve the control plane's internal token
   (`redis-agent-memory-controlplane-internal-token`) the same way.
2. Hand both values to deployment automation, which creates the shared Secrets
   from [Required Secrets](#required-secrets) with them.
3. Install the Identity Service release with those Secrets registered as in
   [Product contracts](#product-contracts), pointing `metadata.existingSecret`
   at the same metadata Redis (and key namespace) the bundled service used so existing agent keys
   keep working.
4. Uninstall the `0.0.x` release, delete the bundled Identity Service resources
   Helm keeps (the `redis-agent-memory-identity-service-*` Secrets), and install
   this chart with the connection values.
5. Keep the tenant your existing stores and keys use. A `0.0.x` control plane
   created admin-token stores under the tenant `"1"`, whatever `tenantId` said;
   this chart creates them under `tenantId`. Set `tenantId` and the Identity
   Service release's `runtime.apiKeyTenant.singleTenantID` to the tenant of the
   existing stores, or migrate the metadata first (see the
   [agent-key tenant migration runbook](../../docs/runbooks/mod-18393-agent-key-tenant-migration.md)).
   Otherwise existing stores drop out of the admin listing and new keys for
   them are refused.

### Introspection cache

The data plane caches each introspection result and bounds how often it may
consult IdS. These live in the data-plane config body rather than under
`identityService`, because they tune the data plane, not the service:

```yaml
memory:
  auth:
    agent_keys:
      introspection:
        cache:
          # Repeat presentations of one rejected key are answered from cache.
          negative_ttl: 30s
          # Pause refreshes after IdS fails, so an outage is not amplified.
          failed_refresh_backoff: 30s
          # Ceiling on distinct rejected keys forwarded to IdS per window, so a
          # spray of random iris_ strings cannot become one IdS call each.
          miss_rate_limit_window: 1s
          max_misses_per_window: 64
```

Only keys IdS *rejects* count against `max_misses_per_window`. Successful
introspections never consume the budget, so a cold start or a burst of new keys
does not trip it — but while the budget is exhausted, uncached keys fail closed
with `503` for the remainder of the window. Raise the ceiling if a deployment
legitimately sees more than 64 failed authentications per second per data-plane
pod.

Every cache here is per-pod: the positive cache, the negative cache, and the
miss budget all live in the data-plane process and are never shared. Two
consequences follow when `server.replicaCount` is greater than one.

Introspection load on the Identity Service scales with replicas — the worst case
is `max_misses_per_window` x replicas per window, not `max_misses_per_window`.
Size the Identity Service against that product, not against a single pod.

Revocation also lands per pod. After a key is revoked, pods that already hold it
keep honouring it until their own entry expires, so different replicas can
briefly disagree. `negative_ttl` and the positive TTL
(the Identity Service release's `runtime.cache.hardTtlSeconds`) bound that window; they do not
synchronise it.

### Pair the data plane with the control plane

The data plane uses the same metadata Redis, namespace, and database registry.
It defaults to `auth.method: agent_key`. The data plane accepts
`auth.method: none` only with `profile: dev`, so use it only for development:

```yaml
metadata:
  urls:
    - redis://redis-meta:6379    # the same metadata Redis the CP writes to
  namespace: iris:memory         # must match the CP's metadata.namespace

# Fallback only for legacy/malformed store records; use the same registry as the CP.
databases:
  "1":
    urls:
      - redis://redis-store:6379
```

Each store record carries its persisted `databaseId` and
`databaseUrls`; valid persisted URLs are authoritative. The `databases` map is
consulted by ID only when those URLs are missing or malformed. The records carry
no embedding, so the data plane **completes** each resolved store from its own
config, and the long-term-memory
embedding comes from **two separate blocks** that play different roles:

- **`embedding:`** — the embedding **selection**. Despite being typed as a general
  `llm.Config`, the data plane reads only three fields from it and
  stamps them onto every store: `provider`, `models.default_embedding_model`, and
  `models.dimensions`. **It is required — the data plane refuses to
  start without `default_embedding_model` and a non-zero `dimensions`.**
- **`embedders_connection_details:`** — the actual embedder **endpoint +
  credentials**, looked up by the `provider` name from the `embedding:` block.

```yaml
metadata:
  urls:
    - redis://redis-meta:6379    # the same metadata Redis the CP writes to
  namespace: iris:memory         # must match the CP's metadata.namespace

databases:
  "1":
    urls:
      - redis://redis-store:6379    # fallback for invalid persisted URLs

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

Static configuration keys (`metadata.source`, `metadata.stores`, and
`metadata.live`) are rejected at startup with migration guidance. Create stores
through the bundled Control Plane; there is no automatic import or adoption of
static store IDs or data.

### Operator SSO on the data plane

The suite enables OIDC on both planes when an IdP issuer is set. Standalone
installations must enable it explicitly. The on-prem data plane validates the
token's signature, issuer, audience, and expiry. With an explicit
`auth.oidc.static_tenant_id`, that tenant must match `auth.admin_tenant_id`.
Mapped human viewers receive store read access, operators receive data read/write
access, and `product_admin` or `suite_admin` users receive full `mem-store:*`
access within that tenant. Shared configuration, including global namespace
routing, still requires an admin role. Kubernetes ServiceAccounts and configured
machine subjects cannot gain these human console grants.

Claim-based OIDC (`auth.oidc.tenant_id_claim`) keeps its existing tenant resolution
and role/grant policy. It does not receive these automatic console grants.

Store tenant and personal-record ownership checks still apply. Full store
grants do not let an admin read another user's personal records. The shared
admin token has no user ID and cannot access personal records when ownership
enforcement is enabled. Enabling OIDC keeps agent keys, worker identities, and
the local admin token available.

The admin token is a shared recovery credential for both the control plane and
the authenticated data plane. A store without an owning tenant can still appear
in the control-plane list, but data-plane access with this token is denied, so
the Inspector cannot open it. Development installations with `auth.method: none`
remain open; the chart does not inject an admin-token requirement into that mode.

The following is a data-plane application configuration fragment. With
`config.render=true`, place it under `memory:` in Helm values (for example,
`memory.auth.oidc.enabled`). With `config.existingSecret`, place it at the root
of the data-plane configuration file in that Secret instead. For this Helm
example, also set top-level `tenantId: default` so the CP and DP use the same
tenant.

```yaml
auth:
  admin_tenant_id: default
  oidc:
    enabled: true
    issuer: https://idp.example.com/tenant
    jwks_uri: https://idp.example.com/tenant/discovery/v2.0/keys
    static_tenant_id: default
    role_mappings:
      memory-admins: product_admin
```

`issuer` may be `http://` or `https://`: it is an identifier compared with the
token's `iss` and never fetched, so an `http://` issuer needs no
`allow_insecure_transport` and is accepted under the FIPS profile. On AD FS set it
to the discovery document's `access_token_issuer`
(`http://<host>/adfs/services/trust`). `jwks_uri` is fetched, so it must stay
`https://`. The chart does not validate the issuer scheme; the data plane does at
startup.

`role_mappings` is required, not decorative. The role gate runs before the
grant check, and a role-claim value (read from `role_claims`, default
`[roles, groups]`) confers an Iris role only through an explicit mapping,
matched case-insensitively. Without one, every federated caller is roleless and
is refused at the role gate with the same `403` a missing grant produces. The
on-prem data plane rejects `allow_unmapped_roles` and `oidc_role_only` for
static-tenant console grants, which require explicit role mappings and resource grants. Mapping keys
that are equal ignoring case (`admins` and `Admins`) are refused at startup.

Every agent key carries a tenant. For a single-tenant installation, set
`tenantId`. The Identity Service then stamps it on each grant that has no tenant
when you create or change a key, and it rejects a grant that names another tenant.
Stores created with the static admin token also belong to `tenantId`: the chart
renders it as the control plane's `auth.admin_tenant_id`, and a differing
`controlplane.configData.auth.admin_tenant_id` fails the render. With no
`tenantId`, tenant claim, or explicit admin tenant, admin-token stores keep the
deprecated tenant `"1"` so existing 0.0.x stores retain their owner.

In the multi-tenant mode, `tenant_id_claim` names the tenant of each caller.
Then, when `auth.admin_tenant_id` is not set, admin-token stores belong to the
system tenant `_system`. No IdP can name that tenant, so no tenant user sees
those stores. Each plane gets this tenant from its own `auth.oidc`. So when the
data plane uses the admin token, set `tenant_id_claim` on both
`controlplane.configData.auth.oidc` and `memory.auth.oidc`, or set
`controlplane.configData.auth.admin_tenant_id`. If not, the render fails.

Upgrade note: before this change, a release with `tenant_id_claim` and no
`auth.admin_tenant_id` kept admin-token stores in tenant `"1"`. After the
upgrade, new admin-token stores go to `_system`, and the data-plane admin token
can no longer use stores in the old tenant. To retain that access, set
`controlplane.configData.auth.admin_tenant_id: "1"` before the upgrade.
Use this only if tenant `"1"` is the intended owner; its IdP users can access
those stores.

An IdP user sees only the stores of its own tenant, also with `suite_admin`.
Only the static control-plane admin token sees the stores of all tenants.
An IdP admin sees admin-token stores only when those stores belong to its own
tenant. Use the IdP token to create stores for that tenant.

For a multi-tenant installation, leave `tenantId` empty and configure the
Identity Service release's `controlAuth.oidc` with a `tenant_id_claim`. Each
grant then names its tenant. Under the `redis-iris` umbrella, set
`global.iris.auth.oidc.tenantIdClaim` instead: the umbrella then leaves
`tenantId` empty and sets `tenant_id_claim` on the Identity Service and on this
chart. A control OIDC with only a `static_tenant_id` also
renders: operator tokens carry that tenant, and the admin token must name a
tenant on each write. The Identity Service chart does not render with none of
these.

Configure exactly one tenant source. `static_tenant_id` declares a single-tenant
deployment; alternatively use `tenant_id_claim` to resolve the tenant from the
validated token. Configuring both is rejected instead of silently overriding
the claim. Claim-based resolution rejects a missing tenant and still requires
resource ownership and grants; it does not by itself establish multi-tenant
support. For an older configuration containing both fields, choose the intended
tenant source explicitly before upgrading. Static assignment must not be used
for a multi-tenant deployment.

**RAM DP ownership check:** the resolved tenant string (static or
claim-derived) must be equal to the `TenantID` of the store. The match is exact.
Only a legacy store with no `TenantID` falls back to its numeric account ID in
decimal form.
During the preview, both missing grants and a tenant mismatch result in `403`.

#### Token audience

> **Upgrading with OIDC enabled.** The default audience is `api://redis-iris`.
> If your IdP issues another audience, such as `api://memory-dp`, set
> `auth.oidc.audience` to it and remove `audience` from `memory.auth.oidc` and
> `controlplane.configData.auth.oidc`; a different `audience` there fails the
> render. With `config.existingSecret` the chart cannot check the file: set its
> `audience` to match the IdP.

The accepted audience is the chart value `auth.oidc.audience`, next to the issuer
and claim settings. It defaults to `api://redis-iris`, the single Iris API
audience shared by every Iris service that validates IdP tokens, and it is the
value the IdP must put in the access token's `aud`:

| IdP | `auth.oidc.audience` |
|---|---|
| Okta, Auth0, Keycloak, PingFederate, AD FS | the audience or API identifier you configured, for example `api://redis-iris` |
| Entra ID, v2 tokens | the API's Application (client) ID GUID |
| Entra ID, v1 tokens | the Application ID URI, for example `api://redis-iris` |

Use the same value in every Iris chart. The UI sign-in setting for it arrives with the UI sign-in work (MOD-19450).

- With `config.render=true` and `controlplane.config.render=true`, the chart sets
  the value as `audience` of every enabled `auth.oidc` block, in the data-plane
  and control-plane config. There is no per-service override: an `audience`
  already written in those blocks (for example `memory.auth.oidc.audience`) must
  equal `auth.oidc.audience`, otherwise the render fails and names the conflict.
  The chart refuses a blank or wildcard value.
- With `config.existingSecret` or `controlplane.config.existingSecret`, the chart
  cannot add it. Set the same value as `audience:` in the `auth.oidc` block of
  each file, as a one-element list.
- Every Iris service (data plane and control plane) accepts exactly one configured
  audience. A token whose `aud` is a list is accepted when it contains that value.
- The Identity Service release's `controlAuth.oidc` keeps its own audience, but like every
  control plane it may list only one non-wildcard value. `auth.service_subjects`
  is not affected. `auth.service_subjects.audience` stays `api://memory-dp`: it is the
  audience of the worker's projected ServiceAccount token, not of the IdP, and
  other charts reference it (Playbook's `worker.sourceTokenAudience`).

Tokens must carry the configured audience; additional audiences in a token's
`aud` list do not matter, but the configuration may name only one. `allow_azp_fallback` is rejected at
startup: `azp` identifies a client, not the resource API.

**JWKS egress and failures.** Permit outbound access to the configured JWKS
endpoint. JWT signatures are checked locally against cached keys, without
agent-key introspection. An unavailable required key fetch returns `503`;
an invalid, expired, wrong-issuer, or wrong-audience token returns `401`.
Successfully authenticated resource requests without a grant return `403`.
After a successful fetch, failed refreshes can reuse cached JWKS indefinitely:
the current cache has no hard maximum age. Removing a signing key at the IdP
therefore does not reliably revoke trust during an outage, although each token
must still pass expiry and other JWT checks.

**Revocation has separate bounds.** Agent-key revocation and grant edits reach
each DP pod by its cached snapshot's hard expiry, not necessarily on the next
request. Offline IdP validation cannot observe upstream account/client
disablement or token revocation before the token's accepted expiry, including
configured clock skew. Future subject-grant snapshots must independently bound
grant deletion and binding changes by their hard TTL; that grant-resolution
path is not shipped by this preview. Neither credential type guarantees
immediate revocation.

See the [authentication support matrix](../../docs/specs/identity-service/product-authentication-support.md)
for product and deployment coverage.

## Redis client certificates

Use this when your Redis Enterprise database requires a client certificate:
mTLS (mutual TLS), or certificate-only login with no password. The
server, worker and control plane present the certificate on every `rediss://` connection. The full
setup, rotation and CA (certificate authority) rotation steps are in the
[Redis client certificate runbook](../../docs/runbooks/iris-onprem-redis-mtls.md).

```yaml
redisClientTLS:
  existingSecret: redis-client-cert        # Secret with tls.crt and tls.key
  extraCertificates:                       # optional, per connection
    - name: store-1
      existingSecret: redis-client-cert-store-1
```

- The chart projects every Secret into one read-only volume at
  `/etc/redis-client-tls`, without `subPath`: the default pair at
  `/etc/redis-client-tls/tls.crt` and `tls.key`, an extra one at
  `/etc/redis-client-tls/<name>/tls.crt` and `tls.key`.
- The chart renders `redis_client_tls` with the default pair's paths into the
  service config. When the config comes from your own Secret (`config.existingSecret` or
  `controlplane.config.existingSecret`), the chart cannot change it: add

  ```yaml
  redis_client_tls:
    cert_path: /etc/redis-client-tls/tls.crt
    key_path: /etc/redis-client-tls/tls.key
  ```

  to that config yourself.
- An extra certificate is used by a connection block that names it in its own
  `tls:` block (`cert_path`, `key_path`). A `tls:` block on a `redis://` URL
  stops the service at startup.
- Certificate-only login: use a `rediss://` URL with no user name or password.
  With a password in the URL, the service sends both (mTLS plus password).
- Rotation: update the Secret. The service rereads the files about every 30
  seconds and uses the new pair for new connections, without a restart. A
  broken pair keeps the last good one and increments
  `iris.redis.client_certificate.reload_failures`.
- Server trust stays on `tls.caCertSecret`.

- The queue monitor (Asynqdash) has no client certificate: it does not work
  with a Redis that requires one.

## Queue Monitor (optional)

The chart can optionally deploy **Asynqdash** for low-frequency inspection of the
RAM async queues backed by `background_jobs.redis`. It is disabled by default
(`controlplane.queueMonitor.enabled=false`) and is specific to the supported
Redis queue backend.

When enabled, the chart adds a separate low-resource Deployment,
`redis-agent-memory-asynqdash`, plus a ClusterIP Service. If
`controlplane.queueMonitor.ingress.enabled=true`, it also renders a dedicated
host Ingress, for example `ram-jobs.example.com`, protected by ingress Basic
Auth. The chart does not generate or transform Secrets for this monitor.

Upgrading from a chart that shipped `hibiken/asynqmon` (1.0.0): the Deployment,
Service and Ingress are renamed from `<fullname>-asynqmon` to `<fullname>-asynqdash`,
and the container from `asynqmon` to `asynqdash`. `<fullname>` is the
`fullnameOverride` value: `redis-agent-memory` by default and in the `redis-iris`
umbrella chart, whatever the release name. `helm upgrade` replaces the
Deployment and Service by itself. **With
`controlplane.queueMonitor.ingress.enabled=true`, delete the old Ingress first.**
Helm creates the renamed Ingress before it deletes the old one, and the
ingress-nginx admission webhook rejects a second Ingress on the same host and
path, so the upgrade fails. Select the Ingress by its labels, which both chart
versions set, so you do not need its name:

```bash
kubectl -n <namespace-name> delete ingress \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=queue-monitor
helm upgrade <release> ...
```

Before `helm rollback` to a revision that shipped `hibiken/asynqmon`, run the
same `kubectl delete` to remove `<fullname>-asynqdash`. The queue monitor UI is
unreachable from the delete until the upgrade or rollback completes; the RAM
workloads are not affected. Your existing Secrets keep working. Update any NetworkPolicy,
monitoring rule or script that matches the old names.

### Queue monitor Secrets

Create a Redis connection Secret that points at the same Redis endpoint used by
`background_jobs.redis.urls`:

```sh
kubectl -n <namespace-name> create secret generic ram-job-redis \
  --from-literal=REDIS_URL='rediss://:<password>@<job-redis-host>:6379/0'
```

A `rediss://` URL verifies the certificate against `<job-redis-host>`. The
optional `REDIS_TLS` key sets the TLS server name: Asynqdash verifies that name
instead of the URL host for a `rediss://` URL, and turns TLS on for a `redis://`
URL. When the certificate does not cover the connect host (for example the Redis
Enterprise default certificate), add `REDIS_TLS='<covered name>'` to either URL. A `redis://` URL without `REDIS_TLS` connects
without TLS; use it only when your environment does not require TLS. If your environment intentionally
skips hostname verification, provide `REDIS_INSECURE_TLS=true` as a third key
and document that exception in your deployment record.

For a named Redis ACL user, add a `REDIS_USERNAME` key to the same Secret
(`--from-literal=REDIS_USERNAME='<acl-user>'`) and keep only the password in
`REDIS_URL` (`rediss://:<password>@...`). Asynqdash reads only the password
from the URL and ignores a username there. Change the key name with
`controlplane.queueMonitor.redis.usernameKey`.

Create the Basic Auth Secret separately. Ingress-nginx expects htpasswd content
under the key `auth`. Use the same password value as the control-plane admin
token, but store it in this separate htpasswd-formatted Secret consumed by the
ingress controller:

```sh
read -rs RAM_ADMIN_PASSWORD
printf '\n'
htpasswd -Bbn admin "$RAM_ADMIN_PASSWORD" > asynqdash.htpasswd
kubectl -n <namespace-name> create secret generic redis-agent-memory-asynqdash-basic-auth \
  --from-file=auth=./asynqdash.htpasswd
rm asynqdash.htpasswd
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
      repository: ghcr.io/jpedrosouza/asynqdash
      tag: 1.2.0
    redis:
      existingSecret: ram-job-redis
      urlKey: REDIS_URL
      usernameKey: REDIS_USERNAME
      tlsServerNameKey: REDIS_TLS
      insecureTLSKey: REDIS_INSECURE_TLS
    auth:
      type: basic
      existingSecret: redis-agent-memory-asynqdash-basic-auth
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
policy in front of the queue monitor Service.

### Security posture

- The monitor is opt-in and runs as an isolated Deployment, not inside the RAM
  worker.
- It is read-only by default (`READ_ONLY=true`), so Asynqdash hides and rejects
  mutating actions. Read-only mode also sets `DISABLE_THROUGHPUT_COLLECTOR=true`,
  so the monitor writes no `asynqdash:*` throughput keys to the job Redis.
- If you set `readOnly=false`, Asynqdash can mutate queues and tasks and records
  per-queue throughput in the job Redis; Basic Auth
  is then the only chart-managed access control.
- The default Service is ClusterIP. Public access should go through the
  dedicated admin host ingress or an operator-managed auth proxy.
- The default image is [Asynqdash](https://github.com/jpedrosouza/asynqdash)
  `1.2.0` (Git tag `v1.2.0`), a maintained fork of `hibiken/asynqmon` that keeps
  its flags and reads the same Asynq data in Redis. Keep the image tag pinned and
  validate it when changing the repository's Asynq version.
- The monitor presents no Redis client certificate, so it does not work with
  certificate-only Redis (see [Redis client certificates](#redis-client-certificates)).
- The image publishes `linux/amd64` and `linux/arm64` manifests from one tag. A
  private-registry mirror must copy both (`skopeo copy --all` or `crane copy`).

### Local Docker Compose

The local RAM on-prem compose stack includes Asynqdash in read-only mode against
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
| Networking | `service.type`, `ingress.*` | expose the API outside the cluster. The Ingress carries no controller annotations, so it works on any controller: set `ingress.className` to yours (default `nginx`; for example `traefik`). Earlier chart versions defaulted `nginx.ingress.kubernetes.io/rewrite-target: /`, which sent every request to `/`; remove it if your values copied it. |
| Naming | `fullnameOverride` | multiple RAM releases in one namespace |
| Service account | `serviceAccount.*` | custom namespace security policy |
| Secret rollouts | `license.existingSecretChecksum`, `config.existingSecretChecksum` | force restart after external Secret updates |
| Control plane | `controlplane.image.*`, `controlplane.config.*`, `controlplane.adminToken.*`, `controlplane.internalToken.*` | configure the bundled admin store API (see [Bundled Control Plane](#bundled-control-plane)) |
| Identity Service connection | `dataplane.identityServiceBaseURL`, `identityService.allowInsecureTransport`, `identityService.credential.*` | connect the data plane to the Identity Service release (see [Connecting to the Identity Service](#connecting-to-the-identity-service)) |
| Umbrella fallbacks | `global.security.profile`, `global.imagePullSecrets`, `global.tls.caCertSecret` | read when the local value is empty |
| Queue monitor | `controlplane.queueMonitor.*` | enable the optional Asynqdash UI for `background_jobs.redis` |
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

That overlay sets `global.security.profile=fips`; `security.profile=fips` works
the same. Set the profile on the Identity Service release too: this chart does
not configure it. The chart rejects any value other than `""` and `fips` at
install/upgrade time, so a typo like `fisp` fails loudly instead of silently
falling back to the default posture.

Under the fips profile the chart:

- sets `GODEBUG=fips140=on` on the server, worker, and control-plane containers;
- refuses an `http://` `dataplane.identityServiceBaseURL` and
  `identityService.allowInsecureTransport=true`, with no opt-out, because they
  would send agent-key material in the clear; the data plane trusts
  `tls.caCertSecret` for the `https://` URL (see
  [FIPS and TLS trust](#fips-and-tls-trust));
- surfaces the active profile in `helm status` / `NOTES.txt` output;
- lets each binary inject the effective Go runtime profile into its DI container.

When the posture is active the binary additionally refuses to start if the
mounted config:

- enables `skip_verify` on any outbound HTTP client (`dataplane_client.http_client`,
  `inference_providers.<key>.http_client`,
  `promote_session_memory.strategies.instruct.llm.http_client`,
  `promote_session_memory.strategies.custom_extraction.llm.http_client`,
  `session_summarisation.llm.http_client`,
  `session_summary_view.llm.http_client`,
  `embedders_connection_details.<key>.http_client`, `embedding.http_client`,
  `auth.oidc.http_client`, `auth.agent_keys.introspection.http_client`, or
  `auth.worker_identity.http_client`);
- sets `allow_insecure_transport` on any authentication block
  (`auth.oidc`, `auth.agent_keys.introspection`, or `auth.worker_identity`).
  That flag relaxes URL-scheme validation for the block's fetched endpoints —
  `jwks_uri`, introspection `base_url`, and the issuer of every block except
  `auth.oidc`, whose `http://` issuer is an identifier and needs no flag — so leaving it on would let bearer
  material reach the Identity Service or the IdP over plaintext HTTP. It is
  rejected even when the owning block is disabled, on the same reasoning as
  `skip_verify`: a flag left in a dormant block must not survive until someone
  enables it; or
- uses a non-`rediss://` URL for any Redis connection
  (`background_jobs.redis.urls`, `metadata.urls`, or `databases.<id>.urls`).

All violations are reported together at startup, so you never have to fix
them one restart at a time.

The control plane runs under the same `GODEBUG=fips140` contract and refuses to
start if its own Redis
URLs (`metadata.urls`, `databases.<id>.urls`) are not `rediss://`. The CP has no
outbound HTTP clients, so the `skip_verify` checks do not apply to it.

### TLS ownership

This chart does not terminate TLS on the API service itself. The server
process speaks plain HTTP on its listener. TLS at the edge is the hosting
environment's responsibility — terminate TLS at your ingress, service mesh,
or external load balancer. Outbound TLS (to Redis, to the embedding provider,
to the promotion LLM, and to the worker-to-server callback URL if you
expose it externally) is configured through the shared config file and is
what the FIPS posture enforces.

### IdP bearer-token authentication

See [Federated data-plane authentication preview](#federated-data-plane-authentication-preview)
for the current limitations, tenant configuration, audience policy, and egress requirements.

### Delegated user token (MOD-19849)

An agent can act for the user it serves. The agent sends its agent key as usual
and the access token of the user in the `X-Iris-User-Token` header. The data
plane validates the token with `memory.auth.oidc` and takes only the user ID
from it. Store access still comes from the grants of the key. With ownership
enforcement on, the agent then reads and writes the personal records of that
user.

```yaml
memory:
  auth:
    delegation:
      enabled: true   # default false; requires memory.auth.oidc.enabled
      audience:       # recommended: an audience that direct sign-in refuses
        - api://iris-delegation
```

Without `audience`, the data plane also accepts the user token as a direct
sign-in, with the access of the user. With a separate audience, a token issued
for delegation works only next to an agent key. A separate audience needs
`memory.auth.oidc.allow_azp_fallback` off.

The data plane refuses the header with any credential other than an agent key,
and refuses a user of another tenant. See
`docs/specs/MOD-19849-delegated-user-token.md` for all rules.

### Playbook extraction authentication (MOD-20121)

A fresh Playbook extraction deployment uses RAM's existing static JWT policy for
its dedicated worker. It does not create extraction IdS grants. Retain customer
agent-key auth and RAM's own promotion-worker identity separately.

```yaml
memory:
  auth:
    method: agent_key
    jwt_subjects:
      - issuer: https://YOUR-CLUSTER-ISSUER
        jwks_uri: https://YOUR-CLUSTER-JWKS
        audience: [api://memory-dp]
        subjects:
          - subject: system:serviceaccount:<namespace>:<playbook-fullname>-worker
            authority: static
            roles: [viewer]
            resources:
              "mem-store:*": {permissions: [read]}
```

Playbook CP uses a separate tenant-confined viewer for RAM CP list/get source
ownership checks. Configure the same tenant as Playbook `tenantId`; do not use
suite-admin trust, which bypasses RAM's ownership checks.

```yaml
controlplane:
  configData:
    auth:
      workload_identity:
        enabled: true
        issuer: https://YOUR-CLUSTER-ISSUER
        jwks_uri: https://YOUR-CLUSTER-JWKS
        audience: [api://memory-cp]
        subjects:
          - subject: system:serviceaccount:<namespace>:<playbook-fullname>-controlplane
            tenant: "<playbook-tenantId>"
            roles: [viewer]
```

Both RAM planes must reach the issuer/JWKS and trust its CA. Merge list entries
with existing identities instead of replacing RAM's worker/customer auth. CP
viewer trust supplies ownership proof only; Playbook independently requires the
calling installation admin or same-tenant product/suite admin to consent.
See the [Playbook chart setup](../../playbook/helm/README.md#reading-agent-memory-for-extraction-mod-20121)
for projected tokens, fixed endpoints and network requirements. Ordinary IdS service
subjects remain available for separately administered customer integrations.

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
- `<identity-service-namespace>` and `<identity-service-release-name>`: the
  namespace and release name of the separate Identity Service release this
  chart connects to

The reference policy first default-denies ingress to the chart pods, then allows
TCP traffic to the server pods on port `9000` from the worker Deployment and
from the approved caller selector. It also includes a control-plane stanza that
allows traffic to the CP pods on port `9100` from the Identity Service release's
pods, for grant validation, and from approved admin clients. Egress is not
restricted; if you add an egress policy, let the server pods reach the Identity
Service release (`dataplane.identityServiceBaseURL`, port `9200` by default).
Review it against your CNI implementation
and cluster ingress path before using it in production.

### Two control planes caveat (advanced)

The FIPS runtime posture has two stages:

1. **Build-time** (`GOFIPS140`): links the selected Go Cryptographic Module into
   the image. Each on-prem main package declares `//go:debug fips140=off`, so
   the compiled binary defaults to non-FIPS while retaining that module.
2. **Runtime** (`GODEBUG=fips140=on|off`): rendered directly by the chart from
   `security.profile`. Images default to `fips140=off`; the chart explicitly
   renders either value for every application container. Each binary reads the
   effective runtime state through Go's `crypto/fips140` package and supplies a
   typed profile through dependency injection.

Use `security.profile` as the supported FIPS control. Direct image launches use
the image's non-FIPS default unless the runtime environment explicitly overrides
`GODEBUG`.

### Verifying the posture at runtime

After install, the Deployment carries `GODEBUG` as a literal env var. You can
confirm both the chart wiring and the runtime behavior with:

```sh
kubectl -n <ns> get deploy redis-agent-memory \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GODEBUG")].value}'

kubectl -n <ns> logs deploy/redis-agent-memory | grep -i 'FIPS-oriented security profile'
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

- `GET /health/readiness`
- `POST /iris/data/v1/agent-memory/stores/{storeId}/sessions`
- `POST /iris/data/v1/agent-memory/stores/{storeId}/memories`
- `POST /iris/data/v1/agent-memory/stores/{storeId}/memories/search`

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
registry image validation, node metrics, bounded RAM server/worker/control-plane
logs, a static manifest, and Troubleshoot analyzer results. Built-in Troubleshoot
redactors and RAM-specific redactors run against the archive. It intentionally
does not collect Helm values, license contents, admin tokens, Redis keys or
values, raw Redis `INFO`, or business API calls.

The default spec also renders exact-key config value collection, in-cluster HTTP
health checks, registry image validation, Kubernetes node metrics collection,
Kubernetes node resource analyzers, and native Troubleshoot analyzers:

```yaml
supportPackage:
  registryImages:
    imagePullSecretName: regcred
```

`supportPackage.healthChecks.enabled=true` is the default and runs temporary
in-cluster `runPod` probes for server, worker, the bundled Control Plane, and
optional queue monitor health endpoints. Each probe executes the Troubleshoot
HTTP collector against `*.svc.cluster.local` and analyzes the pod log for HTTP
200. Worker checks use a support-only ClusterIP Service named
`<release>-worker-support`.

With `dataplane.identityServiceBaseURL` set, the health checks also probe that
URL's `/health/liveness` and `/health/readiness`, and the package flags Identity
Service introspection errors in the server logs. With
`identityService.credential.existingSecret` set, it checks that the Secret key
exists without collecting its value. The health check proves reachability only: the
Identity Service's readiness does not cover its metadata Redis or the grant
validator, and the package cannot check that the release registers the
`memory-dp` credential or the `memory` validator. It does not collect the
Identity Service release's logs; run that release's own diagnostics.

Redis dependency failures are covered by the service health probes and bounded
RAM logs. The support package does not run separate Redis client probes, and it
does not collect Redis keys, values, raw `INFO`, memory contents, prompts, or
provider payloads.

`supportPackage.registryImages.enabled=true` is the default and validates
chart-rendered images: server/worker/Control Plane, optional queue
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

- mirror `redislabs/agent-memory:<ram-version>` and
  `redislabs/agent-memory-control-plane:<ram-version>` into an internal
  registry, and the Identity Service image for that release
- create any required image pull Secret in the target namespace
- make sure `memory-dataplane.config.yaml` points only to endpoints reachable from inside the environment

Use the same `ram-values.yaml` approach as the standard install. Add these settings to
that file:

- `airgap.enabled: true`
- `image.repository: registry.example.com/redislabs/agent-memory`
- `image.tag: <ram-version>`
- `controlplane.image.repository: registry.example.com/redislabs/agent-memory-control-plane`
- `global.imagePullSecrets[0].name: regcred` if your registry requires an image pull Secret

With `airgap.enabled: true` the chart refuses to render while any of these
images still points at Docker Hub.

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

If your registry does not require an image pull Secret, omit `global.imagePullSecrets`.

## Health probe migration (chart 0.1.1)

The RAM control plane now serves `/health/liveness` and `/health/readiness`,
matching the data-plane probe paths. The old `/v1/health/live` and
`/v1/health/ready` URLs are removed without aliases. Readiness checks and
response bodies are unchanged.

Deploy chart `0.1.1` together with a control-plane image containing this route
change. Pair older images with their matching older charts; mixing the old and
new probe contracts makes the control-plane pod fail its probes. Update custom
monitoring and UI `healthPath` settings to `/health/readiness`. The standalone
Identity Service retains its `/v1/health/live` and `/v1/health/ready` routes.

## Verify

```sh
kubectl get pods -n <namespace-name> -l app.kubernetes.io/name=redis-agent-memory
kubectl port-forward -n <namespace-name> svc/redis-agent-memory 9000:9000
curl http://localhost:9000/health/liveness
```

If the control plane is enabled, verify it on port `9100`:

```sh
kubectl port-forward -n <namespace-name> svc/redis-agent-memory-controlplane 9100:9100
curl http://localhost:9100/health/readiness
# Admin endpoints require the token (HTTP 401 without it):
curl -H "Authorization: Bearer <admin-token>" http://localhost:9100/iris/v1/agent-memory/stores
```

## Observability / Metrics

Both the API server and the worker expose Prometheus metrics at `/metrics` on the
service container port (`service.port`, default `9000`). The endpoint is
**unauthenticated** and is intended for **in-cluster scraping only** — do not
expose it outside the cluster.

The async-queue signals are split across the two processes, so collecting the
full picture requires scraping **both**:

- **Server** (`redis-agent-memory` Deployment + Service): emits the submission
  metric `iris_jobqueue_enqueue_total` (with `service_name="dataplane"`) alongside the
  HTTP/runtime metrics. Reachable through the `redis-agent-memory` Service on port
  `9000`.
- **Worker** (`redis-agent-memory-worker` Deployment): emits the job-processing
  metrics (all with `service_name="worker"`) — `iris_jobqueue_processing_duration_seconds`,
  `iris_jobqueue_schedule_to_start_seconds`,
  `iris_jobqueue_size`, `iris_jobqueue_oldest_pending_seconds`,
  and `iris_jobqueue_worker_up`.

Every `jobqueue_*` series also carries the constant identity labels
`service_namespace="agent-memory"` and `service_name` (`dataplane` on the server, `worker`
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

- new RAM version: change `image.tag` and `controlplane.image.tag`
- chart-only update: change `--version`; `helm upgrade` from a `0.0.x` chart is
  unsupported (see [Upgrading from `0.0.x`](#upgrading-from-00x))
- license rotation: update the Secret and `license.existingSecretChecksum`
- config change: update the Secret and `config.existingSecretChecksum` (or
  `controlplane.config.existingSecretChecksum` for the control-plane config)
- credential/overlay rotation: update the pre-created overlay Secret contents,
  then restart the pods (`kubectl rollout restart`) — credentials are read at
  client construction, so the mounted overlay takes effect on pod restart. The
  chart rolls automatically only if the overlay Secret *name* changes.
- control-plane admin-token rotation: edit the admin-token Secret — read-on-use, no redeploy needed

Static store removal is an intentional breaking upgrade. Remove
`metadata.source`, `metadata.stores`, and `metadata.live`; configure
`metadata.urls`, `metadata.namespace`, `databases`, and `embedding`. Stale keys
fail startup. Create replacement stores and agent keys through the bundled
Control Plane. Existing static-store Redis data is not deleted, but new stores
receive new IDs and do not automatically address it; preserving an old ID or
adopting its data requires a separate migration procedure.

The auth-profile change from MOD-19875 can stop an upgrade:

- The data plane refuses `memory.auth.method: none` when `memory.profile` is
  not `dev`. An empty profile is `prod`. The pod does not start. Use
  `auth.method: agent_key` for a deployment that keeps data. For a development
  deployment, set `memory.profile: dev`. The chart refuses to render
  `auth.method: none` without `profile: dev`. The `dev` profile also sets the
  gin debug mode and the development logger. The `basic` and `multi-region`
  examples use it.
<!-- markdownlint-enable MD013 MD060 -->

## Health probe migration

Chart `0.1.2` uses `/health/liveness` and `/health/readiness` for Identity Service
support-bundle checks. Deploy matching service images that expose these
routes; older images and newer chart probes must not be mixed. Update custom
monitoring URLs at the same time.
