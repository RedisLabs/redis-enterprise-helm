#!/usr/bin/env bash
# template-queue-monitor.sh
#
# Offline chart test (no cluster required) for the optional Asynqmon queue
# monitor. Asserts disabled-by-default rendering, enabled Deployment/Service,
# Redis Secret env wiring, dedicated-host Ingress, ingress-nginx Basic Auth
# wiring, TLS env keys, and read-only defaults.
#
# Usage:
#   ./memory/helm/tests/template-queue-monitor.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="ram-test"
QM_NAME="redis-agent-memory-asynqmon"

COMMON_ARGS=(
  --set image.tag=0.0.0-test
  --set license.existingSecret=license-test
  --set config.existingSecret=config-test
  --set config.secretKey=config.yaml
  --set controlplane.image.tag=cp-0.0.0-test
  --set controlplane.config.existingSecret=cp-config-test
  # The Identity Service is enabled by default, and enabling it makes the image
  # tag and the metadata Redis overlay Secret mandatory.
  --set identityService.image.tag=ids-0.0.0-test
  --set identityService.metadata.existingSecret=ids-metadata
)

QM_ARGS=(
  --set controlplane.queueMonitor.enabled=true
  --set controlplane.queueMonitor.redis.existingSecret=ram-job-redis
)

INGRESS_ARGS=(
  --set controlplane.queueMonitor.ingress.enabled=true
  --set controlplane.queueMonitor.ingress.host=ram-jobs.example.com
  --set controlplane.queueMonitor.ingress.tls.secretName=ram-jobs-tls
  --set controlplane.queueMonitor.auth.existingSecret=redis-agent-memory-asynqmon-basic-auth
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

count_kind() {
  local manifest="$1" kind="$2"
  printf '%s\n' "$manifest" \
    | awk -v k="kind: $kind" '$0 == k { c++ } END { print c+0 }'
}

echo "=== Case 1: default queue monitor disabled -> no Asynqmon resources ==="
OUT="$(render)"
if grep -q 'app.kubernetes.io/component: queue-monitor' <<<"$OUT"; then
  fail "queue-monitor resources rendered with controlplane.queueMonitor.enabled=false"
fi
if grep -qE "name: ${QM_NAME}([[:space:]]|$)" <<<"$OUT"; then
  fail "resource named ${QM_NAME} rendered with queue monitor disabled"
fi
echo "OK: queue monitor is fully off by default"

echo "=== Case 2: enabled without ingress -> Deployment + Service, no Ingress ==="
OUT="$(render "${QM_ARGS[@]}")"
[ "$(count_kind "$OUT" Deployment)" = "5" ] \
  || fail "expected 5 Deployments (server+worker+controlplane+identity-service+queue-monitor), got $(count_kind "$OUT" Deployment)"
grep -qE "name: ${QM_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "queue monitor Deployment/Service named ${QM_NAME} did not render"
grep -q 'app.kubernetes.io/component: queue-monitor' <<<"$OUT" \
  || fail "queue monitor component label missing"
if grep -q "host: \"ram-jobs.example.com\"" <<<"$OUT"; then
  fail "queue monitor Ingress rendered even though ingress.enabled=false"
fi
echo "OK: enabled monitor renders only Deployment + Service by default"

echo "=== Case 3: Redis Secret env wiring and read-only default render ==="
grep -q 'name: REDIS_URL' <<<"$OUT" \
  || fail "REDIS_URL env var missing"
grep -q 'name: ram-job-redis' <<<"$OUT" \
  || fail "Redis Secret name not wired"
grep -q 'key: REDIS_URL' <<<"$OUT" \
  || fail "Redis URL key not wired"
grep -q 'name: REDIS_TLS' <<<"$OUT" \
  || fail "optional REDIS_TLS env var missing"
grep -q 'key: REDIS_TLS' <<<"$OUT" \
  || fail "Redis TLS key not wired"
grep -q 'name: REDIS_INSECURE_TLS' <<<"$OUT" \
  || fail "optional REDIS_INSECURE_TLS env var missing"
grep -q 'key: REDIS_INSECURE_TLS' <<<"$OUT" \
  || fail "Redis insecure TLS key not wired"
grep -A1 'name: READ_ONLY' <<<"$OUT" | grep -q 'value: "true"' \
  || fail "READ_ONLY=true did not render by default"
echo "OK: Redis Secret env wiring and read-only default render"

echo "=== Case 4: dedicated-host ingress renders with Basic Auth Secret ==="
OUT="$(render "${QM_ARGS[@]}" "${INGRESS_ARGS[@]}")"
[ "$(count_kind "$OUT" Ingress)" = "1" ] \
  || fail "expected exactly 1 Ingress for queue monitor, got $(count_kind "$OUT" Ingress)"
grep -q 'host: "ram-jobs.example.com"' <<<"$OUT" \
  || fail "dedicated queue monitor host did not render"
grep -q 'secretName: ram-jobs-tls' <<<"$OUT" \
  || fail "queue monitor TLS Secret did not render"
grep -q 'nginx.ingress.kubernetes.io/auth-type: basic' <<<"$OUT" \
  || fail "Basic Auth type annotation missing"
grep -q 'nginx.ingress.kubernetes.io/auth-secret: redis-agent-memory-asynqmon-basic-auth' <<<"$OUT" \
  || fail "Basic Auth Secret annotation missing"
grep -q 'nginx.ingress.kubernetes.io/auth-secret-type: auth-file' <<<"$OUT" \
  || fail "htpasswd auth-file annotation missing"
grep -q "name: ${QM_NAME}" <<<"$OUT" \
  || fail "Ingress backend does not point at the queue monitor Service"
echo "OK: dedicated-host Basic Auth ingress renders"

echo "=== Case 4b: Basic Auth annotations win over conflicting extra annotations ==="
OUT="$(render "${QM_ARGS[@]}" "${INGRESS_ARGS[@]}" \
  --set-string 'controlplane.queueMonitor.ingress.annotations.nginx\.ingress\.kubernetes\.io/auth-type=none')"
grep -q 'nginx.ingress.kubernetes.io/auth-type: basic' <<<"$OUT" \
  || fail "required Basic Auth annotation was overridden by extra annotations"
if grep -q 'nginx.ingress.kubernetes.io/auth-type: none' <<<"$OUT"; then
  fail "conflicting auth-type annotation rendered"
fi
echo "OK: required Basic Auth annotations cannot be overridden by extras"

echo "=== Case 5: readOnly=false is explicit when operator opts into mutations ==="
OUT="$(render "${QM_ARGS[@]}" --set controlplane.queueMonitor.readOnly=false)"
grep -A1 'name: READ_ONLY' <<<"$OUT" | grep -q 'value: "false"' \
  || fail "READ_ONLY=false did not render when requested"
echo "OK: read-only mode is configurable"

echo "=== Case 6: enabled without Redis Secret must fail closed ==="
if render --set controlplane.queueMonitor.enabled=true >/dev/null 2>&1; then
  fail "chart rendered queue monitor without controlplane.queueMonitor.redis.existingSecret"
fi
echo "OK: missing Redis Secret rejected"

echo "=== Case 7: ingress without Basic Auth Secret must fail closed ==="
if render "${QM_ARGS[@]}" \
    --set controlplane.queueMonitor.ingress.enabled=true \
    --set controlplane.queueMonitor.ingress.host=ram-jobs.example.com >/dev/null 2>&1; then
  fail "chart rendered queue monitor Ingress without a Basic Auth Secret"
fi
echo "OK: missing Basic Auth Secret rejected"

echo "=== Case 8: ingress-nginx htpasswd key must be auth ==="
if render "${QM_ARGS[@]}" \
    --set controlplane.queueMonitor.ingress.enabled=true \
    --set controlplane.queueMonitor.ingress.host=ram-jobs.example.com \
    --set controlplane.queueMonitor.auth.existingSecret=redis-agent-memory-asynqmon-basic-auth \
    --set controlplane.queueMonitor.auth.secretKey=custom >/dev/null 2>&1; then
  fail "chart rendered queue monitor Ingress with unsupported htpasswd key"
fi
echo "OK: unsupported htpasswd key rejected"

echo ""
echo "All queue-monitor chart template checks passed."
