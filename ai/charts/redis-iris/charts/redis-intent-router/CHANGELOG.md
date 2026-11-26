# Intent Router chart changes

## 1.1.1

- No component changes.

## 1.1.0

- Add `redisClientTLS` to present a client certificate to Redis (mutual TLS and certificate-only
  login). The Secrets are mounted read-only at `/etc/redis-client-tls` and the config names them;
  a renewed certificate is used without a restart (MOD-14536).

- Add ID and name filters on Router lists and support tenant-aware on-prem operation.
- Back off convergence retries per Router when its database fails.

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
