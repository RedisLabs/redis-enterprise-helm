#!/usr/bin/env bash
# template-controlplane.sh
#
# Offline chart test (no cluster required) that renders the chart with
# `helm template` under several controlplane.* settings and asserts the optional
# Control Plane is wired correctly: disabled by default (no CP resources), and
# when enabled it renders a Deployment + Service on port 9100 plus an admin-token
# Secret, honors the bring-your-own-token path, fails closed on missing required
# inputs, and participates in the FIPS security profile.
#
# Usage:
#   ./deployment/redis-agent-memory/tests/template-controlplane.sh
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

# Required data-plane inputs (the chart always renders server + worker).
COMMON_ARGS=(
  --set image.tag=0.0.0-test
  --set license.existingSecret=license-test
  --set config.existingSecret=config-test
  --set config.secretKey=config.yaml
)

# Minimal valid control-plane enablement.
CP_ARGS=(
  --set controlplane.enabled=true
  --set controlplane.image.tag=cp-0.0.0-test
  --set controlplane.config.existingSecret=cp-config-test
)

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

# Count MEM_SECURITY_PROFILE env entries carrying the given value. One per
# container (server + worker, plus control plane when enabled).
count_profile_value() {
  local manifest="$1" value="$2"
  printf '%s\n' "$manifest" \
    | awk -v val="$value" '
        /name: MEM_SECURITY_PROFILE/ { want=1; next }
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

echo "=== Case 1: default (controlplane disabled) → no CP resources render ==="
OUT=$(render)
if printf '%s' "$OUT" | grep -q 'app.kubernetes.io/component: controlplane'; then
  fail "control-plane resources rendered with controlplane.enabled=false"
fi
if printf '%s' "$OUT" | grep -qE "name: ${CP_NAME}([[:space:]]|$)"; then
  fail "a resource named ${CP_NAME} rendered with controlplane.enabled=false"
fi
# No generated Secret exists in the chart unless the CP auto-token renders.
[ "$(count_kind "$OUT" Secret)" = "0" ] \
  || fail "unexpected Secret rendered with controlplane.enabled=false"
echo "OK: control plane is fully off by default"

echo "=== Case 2: controlplane.enabled=true → Deployment + Service + admin-token Secret on 9100 ==="
OUT=$(render "${CP_ARGS[@]}")
# Three Deployments now: server, worker, control plane.
[ "$(count_kind "$OUT" Deployment)" = "3" ] \
  || fail "expected 3 Deployments (server+worker+controlplane), got $(count_kind "$OUT" Deployment)"
printf '%s' "$OUT" | grep -qE "name: ${CP_NAME}([[:space:]]|$)" \
  || fail "control-plane Deployment/Service named ${CP_NAME} did not render"
printf '%s' "$OUT" | grep -q "name: ${CP_TOKEN_SECRET}" \
  || fail "admin-token Secret ${CP_TOKEN_SECRET} did not render (autoGenerate default)"
[ "$(count_kind "$OUT" Secret)" = "1" ] \
  || fail "expected exactly 1 generated Secret (admin token), got $(count_kind "$OUT" Secret)"
printf '%s' "$OUT" | grep -q 'containerPort: 9100' \
  || fail "control-plane container port 9100 did not render"
printf '%s' "$OUT" | grep -q 'path: /v1/health/live' \
  || fail "control-plane liveness probe /v1/health/live did not render"
printf '%s' "$OUT" | grep -q 'path: /v1/health/ready' \
  || fail "control-plane readiness probe /v1/health/ready did not render"
echo "OK: control plane renders Deployment + Service + admin-token Secret with the expected port and probes"

echo "=== Case 3: enabled but missing controlplane.image.tag → helm must refuse ==="
if helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" \
     --set controlplane.enabled=true \
     --set controlplane.config.existingSecret=cp-config-test >/dev/null 2>&1; then
  fail "helm rendered controlplane.enabled=true without controlplane.image.tag"
fi
echo "OK: missing controlplane.image.tag rejected at render time"

echo "=== Case 4: enabled but no admin-token source → helm must refuse ==="
if render "${CP_ARGS[@]}" \
     --set controlplane.adminToken.autoGenerate=false >/dev/null 2>&1; then
  fail "helm rendered the control plane with neither adminToken.existingSecret nor autoGenerate"
fi
echo "OK: missing admin-token source rejected at render time"

echo "=== Case 5: BYO admin token (existingSecret + autoGenerate=false) → no generated Secret ==="
OUT=$(render "${CP_ARGS[@]}" \
  --set controlplane.adminToken.existingSecret=byo-admin-token \
  --set controlplane.adminToken.autoGenerate=false)
[ "$(count_kind "$OUT" Secret)" = "0" ] \
  || fail "a Secret was generated even though a BYO admin-token Secret was provided"
# The control plane still renders (Deployment present), it just references the BYO Secret.
printf '%s' "$OUT" | grep -qE "name: ${CP_NAME}([[:space:]]|$)" \
  || fail "control plane did not render in BYO-token mode"
echo "OK: BYO admin-token suppresses the generated Secret"

echo "=== Case 6: security.profile=fips with CP enabled → fips on server, worker, and control plane ==="
OUT=$(render "${CP_ARGS[@]}" --set security.profile=fips)
N=$(count_profile_value "$OUT" "fips")
[ "$N" = "3" ] \
  || fail "expected 3 fips MEM_SECURITY_PROFILE entries (server+worker+controlplane), got $N"
echo "OK: FIPS profile plumbed through to the control-plane container too"

echo "=== Case 7: controlplane.volumes/volumeMounts passthrough (CSI sync support) renders ==="
OUT=$(render "${CP_ARGS[@]}" \
  --set 'controlplane.volumes[0].name=secrets-store' \
  --set 'controlplane.volumes[0].csi.driver=secrets-store.csi.k8s.io' \
  --set 'controlplane.volumeMounts[0].name=secrets-store' \
  --set 'controlplane.volumeMounts[0].mountPath=/mnt/secrets-store')
printf '%s' "$OUT" | grep -q 'secrets-store.csi.k8s.io' \
  || fail "controlplane.volumes CSI passthrough did not render"
printf '%s' "$OUT" | grep -q 'mountPath: /mnt/secrets-store' \
  || fail "controlplane.volumeMounts passthrough did not render"
echo "OK: control-plane volumes/volumeMounts passthrough renders (enables CSI-synced Secrets)"

echo ""
echo "All control-plane chart template checks passed."
