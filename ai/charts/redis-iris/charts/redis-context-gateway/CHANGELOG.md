# Context Gateway chart changes

## 1.1.1

- No component changes.

## 1.1.0

- Add `redisClientTLS` to present a client certificate to Redis (mutual TLS and certificate-only
  login). The Secrets are mounted read-only at `/etc/redis-client-tls` and the config names them;
  a renewed certificate is used without a restart (MOD-14536).

- Set the socket limit for Gateway cache, handles, and Surfaces under
  `dataplane.config`. The default is eight sockets per Redis client.

- Redis enforces `maxmemory` on the Gateway database. `noeviction` and an
  unbounded `maxmemory` still work, with a deprecation warning that recommends
  a finite `maxmemory` and `volatile-ttl`. Redis Software and Redis Cloud
  enforce their own memory limit and do not report it, so they get no warning.
- `dataplane.config.cache.max_memory_share` and
  `dataplane.config.compression.max_memory_share` are deprecated and ignored.
  The schema still accepts them, and the install notes warn when either is set.

- Add a configurable HTTP request tool and ID and name filters on Gateway lists.
- Support tenant-aware on-prem operation.

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
