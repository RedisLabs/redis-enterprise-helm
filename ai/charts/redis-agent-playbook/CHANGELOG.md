# Agent Playbook chart changes

## 1.1.1

- No component changes.

## 1.1.0

- Support retry-safe UPDATE proposals and ID and name filters on Playbook lists.
- Allow Playbook deletion when content storage is unavailable and retry extraction cleanup after source loss.
- Support tenant-aware on-prem operation, Vertex AI and Cohere embeddings, and Anthropic and Cohere for the worker LLM.
- Support Redis client certificates for mutual TLS and certificate-only login.

## 1.0.1

- Publish every image of this chart for `linux/amd64` and `linux/arm64` under the same tag, as one
  multi-platform image index (MOD-20940).

## 1.0.0

- Join the Redis Iris 1.0 component release set with matching chart, application,
  and image versions.
- Support suite-managed credentials and Identity Service connections, with
  optional extraction from Agent Memory, through the `redis-iris` umbrella chart.
