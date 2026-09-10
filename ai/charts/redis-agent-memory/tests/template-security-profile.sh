#!/usr/bin/env bash
# template-security-profile.sh
#
# Offline chart test (no cluster required) that renders the chart with
# `helm template` under several security.profile settings and asserts the
# rendered manifests carry the expected GODEBUG FIPS mode on the server,
# worker, and bundled control-plane Deployments, and that invalid values are rejected
# at render time. See the plan "FIPS posture for on-prem Agent Memory"
# (section: Helm) — the goal is to make the security.profile contract
# regression-proof in CI without needing a live Kubernetes cluster.
#
# Usage:
#   ./memory/helm/tests/template-security-profile.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="ram-test"

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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

count_env_value() {
  local manifest="$1" name="$2" value="$3"
  printf '%s\n' "$manifest" \
    | awk -v name="$name" -v val="$value" '
        $0 ~ "name: " name "$" { want=1; next }
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

has_rbac_test_hook_annotation() {
  local manifest="$1"
  printf '%s\n' "$manifest" \
    | awk '
        /^---$/ {
          in_rbac=0
          next
        }
        /^kind:[[:space:]]+(Role|RoleBinding)$/ {
          in_rbac=1
          next
        }
        in_rbac && /helm.sh\/hook/ && /test/ {
          found=1
        }
        END { exit found ? 0 : 1 }
      '
}

echo "=== Case 1: default profile (unset) → should disable the FIPS runtime ==="
OUT=$(render)
N=$(count_env_value "$OUT" "GODEBUG" "fips140=off")
[ "$N" = "4" ] || fail "expected 4 GODEBUG=fips140=off entries (server+worker+controlplane+identity-service), got $N"
echo "OK: default profile disables the FIPS runtime on all Deployments"

echo "=== Case 2: security.profile=fips → should enable the FIPS runtime ==="
OUT=$(render --set security.profile=fips)
N=$(count_env_value "$OUT" "GODEBUG" "fips140=on")
[ "$N" = "4" ] || fail "expected 4 GODEBUG=fips140=on entries (server+worker+controlplane+identity-service), got $N"
echo "OK: fips profile enables the FIPS runtime on all Deployments"

echo "=== Case 3: invalid security.profile=bogus → helm must refuse to render ==="
if render --set security.profile=bogus >/dev/null 2>&1; then
  fail "helm rendered an invalid security.profile=bogus; values.schema.json or the validate helper is not catching it"
fi
echo "OK: invalid profile rejected at render time"

echo "=== Case 4: tests.enabled=false → helm test hooks & RBAC must NOT render ==="
OUT=$(render)
if grep -qE 'name:[[:space:]]+"?[^"]*-test-security-profile"?' <<<"$OUT"; then
  fail "security-profile test Pod rendered with tests.enabled=false"
fi
if grep -qE 'name:[[:space:]]+"?[^"]*-test-api-smoke"?' <<<"$OUT"; then
  fail "api-smoke test Pod rendered with tests.enabled=false"
fi
if grep -qE 'name:[[:space:]]+"?[^"]*-test-reader"?' <<<"$OUT"; then
  fail "test Role/RoleBinding rendered with tests.enabled=false"
fi
if grep -qE '^kind:[[:space:]]+(Role|RoleBinding)$' <<<"$OUT"; then
  fail "unexpected Role or RoleBinding rendered with tests.enabled=false"
fi
echo "OK: no test hooks or test RBAC rendered by default"

echo "=== Case 4b: supportPackage.rbac is not a supported chart value ==="
if render --set supportPackage.rbac.create=true >/dev/null 2>&1; then
  fail "helm accepted supportPackage.rbac even though support-bundle RBAC is not chart-managed"
fi
echo "OK: supportPackage.rbac is rejected by schema validation"

echo "=== Case 5: tests.enabled=true → security-profile test resources must render ==="
OUT=$(render --set tests.enabled=true)
grep -qE 'name:[[:space:]]+"?[^"]*-test-security-profile"?' <<<"$OUT" \
  || fail "security-profile test Pod did not render with tests.enabled=true"
if grep -qE 'name:[[:space:]]+"?[^"]*-test-api-smoke"?' <<<"$OUT"; then
  fail "api-smoke test Pod rendered even though tests.smoke.enabled=false"
fi
ROLE_COUNT=$(printf '%s\n' "$OUT" | awk '/^kind:[[:space:]]+Role$/ {c++} END {print c+0}')
BINDING_COUNT=$(printf '%s\n' "$OUT" | awk '/^kind:[[:space:]]+RoleBinding$/ {c++} END {print c+0}')
[ "$ROLE_COUNT" = "1" ] \
  || fail "expected exactly 1 Role when tests.enabled=true, got $ROLE_COUNT"
[ "$BINDING_COUNT" = "1" ] \
  || fail "expected exactly 1 RoleBinding when tests.enabled=true, got $BINDING_COUNT"
grep -qE 'name:[[:space:]]+"?[^"]*-test-reader"?' <<<"$OUT" \
  || fail "expected Role/RoleBinding named *-test-reader when tests.enabled=true"
if has_rbac_test_hook_annotation "$OUT"; then
  fail "test Role/RoleBinding must not be Helm test hooks; helm test --logs should only collect pod logs"
fi
if grep -q 'hook-succeeded' <<<"$OUT"; then
  fail "test Pods must stay available after success so helm test --logs can collect logs"
fi
echo "OK: security-profile test Pod, Role, and RoleBinding all render when opted in"

echo "=== Case 6: tests.enabled=true and tests.smoke.enabled=true → API smoke test must render ==="
OUT=$(render --set tests.enabled=true --set tests.smoke.enabled=true)
grep -qE 'name:[[:space:]]+"?[^"]*-test-api-smoke"?' <<<"$OUT" \
  || fail "api-smoke test Pod did not render with tests.smoke.enabled=true"
grep -q 'name: RAM_STORE_ID' <<<"$OUT" \
  || fail "api-smoke test Pod did not render RAM_STORE_ID env var"
grep -q 'value: "00000000000000000000000000000001"' <<<"$OUT" \
  || fail "api-smoke test Pod did not render the default smoke store ID"
grep -q 'activeDeadlineSeconds: 600' <<<"$OUT" \
  || fail "api-smoke test Pod did not render the default 600s activeDeadlineSeconds"
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_ENABLED" "false")
[ "$N" = "1" ] \
  || fail "expected async promotion env to default false in the smoke Pod, got $N"
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_RETRIES" "90")
[ "$N" = "1" ] \
  || fail "expected async promotion retries env to default 90, got $N"
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_RETRY_INTERVAL_SECONDS" "5")
[ "$N" = "1" ] \
  || fail "expected async promotion retry interval env to default 5, got $N"
echo "OK: API smoke test renders only when explicitly enabled"

echo "=== Case 7: async promotion settings render when explicitly enabled ==="
OUT=$(render \
  --set tests.enabled=true \
  --set tests.smoke.enabled=true \
  --set tests.smoke.asyncPromotion.enabled=true \
  --set tests.smoke.asyncPromotion.promotionRetries=9 \
  --set tests.smoke.asyncPromotion.promotionRetryIntervalSeconds=7)
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_ENABLED" "true")
[ "$N" = "1" ] \
  || fail "expected async promotion env to render true in the smoke Pod, got $N"
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_RETRIES" "9")
[ "$N" = "1" ] \
  || fail "expected async promotion retries env to render 9, got $N"
N=$(count_env_value "$OUT" "SMOKE_ASYNC_PROMOTION_RETRY_INTERVAL_SECONDS" "7")
[ "$N" = "1" ] \
  || fail "expected async promotion retry interval env to render 7, got $N"
echo "OK: async promotion smoke settings render only when explicitly enabled"

echo ""
echo "All chart template checks passed."
