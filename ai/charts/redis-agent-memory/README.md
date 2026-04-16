<!-- markdownlint-disable MD013 MD060 -->

# Redis Agent Memory On-Premises Deployment

Helm chart for deploying Redis Agent Memory in customer-managed Kubernetes environments.

## Summary

This chart deploys two workloads from one release:

- `redis-agent-memory`: API server
- `redis-agent-memory-worker`: background worker

Both workloads require:

- a valid RAM license file mounted as `license`
- application configuration
- access to Redis

For enterprise installs, prefer customer-managed Secrets over inline Helm values.

## Naming model

This chart defaults to a stable full resource name:

- server Service and Deployment: `redis-agent-memory`
- worker Deployment: `redis-agent-memory-worker`

This is intentional. The shared on-prem config can then always use:

- `dataplane_client.base_url: http://redis-agent-memory:9000`

without encoding the Helm release name into the config file.

### Expected deployment model

This chart is designed for **one Redis Agent Memory release per namespace**.

That gives customers:

- one reusable shared config file across environments
- a stable in-cluster Service name for worker-to-server calls
- no per-release edits to `dataplane_client.base_url`

If you need multiple Redis Agent Memory releases in the same namespace, you must override
`fullnameOverride` to a unique value for each release and provide a matching
`dataplane_client.base_url` in the external config Secret for that release.

## Deployment guardrails

This chart validates several best practices at template time:

- `image.tag` must be set explicitly for every install and upgrade
- the license must come from `license.existingSecret`
- the shared on-prem config must come from `config.existingSecret`

When `airgap.enabled=true`, the chart also requires `image.repository` to point at a mirrored registry reachable from the cluster.

## Prerequisites

- Kubernetes 1.19+
- Helm 3+
- a reachable Redis deployment
- a customer-specific RAM license file
- a container image accessible from the cluster

## Security model

The chart defaults are now aligned for restricted environments:

- `serviceAccount.create=false`
- `serviceAccount.automount=false`
- fixed image tags should be supplied explicitly
- license material is provided as a Secret-mounted file
- enterprise installs can provide a prebuilt config Secret instead of embedding credentials in Helm values
- `image.tag` is required at install time

## Recommended installation modes

### Mode 1: Enterprise recommended

Use customer-managed Secrets for both:

- the license file
- the shared on-prem application config used by both server and worker

This avoids putting Redis credentials and API keys in Helm values or command history.

#### 1. Create the namespace

```sh
kubectl create namespace <namespace-name>
```

#### 2. Create the license Secret

The Secret key must be `license`.

```sh
kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license
```

#### 3. Create the shared config Secret

Create one Secret containing the shared on-prem config file key `memory-dataplane.config.yaml`.

```sh
kubectl -n <namespace-name> create secret generic ram-config \
  --from-file=memory-dataplane.config.yaml=./memory-dataplane.config.yaml
```

#### 4. Install the chart

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
CONFIG_CHECKSUM="$(shasum ./memory-dataplane.config.yaml | awk '{print $1}')"

helm repo add redis-ai https://helm.redis.io/ai
helm repo update

helm install <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  --set license.existingSecret=ram-license \
  --set config.existingSecret=ram-config \
  --set license.existingSecretChecksum="$LICENSE_CHECKSUM" \
  --set config.existingSecretChecksum="$CONFIG_CHECKSUM" \
  --set image.repository=<image-repository> \
  --set image.tag=<ram-version>
```

### Mode 2: Local or evaluation install

For local testing or evaluation, still create the license Secret and the shared on-prem config Secret first. The chart no longer generates dataplane config from Helm values.

```sh
kubectl -n <namespace-name> create secret generic ram-license \
  --from-file=license=./license

kubectl -n <namespace-name> create secret generic ram-config \
  --from-file=memory-dataplane.config.yaml=./memory-dataplane.config.yaml
```

## License file behavior

The chart mounts the license file into both Deployments at:

`/etc/redis-agent-memory/license`

```yaml
license:
  # Required. Name of the existing Secret that contains the customer license file.
  existingSecret: ram-license

  # Secret key that holds the license payload.
  secretKey: license

  # Directory mounted into the container.
  mountDir: /etc/redis-agent-memory

  # Final filename inside the container.
  # Combined with mountDir, this becomes /etc/redis-agent-memory/license.
  fileName: license

  # Manual rollout trigger for externally managed Secrets.
  # Change this whenever the license Secret content changes.
  existingSecretChecksum: "<output of shasum ./license>"
```

When you rotate an externally managed license Secret, also change `license.existingSecretChecksum` in your Helm values so the Deployments roll automatically.

You can derive this value from the source license file itself. Any deterministic change marker works, but a file hash is the clearest option.

Use:

```sh
LICENSE_CHECKSUM="$(shasum ./license | awk '{print $1}')"
```

Then pass it during install or upgrade:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f my-values.yaml \
  --set license.existingSecretChecksum="$LICENSE_CHECKSUM"
```

## Config Secret behavior

The chart requires one shared config Secret with the shared on-prem config file key:

- `memory-dataplane.config.yaml`

The chart mounts that same key to `/etc/ai/memory-dataplane.config.yaml` in both the server and worker pods.

This is the recommended enterprise pattern because the server and worker share the same on-prem config model, including store definitions and the supported `background_jobs.redis_streams` backend.

```yaml
config:
  # Required. Name of the existing Secret that contains the shared on-prem config file.
  existingSecret: ram-config

  # Secret key mounted into both Deployments as /etc/ai/memory-dataplane.config.yaml.
  secretKey: memory-dataplane.config.yaml

  # Manual rollout trigger for externally managed Secrets.
  # Change this whenever the config Secret content changes.
  existingSecretChecksum: "<output of shasum ./memory-dataplane.config.yaml>"
```

When you rotate an externally managed config Secret, also change `config.existingSecretChecksum` in your Helm values so the Deployments roll automatically.

You can derive this value from the shared on-prem config source file before creating or updating the Secret.

```sh
CONFIG_CHECKSUM="$(shasum ./memory-dataplane.config.yaml | awk '{print $1}')"
```

Then pass it during install or upgrade:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f my-values.yaml \
  --set config.existingSecretChecksum="$CONFIG_CHECKSUM"
```

The value does not need to be a cryptographic checksum. It only needs to change when the underlying Secret content changes. Using `shasum` keeps the instructions simple and consistent for both license and config sources.

## Config file reference

The runtime config file mounted into both workloads is:

`/etc/ai/memory-dataplane.config.yaml`

This is the shared on-prem config consumed by both the API server and the worker. The underlying config model is defined in [onprem_config.go](/Users/todor.todorov/redislabsdev/langcache/memory-dataplane/internal/infrastructure/onprem_config.go).

The fully expanded example used for development lives at [development/memory-dataplane/memory-dataplane-onprem.config.yaml](/Users/todor.todorov/redislabsdev/langcache/development/memory-dataplane/memory-dataplane-onprem.config.yaml).

Use this structure:

```yaml
server:
  # host and port are omitted so containerized deployments use the built-in defaults
  # (host 0.0.0.0, port 9000).
  # Maximum duration for reading request bodies.
  read_timeout: 30s
  # Maximum duration for writing responses.
  write_timeout: 30s
  # Overall request timeout used by the server wrapper.
  timeout: 30s

# profile and debug are fixed internally for on-prem deployments
# and are not configurable through this file.

# Default extraction strategy applied when a store does not override extraction_strategy.
default_extraction_strategy: instruct

client_pool:
  # Enables the Redis client pool used by the dataplane.
  enable: true
  # Maximum pooled clients across stores.
  max_size: 1000
  # Retry count when opening Redis clients.
  max_retries: 10
  # Time to wait for a pooled client before failing.
  client_acquisition_timeout_ms: 2000

background_jobs:
  # Redis Streams is the only supported on-prem backend.
  redis_streams:
    # Must be true in on-prem deployments.
    enabled: true
    # One or more Redis URLs used for the job queue.
    urls:
      - redis://redis-jobs-1:6379
      - redis://redis-jobs-2:6379
    # Logical stream name used for enqueueing and consuming jobs.
    stream_name: memory-jobs
    # How often the delayed-job scheduler scans for due jobs.
    delayed_poll_interval: 1s
    # How long a worker blocks waiting for new stream entries.
    block_duration: 5s
    # How long a pending job can sit idle before another worker may reclaim it.
    claim_idle_time: 30s
    # Maximum number of delivery attempts before the job is marked failed.
    max_delivery_count: 3
    # TTL for deduplication state keyed by job ID.
    deduplication_ttl: 24h
    # Timeout for individual Redis operations against the queue backend.
    operation_timeout: 30s
    # Maximum time allowed for a single job handler execution.
    handler_timeout: 5m

metadata:
  stores:
    - # Stable store identifier used in API paths and job payloads.
      id: "00000000000000000000000000000001"
      # One or more Redis URLs for this store.
      urls:
        - redis://store-a-primary:6379
        - redis://store-a-replica:6379
      # Optional override for extraction behavior; falls back to default_extraction_strategy.
      extraction_strategy: instruct
      short_memory:
        # TTL for short-term/session memory records in seconds.
        ttl_seconds: 3600
      long_term_memory:
        # Must match a key under embedders_connection_details.
        embedding_provider: openai
        # Exact embedding model name expected by that provider endpoint.
        embedding_model: text-embedding-3-large
        # Expected embedding vector size for that model.
        embedding_dimensions: 3072

embedders_connection_details:
  # Provider-name map used by metadata.stores[].long_term_memory.embedding_provider.
  openai:
    # Base URL for embedding requests to this provider.
    base_url: https://api.openai.com
    credentials:
      # Static API-key auth for on-prem config.
      type: static
      # API key presented to the embedding provider.
      api_key: "<embedder-api-key>"

dataplane_client:
  # Base URL the worker uses to call the in-cluster dataplane Service.
  # Because the chart defaults to a stable fullnameOverride, this value does not
  # need to change per release when you run one release per namespace.
  base_url: http://redis-agent-memory:9000
  auth:
    # On-prem installs typically keep this disabled.
    disabled: true
    # Shared passphrase for worker->dataplane auth if auth is enabled later.
    passphrase: ""
  http_client:
    # When true, TLS certificate verification is skipped.
    skip_verify: false
    # Per-request timeout for worker calls back into the dataplane API.
    timeout: 30s
    # HTTP retry count for transient dataplane client failures.
    max_retry_attempts: 3

promote_working_memory:
  llm:
    # Allowed values: openai, oip, noop
    provider: openai
    endpoint:
      # Base URL for the promotion LLM endpoint.
      base_url: https://api.openai.com/v1
      # Request timeout for LLM calls.
      timeout: 30s
      # Allowed values: bearer, api-key
      auth_format: bearer
    credentials:
      # Static API-key auth for the promotion LLM.
      type: static
      # API key used for promote-working-memory requests.
      api_key: "<promotion-llm-api-key>"
    models:
      # Chat model used by the memory-promotion workflow.
      default_chat_model: gpt-4o
    http_client:
      # When true, TLS certificate verification is skipped.
      skip_verify: false
      # Per-request timeout for promotion LLM calls.
      timeout: 30s
      # HTTP retry count for transient promotion LLM failures.
      max_retry_attempts: 3
```


This shared external config Secret is the preferred enterprise path because one file can describe multiple stores, multiple database URLs, background job backend settings, internal model endpoints, and worker-to-server connectivity in one artifact that both workloads consume consistently.

### Secret-backed inputs

The chart enforces Secret-backed credential handling:

- `license.existingSecret` provides the license file mounted at `/etc/redis-agent-memory/license`
- `config.existingSecret` replaces the entire generated config with a shared externally managed on-prem config file

For enterprise deployments with multiple stores, internal endpoints, or many database references, prefer `config.existingSecret` so the full runtime config is reviewed and versioned as a single deployment artifact.

## Image configuration

Do not use floating tags in production.

```yaml
image:
  # Mirror this image into your private registry for enterprise installs.
  repository: redislabs/agent-memory
  # Required at install time. Set this to the RAM version being deployed.
  tag: ""
  pullPolicy: IfNotPresent

# Optional pull secrets for private registries.
imagePullSecrets: []

airgap:
  # When true, Helm requires image.repository to be overridden to a mirrored registry.
  enabled: false
```

### Private registry

Mirror `redislabs/agent-memory:<ram-version>` into your private registry and override:

```yaml
image:
  repository: registry.example.com/redislabs/agent-memory
  tag: "<ram-version>"
imagePullSecrets:
  - name: regcred
```

For disconnected installs, mirror the RAM image into an internal registry, create any required `imagePullSecrets`, and make sure the shared on-prem config file points only to internal services reachable from the cluster.

### Air-gapped environments

Set `airgap.enabled=true` when the deployment must not rely on public image registries.

When enabled, the chart validates that:

- `image.repository` is not the public default `redislabs/agent-memory`

Example:

```sh
helm install <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  --set airgap.enabled=true \
  --set license.existingSecret=ram-license \
  --set config.existingSecret=ram-config \
  --set image.repository=registry.example.com/redislabs/agent-memory \
  --set image.tag=<ram-version>
```

The chart cannot inspect the contents of your external config Secret, so in air-gapped environments you must ensure the shared on-prem config file itself points only to internal services reachable from the cluster.

## Service account behavior

The chart uses the namespace's default ServiceAccount unless you opt into creating or naming a dedicated one. It does not mount a Kubernetes API token unless you opt in.

```yaml
serviceAccount:
  # Create a dedicated ServiceAccount for the release.
  create: false
  # Mount the Kubernetes API token into the pods.
  automount: false
  # Use an existing ServiceAccount instead of the namespace default.
  name: ""
```

## Application configuration

The application configuration comes entirely from the shared on-prem config file stored in `config.existingSecret`. The Helm chart does not expose dataplane config content fields in `values.yaml`.

### Scheduling and runtime controls

The server and worker can be tuned independently:

- `server.resources`, `worker.resources`
- `server.autoscaling`, `worker.autoscaling`
- `server.nodeSelector`, `worker.nodeSelector`
- `server.affinity`, `worker.affinity`
- `server.tolerations`, `worker.tolerations`

## Ingress and service

The chart exposes the API through a Kubernetes Service and optional Ingress.

```yaml
service:
  # Kubernetes Service type used for the dataplane API.
  type: ClusterIP
  # Service port exposed inside the cluster.
  port: 9000

ingress:
  enabled: false
  className: nginx
  hosts:
    - host: redis-agent-memory.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
  tls: []
```

## Verify the deployment

```sh
kubectl get pods -n <namespace-name> -l app.kubernetes.io/name=redis-agent-memory
kubectl port-forward -n <namespace-name> svc/redis-agent-memory 9000:9000
curl http://localhost:9000/health/liveness
```

If you keep the default `fullnameOverride`, the Service name is always `redis-agent-memory`
regardless of the Helm release name. Only change this if you intentionally run multiple
Redis Agent Memory releases in the same namespace and are prepared to manage per-release config.

## Upgrade guidance

Prefer:

```sh
helm upgrade <release-name> redis-ai/redis-agent-memory \
  --version <chart-version> \
  --namespace <namespace-name> \
  -f my-values.yaml
```

For safer upgrades in customer environments, consider:

- `--atomic`
- `--wait`
- a staged rollout of new image tags
- rotating Secrets before the upgrade if credentials or license material changed

## Notes for enterprise operators

- Prefer `config.existingSecret` for production installations.
- Use `license.existingSecret` for every installation.
- Prefer immutable image tags or digests.
- If using a private registry, set `image.repository`, `imagePullSecrets`, and mirror all required images before installation.
- If using an air-gapped environment, set `airgap.enabled=true`.
- If deploying into a restricted namespace, this chart does not require Kubernetes API access from the application pods.

<!-- markdownlint-enable MD013 MD060 -->
