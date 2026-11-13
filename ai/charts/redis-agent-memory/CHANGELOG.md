# Agent Memory chart changes

## 1.0.1

- Publish every image of this chart for `linux/amd64` and `linux/arm64` under the same tag, as one
  multi-platform image index (MOD-20940).
- The optional queue monitor (`controlplane.queueMonitor`) runs Asynqdash
  (`ghcr.io/jpedrosouza/asynqdash:1.2.0`), an Asynqmon fork that publishes both platforms, instead of
  `hibiken/asynqmon:0.7.2`, which is AMD64-only. Its Deployment, Service and Ingress are renamed
  from `<release>-asynqmon` to `<release>-asynqdash`, and the container to `asynqdash`.
  **With `controlplane.queueMonitor.ingress.enabled=true`, delete the `<release>-asynqmon` Ingress
  before upgrading to 1.0.1, and `<release>-asynqdash` before rolling back to 1.0.0**: Helm creates the
  renamed Ingress before it deletes the old one, and the ingress-nginx admission webhook rejects a
  second Ingress on the same host and path (see the chart README). The default registry moves from
  docker.io to ghcr.io: airgap installs and clusters with a registry allowlist must mirror or allow the
  new image. The new `controlplane.queueMonitor.redis.usernameKey` (default `REDIS_USERNAME`, optional)
  names the ACL user key.
- The support package health check uses `replicated/troubleshoot:0.134.3`.
- Accept an optional `tls_server_name` query parameter on `rediss://` Redis URLs, to verify the
  Redis Enterprise default certificate against a name it covers (MOD-20944): `metadata.urls`,
  `databases.<id>.urls` and `background_jobs.redis.urls`. The queue monitor trusts `tls.caCertSecret`.

## 1.0.0

- Join the Redis Iris 1.0 component release set with matching chart, application,
  and image versions.
- Support suite-managed credentials, licensing, and Identity Service connections
  through `global.iris` when installed by the `redis-iris` umbrella chart.
