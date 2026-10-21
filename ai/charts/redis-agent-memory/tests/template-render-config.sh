#!/usr/bin/env bash
# template-render-config.sh
#
# Offline chart test (no cluster required) for the chart-rendered config path
# (config.render=true) and the mounted secret-overlay wiring. Asserts:
#   - config.render renders a config ConfigMap (no BYO existingSecret needed);
#   - multi-region example: each region names ONE secretName overlay that mounts
#     at /etc/ai/overlays/0 into server AND worker and is appended as a repeatable
#     --config /etc/ai/overlays/0/overlay.yaml arg after the base --config;
#   - single-region: ONE secretName overlay mounts at /etc/ai/overlays/0;
#   - BYO existingSecret with no secretName: config volume is a Secret, and there
#     are NO overlay mounts and NO overlay --config args;
#   - additionalSecrets (advanced): secretName + additionalSecrets build an
#     ordered overlay list mounted at /etc/ai/overlays/0 and /etc/ai/overlays/1,
#     appended as repeatable --config args in order so the later entry wins;
#   - base + region values deep-merge so regional overrides win;
#   - dynamic metadata and deployment embedding defaults render without store fixtures;
#   - the rendered config ConfigMap contains NO credential material and NO urls;
#   - control-plane config renders (as a ConfigMap) from the same shared block;
#   - the control plane also gets the region's overlay;
#   - fail-closed when neither existingSecret nor render is set;
#   - fail-closed when both existingSecret and render are set (mutual exclusion);
#   - examples/basic/values.yaml renders end to end using only the --set flags
#     its own header comment documents (guards the README quick start).
#
# Usage:
#   ./memory/helm/tests/template-render-config.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLES="$CHART_DIR/examples/multi-region"
RELEASE="ram-test"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The single-tenant installation tenant, as the examples set it.
TENANT_ARGS=(--set tenantId=default)

echo "=== Case 1: config.render renders a config ConfigMap from base + region ==="
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml" \
  --set image.tag=0.0.0-test --set controlplane.image.tag=cp-0.0.0-test \
  --set license.existingSecret=ram-license)"

# The rendered config body lives in a ConfigMap, not a Secret.
grep -qE "^kind: ConfigMap" <<<"$OUT" \
  || fail "no ConfigMap rendered for the config"
grep -q "memory-dataplane.config.yaml: |" <<<"$OUT" \
  || fail "rendered config carrier not found"
CONFIG_KIND="$(awk '/kind: ConfigMap/{k="ConfigMap"} /kind: Secret/{k="Secret"} /memory-dataplane.config.yaml: \|/{print k; exit}' <<<"$OUT")"
[ "$CONFIG_KIND" = "ConfigMap" ] \
  || fail "config body is carried by a $CONFIG_KIND, expected ConfigMap"
grep -q "default: eu1" <<<"$OUT" \
  || fail "region-eu request_region.default did not merge in"
grep -A1 "^[[:space:]]*ownership:" <<<"$OUT" | grep -q "enabled: false" \
  || fail "ownership enforcement default missing from rendered config"
grep -q "api: true" <<<"$OUT" \
  || fail "namespace_features.api was not rendered from the example values"
echo "OK: rendered config ConfigMap merges base + region overrides"

echo "=== Case 1b: service defaults and deployment embedding config are preserved ==="
grep -q "namespace: iris:memory" <<<"$OUT" \
  && fail "default metadata namespace should not be rendered" || true
grep -q "embedding_model: text-embedding-3-large" <<<"$OUT" \
  || fail "deployment embedding model missing from rendered config"
grep -qE "^\s*(source|stores|live):" <<<"$OUT" \
  && fail "rendered config contains removed metadata keys" || true
echo "OK: metadata namespace uses the service default and embedding config is preserved"

echo "=== Case 2: region's single overlay is mounted and passed as a --config arg ==="
OVERLAY_ARG_COUNT="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$OUT" || true)"
[ "$OVERLAY_ARG_COUNT" -ge 2 ] \
  || fail "expected overlay --config arg in both server and worker (got $OVERLAY_ARG_COUNT)"
grep -qF 'secretName: "ram-eu-secrets"' <<<"$OUT" \
  || fail "regional overlay Secret (secretName) not mounted"
grep -q "mountPath: /etc/ai/overlays/0" <<<"$OUT" \
  || fail "index-0 overlay mount path missing"
grep -q "mountPath: /etc/ai/overlays/1" <<<"$OUT" \
  && fail "region uses one Secret; unexpected second overlay mounted" || true
echo "OK: region's single secretName overlay mounted at index 0 and passed as a --config arg"

echo "=== Case 2b: single-region — ONE secretName overlay at index 0 ==="
SR_OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.existingSecret=cp-config-test \
  --set config.render=true --set memory.profile=dev --set 'memory.auth.method=none' \
  --set secrets.secretName=ram-secrets)"
SR_ARG_COUNT="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$SR_OUT" || true)"
[ "$SR_ARG_COUNT" -ge 2 ] \
  || fail "expected single-region overlay --config arg in both server and worker (got $SR_ARG_COUNT)"
grep -qF 'secretName: "ram-secrets"' <<<"$SR_OUT" \
  || fail "single-region secretName overlay not mounted"
grep -q "mountPath: /etc/ai/overlays/0" <<<"$SR_OUT" \
  || fail "single-region index-0 overlay mount path missing"
grep -q "mountPath: /etc/ai/overlays/1" <<<"$SR_OUT" \
  && fail "single-region unexpectedly mounted a second overlay" || true
echo "OK: single-region secretName mounts exactly one overlay at index 0"

echo "=== Case 2c: BYO existingSecret with no secretName — no overlays at all ==="
BYO_OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.existingSecret=cp-config-test \
  --set config.existingSecret=ram-config)"
# config volume is carried by a Secret, not a ConfigMap.
grep -q "secretName: ram-config" <<<"$BYO_OUT" \
  || fail "BYO config Secret not referenced by the config volume"
grep -q -- "/etc/ai/overlays/" <<<"$BYO_OUT" \
  && fail "BYO deployment with no secretName should have no overlay args or mounts" || true
echo "OK: BYO existingSecret with no secretName renders no overlay mounts and no overlay --config arg"

echo "=== Case 2d: additionalSecrets (advanced) layers an ordered second overlay ==="
# The examples use one Secret per region, but the chart still supports layering
# extra Secrets via additionalSecrets (later wins). Exercise that code path directly.
MULTI_OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.existingSecret=cp-config-test \
  --set config.render=true --set memory.profile=dev --set 'memory.auth.method=none' \
  --set secrets.secretName=ram-base-secrets \
  --set 'secrets.additionalSecrets[0]=ram-extra-secrets')"
# Repeatable --config: overlay 0 then overlay 1 appended after the base --config,
# in each of server and worker (so each path appears at least twice).
MULTI_ARG0="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$MULTI_OUT" || true)"
MULTI_ARG1="$(grep -c -- '- "/etc/ai/overlays/1/overlay.yaml"' <<<"$MULTI_OUT" || true)"
{ [ "$MULTI_ARG0" -ge 2 ] && [ "$MULTI_ARG1" -ge 2 ]; } \
  || fail "expected ordered overlay --config args in both server and worker (got 0:$MULTI_ARG0 1:$MULTI_ARG1)"
grep -qF 'secretName: "ram-base-secrets"' <<<"$MULTI_OUT" \
  || fail "base overlay Secret (secretName) not mounted"
grep -qF 'secretName: "ram-extra-secrets"' <<<"$MULTI_OUT" \
  || fail "layered overlay Secret (additionalSecrets) not mounted"
grep -q "mountPath: /etc/ai/overlays/1" <<<"$MULTI_OUT" \
  || fail "index-1 overlay mount path missing"
echo "OK: secretName (0) + additionalSecrets (1) mount in order and append repeatable --config args"

echo "=== Case 3: rendered config ConfigMap carries no credential material or urls ==="
CONFIG_BODY="$(awk '/memory-dataplane.config.yaml: \|/{f=1} /^---/{f=0} f' <<<"$OUT")"
grep -qiE "password:|api_key:" <<<"$CONFIG_BODY" \
  && fail "rendered config unexpectedly contains a credential field" || true
grep -qiE "urls:|redis://" <<<"$CONFIG_BODY" \
  && fail "rendered config unexpectedly contains a Redis url" || true
echo "OK: rendered config contains structure only (secrets via mounted overlays)"

echo "=== Case 4: fail-closed when neither existingSecret nor render is set ==="
if helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  --set image.tag=0.0.0-test --set license.existingSecret=lic \
  --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.existingSecret=cp-config-test >/dev/null 2>&1; then
  fail "expected failure when config source is unset"
fi
echo "OK: chart fails closed with a clear error when config source is unset"

echo "=== Case 4b: fail-closed when both existingSecret and render are set ==="
if helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  --set image.tag=0.0.0-test --set license.existingSecret=lic \
  --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.existingSecret=cp-config-test \
  --set config.existingSecret=ram-config --set config.render=true >/dev/null 2>&1; then
  fail "expected failure when both config.existingSecret and config.render are set"
fi
echo "OK: chart fails closed when config.existingSecret and config.render are both set"

echo "=== Case 4c: rendered config requires a real body ==="
if helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
 --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
 --set controlplane.image.tag=cp-0.0.0-test \
 --set controlplane.config.existingSecret=cp-config-test \
 --set config.render=true >/dev/null 2>&1; then
 fail "config.render=true without memory or shared config body unexpectedly rendered"
fi
echo "OK: rendered config without a body fails closed"

echo "=== Case 5: control-plane config renders as a ConfigMap and gets the region overlay ==="
CP_OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.image.tag=cp-0.0.0-test)"
grep -q "controlplane-onprem.config.yaml: |" <<<"$CP_OUT" \
  || fail "control-plane config carrier not rendered"
CP_KIND="$(awk '/kind: ConfigMap/{k="ConfigMap"} /kind: Secret/{k="Secret"} /controlplane-onprem.config.yaml: \|/{print k; exit}' <<<"$CP_OUT")"
[ "$CP_KIND" = "ConfigMap" ] \
  || fail "control-plane config body is carried by a $CP_KIND, expected ConfigMap"
CP_OVERLAY="$(awk '/component: controlplane/{cp=1} cp' <<<"$CP_OUT" | grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' || true)"
[ "$CP_OVERLAY" -ge 1 ] \
  || fail "control-plane deployment missing overlay --config arg"
echo "OK: control-plane config renders as a ConfigMap and gets the region overlay"

echo "=== Case 5b: auth.oidc.audience reaches the data-plane and control-plane OIDC config ==="
OIDC_ARGS=(
  "${TENANT_ARGS[@]}"
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml"
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license
  --set controlplane.image.tag=cp-0.0.0-test
  --set-json 'memory.auth.oidc={"enabled":true,"issuer":"https://idp.example/issuer","jwks_uri":"https://idp.example/jwks","role_mappings":{"admins":"suite_admin"}}'
  --set-json 'controlplane.configData.auth.oidc={"enabled":true,"issuer":"https://idp.example/issuer","jwks_uri":"https://idp.example/jwks","role_mappings":{"admins":"suite_admin"}}'
)
SHARED_AUDIENCE="api://redis-iris"
TMPDIR_ERR="$(mktemp)"
trap 'rm -f "$TMPDIR_ERR"' EXIT
GUID_AUDIENCE="6f1c2d3e-0000-4000-8000-000000000001"

render_oidc() {
  helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" "$@" \
    --show-only templates/config.yaml --show-only templates/controlplane-config.yaml
}

# Default: both services get the shared audience.
OUT="$(render_oidc)"
[ "$(grep -c -- "- $SHARED_AUDIENCE" <<<"$OUT")" = "2" ] \
  || fail "default auth.oidc.audience must reach both the data-plane and control-plane config"

# A non-default value, such as an Entra ID v2 GUID, reaches both and nothing else does.
OUT="$(render_oidc --set-string "auth.oidc.audience=$GUID_AUDIENCE")"
[ "$(grep -c -- "- $GUID_AUDIENCE" <<<"$OUT")" = "2" ] \
  || fail "a non-default auth.oidc.audience must reach both services"
grep -q "$SHARED_AUDIENCE" <<<"$OUT" && fail "the default audience leaked into a render with an override"

# There is no per-service override: an audience already written in the config
# must equal auth.oidc.audience, otherwise the render fails (this catches an old
# api://memory-dp, a wildcard, a blank value and a list).
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" \
  --set-json "memory.auth.oidc.audience=[\"$SHARED_AUDIENCE\"]" --show-only templates/config.yaml)"
[ "$(grep -c -- "- $SHARED_AUDIENCE" <<<"$OUT")" = "1" ] || fail "an explicit audience equal to auth.oidc.audience must render once"
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" \
  --set-string "memory.auth.oidc.audience=$SHARED_AUDIENCE" --show-only templates/config.yaml)"
[ "$(grep -c -- "- $SHARED_AUDIENCE" <<<"$OUT")" = "1" ] || fail "a scalar audience equal to auth.oidc.audience must render once"
for explicit in '["api://memory-dp"]' '["api://*"]' '[" "]' '["api://redis-iris","api://memory-dp"]'; do
  for target in memory.auth.oidc.audience controlplane.configData.auth.oidc.audience; do
    if helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" --set-json "$target=$explicit" >"$TMPDIR_ERR" 2>&1; then
      fail "$target=$explicit must fail the render"
    fi
    grep -q "differs from auth.oidc.audience" "$TMPDIR_ERR" || fail "$target=$explicit must explain the conflict"
  done
done

# Single-tenant alignment with a non-default tenant and no tenant claim: tenantId
# is the static tenant of both OIDC blocks. The grant tenant lives on the
# standalone Identity Service release, which this chart does not render.
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" --set-string tenantId=acme \
  --show-only templates/config.yaml --show-only templates/controlplane-config.yaml)"
[ "$(grep -c -- "static_tenant_id: acme" <<<"$OUT")" = "2" ] \
  || fail "tenantId must be the static tenant of the data-plane and control-plane OIDC blocks"
if helm template "$RELEASE" "$CHART_DIR" "${OIDC_ARGS[@]}" --set-string tenantId=acme \
  --set-string memory.auth.oidc.static_tenant_id=other >"$TMPDIR_ERR" 2>&1; then
  fail "a static OIDC tenant that differs from tenantId must fail the render"
fi
grep -q 'static_tenant_id "other" differs from tenantId "acme"' "$TMPDIR_ERR" \
  || fail "a static OIDC tenant mismatch must fail for that reason, not another one"

# OIDC off: no audience is rendered.
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" \
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.image.tag=cp-0.0.0-test)"
grep -q "$SHARED_AUDIENCE" <<<"$OUT" && fail "no audience may be rendered when OIDC is not enabled"

# A blank or wildcard audience fails the render instead of the pod at startup.
for bad in ' ' '*' 'api://*'; do
  if render_oidc --set-string "auth.oidc.audience=$bad" >/dev/null 2>&1; then
    fail "auth.oidc.audience '$bad' must fail the render"
  fi
done
echo "OK: auth.oidc.audience defaults, overrides, per-service precedence and invalid values"

echo "=== Case 5c: tenantId becomes the control plane's admin-token tenant ==="
CP_TENANT_ARGS=(
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml"
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license
  --set controlplane.image.tag=cp-0.0.0-test
  --show-only templates/controlplane-config.yaml
)
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" "${CP_TENANT_ARGS[@]}")"
[ "$(grep -c 'admin_tenant_id: default' <<<"$OUT")" = "1" ] \
  || fail "tenantId=default must render auth.admin_tenant_id: default in the control-plane config"
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${CP_TENANT_ARGS[@]}" --set-string tenantId=)"
grep -q 'admin_tenant_id' <<<"$OUT" && fail "an empty tenantId must leave auth.admin_tenant_id unset"
OUT="$(helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" "${CP_TENANT_ARGS[@]}" \
  --set-string controlplane.configData.auth.admin_tenant_id=default)"
[ "$(grep -c 'admin_tenant_id: default' <<<"$OUT")" = "1" ] \
  || fail "an explicit admin tenant equal to tenantId must render once"
if helm template "$RELEASE" "$CHART_DIR" "${TENANT_ARGS[@]}" "${CP_TENANT_ARGS[@]}" \
  --set-string controlplane.configData.auth.admin_tenant_id=other >"$TMPDIR_ERR" 2>&1; then
  fail "an explicit admin tenant that differs from tenantId must fail the render"
fi
grep -q 'auth.admin_tenant_id "other" differs from tenantId "default"' "$TMPDIR_ERR" \
  || fail "the admin tenant mismatch must explain the conflict"
echo "OK: tenantId renders the admin-token tenant, an empty tenantId omits it, a mismatch fails"

echo "=== Case 6: examples/basic renders with only the --set flags its own header documents ==="
# examples/basic/values.yaml is self-contained (license, secrets, and the
# Identity Service connection are all set in the file); its header comment says the only
# --set overrides needed at install time are the two image tags. Render with
# exactly that command so a future required-value change can't silently break
# the documented quick start without failing this test.
BASIC_OUT="$(helm template "$RELEASE" "$CHART_DIR" -f "$CHART_DIR/examples/basic/values.yaml" \
  --set image.tag=0.0.0-test --set controlplane.image.tag=cp-0.0.0-test)"
if grep -q "app.kubernetes.io/name: iris-identity-service" <<<"$BASIC_OUT"; then
  fail "examples/basic rendered Identity Service objects"
fi
grep -q "secretName: memory-dp-credential" <<<"$BASIC_OUT" \
  || fail "examples/basic did not mount the data plane's Identity Service credential"
grep -q "name: redis-agent-memory-controlplane" <<<"$BASIC_OUT" \
  || fail "examples/basic did not render the control-plane deployment"
grep -q "name: redis-agent-memory-worker" <<<"$BASIC_OUT" \
  || fail "examples/basic did not render the worker deployment"
echo "OK: examples/basic renders end to end using only its documented install-time --set flags"

echo ""
echo "All render-config chart template checks passed."
