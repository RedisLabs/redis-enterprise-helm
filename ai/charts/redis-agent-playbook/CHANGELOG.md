# Agent Playbook chart changes

## 1.0.1

- Publish every image of this chart for `linux/amd64` and `linux/arm64` under the same tag, as one
  multi-platform image index (MOD-20940).

## 1.0.0

- Join the Redis Iris 1.0 component release set with matching chart, application,
  and image versions.
- Support suite-managed credentials and Identity Service connections, with
  optional extraction from Agent Memory, through the `redis-iris` umbrella chart.
