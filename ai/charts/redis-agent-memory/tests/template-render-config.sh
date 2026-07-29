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
#   - metadata.stores is a map keyed by store id and keeps a store's fields;
#   - the rendered config ConfigMap contains NO credential material and NO urls;
#   - control-plane config renders (as a ConfigMap) from the same shared block;
#   - the control plane also gets the region's overlay;
#   - fail-closed when neither existingSecret nor render is set;
#   - fail-closed when both existingSecret and render are set (mutual exclusion).
#
# Usage:
#   ./deployment/redis-agent-memory/tests/template-render-config.sh
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

echo "=== Case 1: config.render renders a config ConfigMap from base + region ==="
OUT="$(helm template "$RELEASE" "$CHART_DIR" \
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license)"

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
echo "OK: rendered config ConfigMap merges base + region overrides"

echo "=== Case 1b: metadata.stores is a map keyed by id, structure preserved ==="
grep -qE '^\s*"00000000000000000000000000000001":' <<<"$OUT" \
  || fail "metadata.stores is not keyed by store id"
grep -q "ttl_seconds: 86400" <<<"$OUT" \
  || fail "store short_memory.ttl_seconds missing from rendered config"
grep -q "embedding_model: text-embedding-3-large" <<<"$OUT" \
  || fail "store long_term_memory missing from rendered config"
grep -qE "^\s*storesByID:" <<<"$OUT" \
  && fail "rendered config still contains storesByID (removed helper)" || true
echo "OK: stores map keyed by id, structural fields preserved"

echo "=== Case 2: region's single overlay is mounted and passed as a --config arg ==="
OVERLAY_ARG_COUNT="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$OUT" || true)"
[ "$OVERLAY_ARG_COUNT" -ge 2 ] \
  || fail "expected overlay --config arg in both server and worker (got $OVERLAY_ARG_COUNT)"
grep -q "secretName: ram-eu-secrets" <<<"$OUT" \
  || fail "regional overlay Secret (secretName) not mounted"
grep -q "mountPath: /etc/ai/overlays/0" <<<"$OUT" \
  || fail "index-0 overlay mount path missing"
grep -q "mountPath: /etc/ai/overlays/1" <<<"$OUT" \
  && fail "region uses one Secret; unexpected second overlay mounted" || true
echo "OK: region's single secretName overlay mounted at index 0 and passed as a --config arg"

echo "=== Case 2b: single-region — ONE secretName overlay at index 0 ==="
SR_OUT="$(helm template "$RELEASE" "$CHART_DIR" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set config.render=true --set 'memory.metadata.source=static' \
  --set secrets.secretName=ram-secrets)"
SR_ARG_COUNT="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$SR_OUT" || true)"
[ "$SR_ARG_COUNT" -ge 2 ] \
  || fail "expected single-region overlay --config arg in both server and worker (got $SR_ARG_COUNT)"
grep -q "secretName: ram-secrets" <<<"$SR_OUT" \
  || fail "single-region secretName overlay not mounted"
grep -q "mountPath: /etc/ai/overlays/0" <<<"$SR_OUT" \
  || fail "single-region index-0 overlay mount path missing"
grep -q "mountPath: /etc/ai/overlays/1" <<<"$SR_OUT" \
  && fail "single-region unexpectedly mounted a second overlay" || true
echo "OK: single-region secretName mounts exactly one overlay at index 0"

echo "=== Case 2c: BYO existingSecret with no secretName — no overlays at all ==="
BYO_OUT="$(helm template "$RELEASE" "$CHART_DIR" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
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
MULTI_OUT="$(helm template "$RELEASE" "$CHART_DIR" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set config.render=true --set 'memory.metadata.source=static' \
  --set secrets.secretName=ram-base-secrets \
  --set 'secrets.additionalSecrets[0]=ram-extra-secrets')"
# Repeatable --config: overlay 0 then overlay 1 appended after the base --config,
# in each of server and worker (so each path appears at least twice).
MULTI_ARG0="$(grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' <<<"$MULTI_OUT" || true)"
MULTI_ARG1="$(grep -c -- '- "/etc/ai/overlays/1/overlay.yaml"' <<<"$MULTI_OUT" || true)"
{ [ "$MULTI_ARG0" -ge 2 ] && [ "$MULTI_ARG1" -ge 2 ]; } \
  || fail "expected ordered overlay --config args in both server and worker (got 0:$MULTI_ARG0 1:$MULTI_ARG1)"
grep -q "secretName: ram-base-secrets" <<<"$MULTI_OUT" \
  || fail "base overlay Secret (secretName) not mounted"
grep -q "secretName: ram-extra-secrets" <<<"$MULTI_OUT" \
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
if helm template "$RELEASE" "$CHART_DIR" \
  --set image.tag=0.0.0-test --set license.existingSecret=lic >/dev/null 2>&1; then
  fail "expected failure when config source is unset"
fi
echo "OK: chart fails closed with a clear error when config source is unset"

echo "=== Case 4b: fail-closed when both existingSecret and render are set ==="
if helm template "$RELEASE" "$CHART_DIR" \
  --set image.tag=0.0.0-test --set license.existingSecret=lic \
  --set config.existingSecret=ram-config --set config.render=true >/dev/null 2>&1; then
  fail "expected failure when both config.existingSecret and config.render are set"
fi
echo "OK: chart fails closed when config.existingSecret and config.render are both set"

echo "=== Case 5: control-plane config renders as a ConfigMap and gets the region overlay ==="
CP_OUT="$(helm template "$RELEASE" "$CHART_DIR" \
  -f "$EXAMPLES/base-values.yaml" -f "$EXAMPLES/region-eu.yaml" \
  --set image.tag=0.0.0-test --set license.existingSecret=ram-license \
  --set controlplane.enabled=true --set controlplane.image.tag=cp-0.0.0-test \
  --set controlplane.config.render=true \
  --set-json 'controlplane.configData={"metadata":{"namespace":"iris:memory"},"embedding":{"dimensions":3072}}')"
grep -q "controlplane-onprem.config.yaml: |" <<<"$CP_OUT" \
  || fail "control-plane config carrier not rendered"
CP_KIND="$(awk '/kind: ConfigMap/{k="ConfigMap"} /kind: Secret/{k="Secret"} /controlplane-onprem.config.yaml: \|/{print k; exit}' <<<"$CP_OUT")"
[ "$CP_KIND" = "ConfigMap" ] \
  || fail "control-plane config body is carried by a $CP_KIND, expected ConfigMap"
CP_OVERLAY="$(awk '/component: controlplane/{cp=1} cp' <<<"$CP_OUT" | grep -c -- '- "/etc/ai/overlays/0/overlay.yaml"' || true)"
[ "$CP_OVERLAY" -ge 1 ] \
  || fail "control-plane deployment missing overlay --config arg"
echo "OK: control-plane config renders as a ConfigMap and gets the region overlay"

echo ""
echo "All render-config chart template checks passed."
