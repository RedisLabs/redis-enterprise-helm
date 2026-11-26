#!/usr/bin/env bash
# template-redis-client-tls.sh
#
# Offline chart test for Redis client certificates (redisClientTLS): the
# control plane, data plane and worker mount the Secrets read-only without
# subPath, every rendered config names the default pair, and an extra
# certificate lands in its own directory.
#
# Usage: ./playbook/helm/tests/template-redis-client-tls.sh

set -euo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)"

ARGS=(
  -f "$CHART/tests/values-test.yaml"
  --set worker.enabled=true
  --set worker.region=local
  --set worker.existingSecret=worker-config
  --set worker.sourceURL=http://ram:8000
)
TLS_ARGS=(
  --set redisClientTLS.existingSecret=playbook-client
  --set 'redisClientTLS.extraCertificates[0].name=store-1'
  --set 'redisClientTLS.extraCertificates[0].existingSecret=playbook-store-1-client'
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Renders one Kubernetes object, by kind and name, from a full render.
object() { # <render> <kind> <name>
  awk -v kind="kind: $2" -v name="  name: $3" '
    /^---/ { if (match_kind && match_name) print doc; doc = ""; match_kind = 0; match_name = 0; next }
    { doc = doc $0 "\n" }
    $0 == kind { match_kind = 1 }
    $0 == name { match_name = 1 }
    END { if (match_kind && match_name) print doc }
  ' <<<"$1"
}

echo "== Without redisClientTLS: nothing rendered =="
out=$(helm template playbook-test "$CHART" "${ARGS[@]}")
if grep -qF "redis-client-tls" <<<"$out"; then fail "default render mounts client certificates"; fi
if grep -qF "redis_client_tls" <<<"$out"; then fail "default render configures client certificates"; fi

out=$(helm template playbook-test "$CHART" "${ARGS[@]}" "${TLS_ARGS[@]}")

echo "== Control plane, data plane and worker mount the Secrets read-only =="
for name in $(grep -A3 '^kind: Deployment' <<<"$out" | sed -n 's/^  name: //p'); do
  deployment=$(object "$out" Deployment "$name")
  grep -A2 -- "- name: redis-client-tls$" <<<"$deployment" | grep -qF "mountPath: /etc/redis-client-tls" \
    || fail "$name does not mount /etc/redis-client-tls"
  grep -A2 -- "mountPath: /etc/redis-client-tls" <<<"$deployment" | grep -qF "readOnly: true" \
    || fail "$name mount is not read-only"
  if grep -qF "subPath" <<<"$deployment"; then fail "$name uses subPath, which never sees a renewed pair"; fi
  grep -qF 'name: "playbook-client"' <<<"$deployment" || fail "$name does not project the default Secret"
  grep -qF "path: store-1/tls.crt" <<<"$deployment" || fail "$name does not project the extra certificate"
done
[ "$(grep -c '^kind: Deployment' <<<"$out")" -eq 3 ] || fail "expected the control plane, data plane and worker Deployments"

echo "== Every rendered config names the default pair =="
for key in playbook-controlplane.yaml playbook-dataplane.yaml worker.yaml; do
  config=$(awk -v key="  $key: |" '$0 == key { on = 1; next } on && /^  [^ ]/ { on = 0 } on && /^---/ { on = 0 } on' <<<"$out")
  grep -qF "cert_path: /etc/redis-client-tls/tls.crt" <<<"$config" || fail "$key has no cert_path"
  grep -qF "key_path: /etc/redis-client-tls/tls.key" <<<"$config" || fail "$key has no key_path"
done

echo "All Redis client certificate render assertions passed."
