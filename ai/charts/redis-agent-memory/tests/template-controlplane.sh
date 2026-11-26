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
# component adds does not read as the control plane having generated one it did
# not.
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
[ "$(count_kind "$OUT" Deployment)" = "3" ] \
  || fail "expected 3 Deployments (server+worker+controlplane), got $(count_kind "$OUT" Deployment)"
grep -qE "name: ${CP_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "control-plane Deployment/Service named ${CP_NAME} did not render"
grep -q "name: ${CP_TOKEN_SECRET}" <<<"$OUT" \
  || fail "admin-token Secret ${CP_TOKEN_SECRET} did not render (autoGenerate default)"
grep -q "name: ${CP_INTERNAL_TOKEN_SECRET}" <<<"$OUT" \
  || fail "internal-token Secret ${CP_INTERNAL_TOKEN_SECRET} did not render (autoGenerate default)"
[ "$(count_cp_secrets "$OUT")" = "2" ] \
  || fail "expected exactly 2 generated control-plane Secrets (admin + internal tokens), got $(count_cp_secrets "$OUT")"
N=$(count_fips_runtime_value "$OUT" "fips140=off")
[ "$N" = "3" ] \
  || fail "expected 3 GODEBUG=fips140=off entries (server+worker+controlplane), got $N"
grep -q 'containerPort: 9100' <<<"$OUT" \
  || fail "control-plane container port 9100 did not render"
CP_OUT=$(render --show-only templates/controlplane-deployment.yaml)
grep -q 'path: /health/liveness' <<<"$CP_OUT" \
  || fail "control-plane liveness probe /health/liveness did not render"
grep -q 'path: /health/readiness' <<<"$CP_OUT" \
  || fail "control-plane readiness probe /health/readiness did not render"
if grep -q 'path: /v1/health/' <<<"$CP_OUT"; then
  fail "control-plane deployment still uses versioned health probes"
fi
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

echo "=== Case 6: global.security.profile=fips → fips on server, worker and control plane ==="
OUT=$(render "${CP_ARGS[@]}" --set global.security.profile=fips)
N=$(count_fips_runtime_value "$OUT" "fips140=on")
[ "$N" = "3" ] \
  || fail "expected 3 GODEBUG=fips140=on entries (server+worker+controlplane), got $N"
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

echo "=== Admin recovery credential is shared by CP and DP, never the worker ==="
OUT=$(render --set controlplane.adminToken.existingSecret=shared-admin --set controlplane.adminToken.secretKey=admin --set controlplane.adminToken.existingSecretChecksum=rotated)
[ "$(grep -c 'mountPath: /etc/controlplane-onprem/admin' <<<"$OUT")" = "2" ] || fail "CP and DP must mount the admin secret"
[ "$(grep -c 'secretName: shared-admin' <<<"$OUT")" = "2" ] || fail "CP and DP must use the same secret"
[ "$(grep -c 'checksum/admin-token: \"rotated\"' <<<"$OUT")" = "2" ] || fail "CP and DP must share rotation annotations"
OUT=$(render --set config.existingSecret= --set config.render=true --set memory.profile=prod --set dataplane.identityServiceBaseURL=https://ids.example --set identityService.credential.existingSecret=memory-dp-credential --set tenantId=tenant-a)
grep -q 'admin_tenant_id: tenant-a' <<<"$OUT" || fail "DP must use the deployment admin tenant"
grep -q 'token_file: /etc/controlplane-onprem/admin/token' <<<"$OUT" || fail "DP config must use the mounted token"
OUT=$(render --set config.existingSecret= --set config.render=true --set memory.profile=dev --set memory.auth.method=none --set shared.auth.admin_tenant_id=tenant-shared)
grep -q 'admin_tenant_id: tenant-shared' <<<"$OUT" || fail "DP must use the shared control-plane admin tenant"
if render --set config.existingSecret= --set config.render=true --set memory.profile=dev --set memory.auth.method=none --set tenantId=tenant-a --set memory.auth.admin_tenant_id=tenant-b >/dev/null 2>&1; then
  fail "mismatched CP/DP admin tenants must fail"
fi
# No tenant and no claim: the DP keeps the deprecated "1" of the CP.
OUT=$(render --set config.existingSecret= --set config.render=true --set memory.profile=dev --set memory.auth.method=none)
grep -q 'admin_tenant_id: "1"' <<<"$OUT" || fail "with no tenant and no claim the DP must keep admin tenant \"1\""
# A CP tenant claim and no admin tenant: neither plane names one, so the code gives the system tenant.
CLAIM_CP=(--set config.existingSecret= --set config.render=true --set memory.profile=dev --set memory.auth.method=none
  --set-json 'controlplane.configData.auth.oidc={"enabled":true,"issuer":"https://idp.example/issuer","jwks_uri":"https://idp.example/jwks","tenant_id_claim":"tenant_id","role_mappings":{"admins":"suite_admin"}}')
OUT=$(render "${CLAIM_CP[@]}")
grep -q 'admin_tenant_id' <<<"$OUT" && fail "with a CP tenant claim neither plane may render admin_tenant_id"
if render "${CLAIM_CP[@]}" --set memory.auth.admin_tenant_id=tenant-b >/dev/null 2>&1; then
  fail "a DP admin tenant must fail when the CP takes the tenant from a claim"
fi
# With the DP admin token, both planes must have the claim, or the two admin tenants would differ.
CLAIM_AGENT_KEY=("${CLAIM_CP[@]}" --set memory.auth.method=agent_key --set dataplane.identityServiceBaseURL=https://ids.example
  --set identityService.credential.existingSecret=memory-dp-credential)
CLAIM_ERR="$(mktemp)"
if render "${CLAIM_AGENT_KEY[@]}" >"$CLAIM_ERR" 2>&1; then
  fail "a CP claim with a DP admin token and no DP claim must fail"
fi
grep -q 'set it on both controlplane.configData.auth.oidc and memory.auth.oidc' "$CLAIM_ERR" \
  || fail "the error must name both settings: $(cat "$CLAIM_ERR")"
rm -f "$CLAIM_ERR"
OUT=$(render "${CLAIM_AGENT_KEY[@]}" --set memory.auth.oidc.enabled=true --set memory.auth.oidc.issuer=https://idp.example/issuer \
  --set memory.auth.oidc.jwks_uri=https://idp.example/jwks --set memory.auth.oidc.tenant_id_claim=tenant_id)
grep -q 'admin_tenant_id' <<<"$OUT" && fail "with the claim on both planes neither plane may render admin_tenant_id"
# A claim in shared.auth.oidc reaches both planes, so the render passes.
OUT=$(render --set config.existingSecret= --set config.render=true --set memory.profile=dev --set memory.auth.method=agent_key \
  --set dataplane.identityServiceBaseURL=https://ids.example --set identityService.credential.existingSecret=memory-dp-credential \
  --set-json 'shared.auth.oidc={"enabled":true,"issuer":"https://idp.example/issuer","jwks_uri":"https://idp.example/jwks","tenant_id_claim":"tenant_id","role_mappings":{"admins":"suite_admin"}}')
grep -q 'admin_tenant_id' <<<"$OUT" && fail "with the claim in shared.auth.oidc neither plane may render admin_tenant_id"
OUT=$(render "${CLAIM_AGENT_KEY[@]}" --set controlplane.configData.auth.admin_tenant_id=ops)
grep -q 'admin_tenant_id: ops' <<<"$OUT" || fail "an explicit CP admin tenant must reach the DP"
