# Lens chart changes

## 1.0.1

- Publish every image of this chart for `linux/amd64` and `linux/arm64` under the same tag, as one
  multi-platform image index (MOD-20940).
- Accept an optional `tls_server_name` query parameter on `rediss://` Redis URLs, to verify the
  Redis Enterprise default certificate against a name it covers (MOD-20944).

## 1.0.0

- Join the Redis Iris 1.0 component release set with matching chart, application,
  and image versions.
- Support suite-managed credentials, licensing, and Identity Service connections
  through `global.iris` when installed by the `redis-iris` umbrella chart.
