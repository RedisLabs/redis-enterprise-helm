#!/usr/bin/env bash
# template-security-profile.sh
#
# Offline chart test (no cluster required) that renders the chart with
# `helm template` under several security.profile settings and asserts the
# rendered manifests carry the expected MEM_SECURITY_PROFILE value on both
# the server and worker Deployments, and that invalid values are rejected
# at render time. See the plan "FIPS posture for on-prem Agent Memory"
# (section: Helm) — the goal is to make the security.profile contract
# regression-proof in CI without needing a live Kubernetes cluster.
#
# Usage:
#   ./deployment/redis-agent-memory/tests/template-security-profile.sh
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
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

# Count MEM_SECURITY_PROFILE entries with the given value in the rendered
# manifest. A correctly wired chart must have exactly one match per
# Deployment (server + worker = 2).
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

echo "=== Case 1: default profile (unset) → should render as empty string ==="
OUT=$(render)
N=$(count_profile_value "$OUT" "")
[ "$N" = "2" ] || fail "expected 2 empty-profile env entries (server+worker), got $N"
echo "OK: default profile renders empty MEM_SECURITY_PROFILE on both Deployments"

echo "=== Case 2: security.profile=fips → should render 'fips' on both Deployments ==="
OUT=$(render --set security.profile=fips)
N=$(count_profile_value "$OUT" "fips")
[ "$N" = "2" ] || fail "expected 2 fips-profile env entries (server+worker), got $N"
echo "OK: fips profile plumbed through to both Deployments"

echo "=== Case 3: invalid security.profile=bogus → helm must refuse to render ==="
if render --set security.profile=bogus >/dev/null 2>&1; then
  fail "helm rendered an invalid security.profile=bogus; values.schema.json or the validate helper is not catching it"
fi
echo "OK: invalid profile rejected at render time"

echo "=== Case 4: tests.enabled=false → helm test hooks & RBAC must NOT render ==="
OUT=$(render)
if printf '%s' "$OUT" | grep -qE 'name:[[:space:]]+"?[^"]*-test-security-profile"?'; then
  fail "security-profile test Pod rendered with tests.enabled=false"
fi
if printf '%s' "$OUT" | grep -qE 'name:[[:space:]]+"?[^"]*-test-reader"?'; then
  fail "test Role/RoleBinding rendered with tests.enabled=false"
fi
if printf '%s' "$OUT" | grep -qE '^kind:[[:space:]]+(Role|RoleBinding)$'; then
  fail "unexpected Role or RoleBinding rendered with tests.enabled=false"
fi
echo "OK: no test hooks or test RBAC rendered by default"

echo "=== Case 5: tests.enabled=true → all three test resources must render ==="
OUT=$(render --set tests.enabled=true)
printf '%s' "$OUT" | grep -qE 'name:[[:space:]]+"?[^"]*-test-security-profile"?' \
  || fail "security-profile test Pod did not render with tests.enabled=true"
ROLE_COUNT=$(printf '%s\n' "$OUT" | awk '/^kind:[[:space:]]+Role$/ {c++} END {print c+0}')
BINDING_COUNT=$(printf '%s\n' "$OUT" | awk '/^kind:[[:space:]]+RoleBinding$/ {c++} END {print c+0}')
[ "$ROLE_COUNT" = "1" ] \
  || fail "expected exactly 1 Role when tests.enabled=true, got $ROLE_COUNT"
[ "$BINDING_COUNT" = "1" ] \
  || fail "expected exactly 1 RoleBinding when tests.enabled=true, got $BINDING_COUNT"
printf '%s' "$OUT" | grep -qE 'name:[[:space:]]+"?[^"]*-test-reader"?' \
  || fail "expected Role/RoleBinding named *-test-reader when tests.enabled=true"
echo "OK: test Pod, Role, and RoleBinding all render when opted in"

echo ""
echo "All chart security-profile checks passed."
