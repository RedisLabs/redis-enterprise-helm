#!/usr/bin/env bash
# template-redis-client-tls.sh
#
# Offline chart test for Redis client certificates (redisClientTLS): the
# server, worker and control plane mount the Secrets read-only without subPath,
# both rendered configs name the default pair, an extra certificate lands in
# its own directory, and the queue monitor gets nothing.
#
# Usage: ./memory/helm/tests/template-redis-client-tls.sh

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"

ARGS=(
  --set image.tag=0.0.0-test
  --set-string tenantId=default
  --set license.existingSecret=license-test
  --set controlplane.image.tag=cp-0.0.0-test
  -f "$CHART_DIR/examples/multi-region/base-values.yaml"
  --set memory.profile=prod
  --set memory.auth.method=identity_service
  --set controlplane.config.render=true
  --set dataplane.identityServiceBaseURL=http://ids:9200
  --set identityService.allowInsecureTransport=true
  --set identityService.credential.existingSecret=memory-dp
  --set controlplane.queueMonitor.enabled=true
  --set controlplane.queueMonitor.redis.existingSecret=ram-job-redis
)
TLS_ARGS=(
  --set redisClientTLS.existingSecret=ram-client
  --set 'redisClientTLS.extraCertificates[0].name=store-1'
  --set 'redisClientTLS.extraCertificates[0].existingSecret=ram-store-1-client'
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# show <template> <extra helm args...>
show() {
  local template=$1
  shift
  helm template ram-test "$CHART_DIR" "${ARGS[@]}" "$@" --show-only "templates/$template"
}

echo "== Without redisClientTLS: nothing rendered =="
out=$(helm template ram-test "$CHART_DIR" "${ARGS[@]}")
if grep -qF "redis-client-tls" <<<"$out"; then fail "default render mounts client certificates"; fi
if grep -qF "redis_client_tls" <<<"$out"; then fail "default render configures client certificates"; fi

echo "== Server, worker and control plane mount the Secrets read-only =="
for workload in deployment.yaml deployment-worker.yaml controlplane-deployment.yaml; do
  out=$(show "$workload" "${TLS_ARGS[@]}")
  grep -A2 -- "- name: redis-client-tls$" <<<"$out" | grep -qF "mountPath: /etc/redis-client-tls" \
    || fail "$workload does not mount /etc/redis-client-tls"
  grep -A2 -- "mountPath: /etc/redis-client-tls" <<<"$out" | grep -qF "readOnly: true" \
    || fail "$workload mount is not read-only"
  if grep -qF "subPath" <<<"$out"; then fail "$workload uses subPath, which never sees a renewed pair"; fi
  grep -qF 'name: "ram-client"' <<<"$out" || fail "$workload does not project the default Secret"
  grep -qF "path: store-1/tls.crt" <<<"$out" || fail "$workload does not project the extra certificate"
done

echo "== Operator volumes after the client certificates stay separate list items =="
# The library helpers end without a newline; each caller's {{- with }} body
# supplies it. A glued line here would be invalid YAML that fails install.
EXTRA_ARGS=(
  --set 'volumes[0].name=extra-vol' --set 'volumes[0].emptyDir.medium=Memory'
  --set 'volumeMounts[0].name=extra-vol' --set 'volumeMounts[0].mountPath=/extra'
  --set 'controlplane.volumes[0].name=extra-vol' --set 'controlplane.volumes[0].emptyDir.medium=Memory'
  --set 'controlplane.volumeMounts[0].name=extra-vol' --set 'controlplane.volumeMounts[0].mountPath=/extra'
)
for workload in deployment.yaml controlplane-deployment.yaml; do
  out=$(show "$workload" "${TLS_ARGS[@]}" "${EXTRA_ARGS[@]}")
  grep -A1 -- "readOnly: true$" <<<"$out" | grep -qE -- "^ +- mountPath: /extra$" \
    || fail "$workload glues the extra volume mount onto the client certificate mount"
  grep -A1 -- "path: store-1/tls.key$" <<<"$out" | grep -qE -- "^ +- emptyDir:$" \
    || fail "$workload glues the extra volume onto the client certificate volume"
done

echo "== Both rendered configs name the default pair =="
for config in config.yaml controlplane-config.yaml; do
  out=$(show "$config" "${TLS_ARGS[@]}")
  grep -qF "cert_path: /etc/redis-client-tls/tls.crt" <<<"$out" || fail "$config has no cert_path"
  grep -qF "key_path: /etc/redis-client-tls/tls.key" <<<"$out" || fail "$config has no key_path"
done

echo "== The queue monitor is unsupported with client certificates: no mount =="
out=$(show queue-monitor-deployment.yaml "${TLS_ARGS[@]}")
if grep -qF "redis-client-tls" <<<"$out"; then fail "queue monitor mounts client certificates"; fi

echo "All Redis client certificate render assertions passed."
