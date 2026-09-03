#!/usr/bin/env bash
# template-controlplane.sh
#
# Offline chart test (no cluster required) that renders the chart with
# `helm template` under several controlplane.* settings and asserts the bundled
# Control Plane renders a Deployment + Service on port 9100 plus token Secrets,
# honors the bring-your-own-token path, fails closed on missing required inputs,
# and participates in the FIPS security profile.
#
# Usage:
#   ./memory/helm/tests/template-controlplane.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="ram-test"

# With the chart's default fullnameOverride (redis-agent-memory), the control
# plane's resources are named deterministically.
CP_NAME="redis-agent-memory-controlplane"
CP_TOKEN_SECRET="redis-agent-memory-controlplane-admin-token"
CP_INTERNAL_TOKEN_SECRET="redis-agent-memory-controlplane-internal-token"

# Required data-plane inputs (the chart always renders server + worker).
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

CP_ARGS=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

# Count "kind: <X>" documents in a rendered manifest.
count_kind() {
  local manifest="$1" kind="$2"
  printf '%s\n' "$manifest" \
    | awk -v k="kind: $kind" '$0 == k { c++ } END { print c+0 }'
}

# Count generated Secrets belonging to the control plane. Scoped by name rather
# than counting every `kind: Secret` in the manifest, so that a Secret another
# component adds (the Identity Service brings two) does not read as the control
# plane having generated one it did not.
count_cp_secrets() {
  local manifest="$1"
  printf '%s\n' "$manifest" \
    | awk -v p="  name: ${CP_NAME}-" '
        /^kind: Secret$/ { s=1; next }
        s && /^  name:/ { if (index($0, p) == 1) { c++ } s=0 }
        END { print c+0 }
      '
}

# Count GODEBUG env entries carrying the given value. One per
# container (server + worker, plus control plane when enabled).
count_fips_runtime_value() {
  local manifest="$1" value="$2"
  printf '%s\n' "$manifest" \
    | awk -v val="$value" '
        /name: GODEBUG/ { want=1; next }
        want && /value:/ {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          gsub(/^value:[[:space:]]*/, "", $0)
          gsub(/"/, "", $0)
          if ($0 == val) c++
          want=0
        }
        END { print c+0 }
      '
}

echo "=== Case 1: bundled control plane renders by default ==="
OUT=$(render)
grep -q 'app.kubernetes.io/component: controlplane' <<<"$OUT" \
  || fail "bundled control-plane resources did not render"
grep -qE "name: ${CP_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "resource named ${CP_NAME} did not render"
echo "OK: bundled control plane renders"

echo "=== Case 2: Deployment + Service + generated token Secrets on 9100 ==="
OUT=$(render "${CP_ARGS[@]}")
# Four Deployments now: server, worker, control plane, Identity Service.
[ "$(count_kind "$OUT" Deployment)" = "4" ] \
  || fail "expected 4 Deployments (server+worker+controlplane+identity-service), got $(count_kind "$OUT" Deployment)"
grep -qE "name: ${CP_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "control-plane Deployment/Service named ${CP_NAME} did not render"
grep -q "name: ${CP_TOKEN_SECRET}" <<<"$OUT" \
  || fail "admin-token Secret ${CP_TOKEN_SECRET} did not render (autoGenerate default)"
grep -q "name: ${CP_INTERNAL_TOKEN_SECRET}" <<<"$OUT" \
  || fail "internal-token Secret ${CP_INTERNAL_TOKEN_SECRET} did not render (autoGenerate default)"
[ "$(count_cp_secrets "$OUT")" = "2" ] \
  || fail "expected exactly 2 generated control-plane Secrets (admin + internal tokens), got $(count_cp_secrets "$OUT")"
N=$(count_fips_runtime_value "$OUT" "fips140=off")
[ "$N" = "4" ] \
  || fail "expected 4 GODEBUG=fips140=off entries (server+worker+controlplane+identity-service), got $N"
grep -q 'containerPort: 9100' <<<"$OUT" \
  || fail "control-plane container port 9100 did not render"
grep -q 'path: /v1/health/live' <<<"$OUT" \
  || fail "control-plane liveness probe /v1/health/live did not render"
grep -q 'path: /v1/health/ready' <<<"$OUT" \
  || fail "control-plane readiness probe /v1/health/ready did not render"
echo "OK: control plane renders resources, probes, and the default non-FIPS runtime"

echo "=== Case 3: missing controlplane.image.tag → helm must refuse ==="
if helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" \
     --set controlplane.image.tag= \
     --set controlplane.config.existingSecret=cp-config-test >/dev/null 2>&1; then
  fail "helm rendered without controlplane.image.tag"
fi
echo "OK: missing controlplane.image.tag rejected at render time"

echo "=== Case 4: no admin-token source → helm must refuse ==="
if render "${CP_ARGS[@]}" \
     --set controlplane.adminToken.autoGenerate=false >/dev/null 2>&1; then
  fail "helm rendered the control plane with neither adminToken.existingSecret nor autoGenerate"
fi
echo "OK: missing admin-token source rejected at render time"

echo "=== Case 5: BYO admin token (existingSecret + autoGenerate=false) → only internal-token Secret generated ==="
OUT=$(render "${CP_ARGS[@]}" \
  --set controlplane.adminToken.existingSecret=byo-admin-token \
  --set controlplane.adminToken.autoGenerate=false)
[ "$(count_cp_secrets "$OUT")" = "1" ] \
  || fail "expected exactly 1 generated control-plane Secret (internal token), got $(count_cp_secrets "$OUT")"
if grep -q "name: ${CP_TOKEN_SECRET}" <<<"$OUT"; then
  fail "admin-token Secret ${CP_TOKEN_SECRET} was generated even though a BYO admin-token Secret was provided"
fi
grep -q "name: ${CP_INTERNAL_TOKEN_SECRET}" <<<"$OUT" \
  || fail "internal-token Secret ${CP_INTERNAL_TOKEN_SECRET} did not render"
# The control plane still renders (Deployment present), it just references the BYO Secret.
grep -qE "name: ${CP_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "control plane did not render in BYO-token mode"
echo "OK: BYO admin-token suppresses only the generated admin Secret"

echo "=== Case 6: security.profile=fips → fips on server, worker, and control plane ==="
OUT=$(render "${CP_ARGS[@]}" --set security.profile=fips)
N=$(count_fips_runtime_value "$OUT" "fips140=on")
[ "$N" = "4" ] \
  || fail "expected 4 GODEBUG=fips140=on entries (server+worker+controlplane+identity-service), got $N"
echo "OK: FIPS runtime enabled on the control-plane container too"

echo "=== Case 7: controlplane.volumes/volumeMounts passthrough (CSI sync support) renders ==="
OUT=$(render "${CP_ARGS[@]}" \
  --set 'controlplane.volumes[0].name=secrets-store' \
  --set 'controlplane.volumes[0].csi.driver=secrets-store.csi.k8s.io' \
  --set 'controlplane.volumeMounts[0].name=secrets-store' \
  --set 'controlplane.volumeMounts[0].mountPath=/mnt/secrets-store')
grep -q 'secrets-store.csi.k8s.io' <<<"$OUT" \
  || fail "controlplane.volumes CSI passthrough did not render"
grep -q 'mountPath: /mnt/secrets-store' <<<"$OUT" \
  || fail "controlplane.volumeMounts passthrough did not render"
echo "OK: control-plane volumes/volumeMounts passthrough renders (enables CSI-synced Secrets)"

echo ""
echo "All control-plane chart template checks passed."
