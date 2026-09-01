#!/usr/bin/env bash
# template-render.sh
#
# Offline chart test (no cluster required) that renders the langcache chart
# with `helm template` and verifies: bundled and external Identity Service
# mode render the right resources (and external renders no duplicate IdS
# workload), default scaling matches the ticket's topology, and the chart
# fails closed on missing/conflicting required values and on
# security.profile=fips combined with an insecure Identity Service endpoint.
#
# Usage:
#   ./langcache/helm/tests/template-render.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="langcache-test"

DP_NAME="langcache"
CP_NAME="langcache-controlplane"
IDS_NAME="langcache-identity-service"

COMMON_ARGS=(
  --set dataplane.image.tag=0.0.0-test
  --set controlplane.image.tag=0.0.0-test
  --set dataplane.license.existingSecret=license-test
  --set dataplane.secrets.secretName=dp-overlay-test
  --set controlplane.secrets.secretName=cp-overlay-test
  --set dataplane.embedding.endpoint.baseURL=https://embedding.example.test
  --set dataplane.embedding.models.defaultEmbeddingModel=fixture-model
  --set dataplane.embedding.models.dimensions=8
)

BUNDLED_ARGS=(
  --set identityService.bundled.image.tag=0.0.0-test
  --set identityService.bundled.metadata.existingSecret=ids-metadata-test
)

EXTERNAL_ARGS=(
  --set identityService.mode=external
  --set identityService.external.baseURL=https://suite-ids.example.com
  --set identityService.external.credential.existingSecret=ext-ids-cred
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

render_expect_fail() {
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN
  if helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@" >"$out_file" 2>&1; then
    cat "$out_file" >&2
    fail "expected helm template to fail, but it succeeded"
  fi
}

count_kind() {
  local manifest="$1" kind="$2"
  printf '%s\n' "$manifest" \
    | awk -v k="kind: $kind" '$0 == k { c++ } END { print c+0 }'
}

echo "=== Case 1: default (bundled Identity Service) -> DP, CP, and bundled IdS all render ==="
OUT=$(render "${BUNDLED_ARGS[@]}")
[ "$(count_kind "$OUT" Deployment)" = "3" ] \
  || fail "expected 3 Deployments (dataplane+controlplane+identity-service), got $(count_kind "$OUT" Deployment)"
[ "$(count_kind "$OUT" Service)" = "3" ] \
  || fail "expected 3 Services, got $(count_kind "$OUT" Service)"
[ "$(count_kind "$OUT" HorizontalPodAutoscaler)" = "1" ] \
  || fail "expected exactly 1 HorizontalPodAutoscaler (Data Plane only, no Control Plane HPA)"
[ "$(count_kind "$OUT" Ingress)" = "0" ] \
  || fail "expected no Ingress by default"
grep -qE "name: ${DP_NAME}([[:space:]]|$)" <<<"$OUT" || fail "Data Plane resource ${DP_NAME} did not render"
grep -qE "name: ${CP_NAME}([[:space:]]|$)" <<<"$OUT" || fail "Control Plane resource ${CP_NAME} did not render"
grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT" || fail "bundled Identity Service resource ${IDS_NAME} did not render"
echo "OK: bundled mode renders Data Plane, Control Plane, and Identity Service"

echo "=== Case 2: default scaling matches the ticket's topology ==="
grep -A1 "minReplicas:" <<<"$OUT" | grep -q "minReplicas: 2" || fail "expected dataplane.autoscaling.minReplicas=2 by default"
grep -q "maxReplicas: 10" <<<"$OUT" || fail "expected dataplane.autoscaling.maxReplicas=10 by default"
grep -q "averageUtilization: 80" <<<"$OUT" || fail "expected dataplane.autoscaling.targetCPUUtilizationPercentage=80 by default"
echo "OK: default DP autoscaling is 2-10 replicas at 80% CPU, CP is a single fixed replica with no HPA"

echo "=== Case 3: external Identity Service mode -> no Identity Service workload renders ==="
OUT=$(render "${EXTERNAL_ARGS[@]}")
[ "$(count_kind "$OUT" Deployment)" = "2" ] \
  || fail "expected 2 Deployments (dataplane+controlplane only), got $(count_kind "$OUT" Deployment)"
if grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT"; then
  fail "a resource named ${IDS_NAME} rendered with identityService.mode=external"
fi
grep -q "secretName: ext-ids-cred" <<<"$OUT" || fail "Data Plane did not mount the external Identity Service credential Secret"
echo "OK: external mode renders no duplicate Identity Service workload"

echo "=== Case 4: missing dataplane.image.tag -> helm must refuse ==="
render_expect_fail --set dataplane.image.tag=""
echo "OK: missing dataplane.image.tag rejected"

echo "=== Case 5: identityService.mode unset/invalid -> helm must refuse ==="
render_expect_fail "${BUNDLED_ARGS[@]}" --set identityService.mode=""
render_expect_fail "${BUNDLED_ARGS[@]}" --set identityService.mode=bogus
echo "OK: missing or invalid identityService.mode rejected"

echo "=== Case 6: external mode missing baseURL or credential -> helm must refuse ==="
render_expect_fail --set identityService.mode=external
render_expect_fail --set identityService.mode=external --set identityService.external.baseURL=https://suite-ids.example.com
echo "OK: external mode requires both baseURL and credential.existingSecret"

echo "=== Case 7: bundled mode missing metadata Secret -> helm must refuse ==="
render_expect_fail --set identityService.bundled.image.tag=0.0.0-test
echo "OK: bundled mode requires identityService.bundled.metadata.existingSecret"

echo "=== Case 8: security.profile=fips with bundled Identity Service -> helm must refuse ==="
render_expect_fail "${BUNDLED_ARGS[@]}" --set security.profile=fips
echo "OK: fips + bundled Identity Service rejected (the bundled Service has no TLS termination)"

echo "=== Case 9: security.profile=fips with a plaintext external Identity Service -> helm must refuse ==="
render_expect_fail --set identityService.mode=external \
  --set identityService.external.baseURL=http://suite-ids.example.com \
  --set identityService.external.credential.existingSecret=ext-ids-cred \
  --set security.profile=fips
echo "OK: fips + insecure external baseURL rejected"

echo "=== Case 10: security.profile=fips with a TLS external Identity Service -> renders with GODEBUG=fips140=on ==="
OUT=$(render "${EXTERNAL_ARGS[@]}" --set security.profile=fips)
[ "$(grep -c 'value: "fips140=on"' <<<"$OUT")" = "2" ] \
  || fail "expected GODEBUG=fips140=on on both the Data Plane and Control Plane containers"
echo "OK: fips + TLS external Identity Service renders cleanly with GODEBUG=fips140=on"

echo
echo "All langcache chart render checks passed."
