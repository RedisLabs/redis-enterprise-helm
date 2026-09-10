#!/usr/bin/env bash
# template-identity-service.sh
#
# Offline chart test (no cluster required) that renders the chart with
# `helm template` under Identity Service settings. It verifies that IdS is on by
# default, can be packaged with on-prem RAM as the first product, fails closed on
# missing credentials/config, and can be wired to another product by URL/Secret.
#
# Usage:
#   ./memory/helm/tests/template-identity-service.sh
#
# Expects:
#   - helm >= 3.x on PATH
#   - bash, awk, grep

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="ram-test"

IDS_NAME="redis-agent-memory-identity-service"
IDS_CONFIG="redis-agent-memory-identity-service-config"
IDS_CONTROL_SECRET="redis-agent-memory-identity-service-control-token"
IDS_RUNTIME_SECRET="redis-agent-memory-identity-service-runtime-memory-dp"
CP_NAME="redis-agent-memory-controlplane"
CP_CONFIG="redis-agent-memory-controlplane-config"
CP_INTERNAL_SECRET="redis-agent-memory-controlplane-internal-token"

COMMON_ARGS=(
  --set image.tag=0.0.0-test
  --set license.existingSecret=license-test
  --set config.existingSecret=config-test
  --set config.secretKey=config.yaml
  --set controlplane.image.tag=cp-0.0.0-test
  --set controlplane.config.existingSecret=cp-config-test
  # The Identity Service is enabled by default, and enabling it makes these two
  # inputs mandatory: the image tag (IdS is versioned separately from RAM) and
  # the metadata Redis overlay Secret. Cases 5 and 6 clear them on purpose.
  --set identityService.image.tag=ids-0.0.0-test
  --set identityService.metadata.existingSecret=ids-metadata
)

IDS_RAM_ARGS=(
  # Swap the BYO control-plane config for a chart-rendered one; the two are
  # mutually exclusive, so the COMMON_ARGS Secret has to be cleared first. The
  # IdS side needs nothing here — enabled and config.render are both defaults.
  --set controlplane.config.existingSecret=null
  --set controlplane.config.render=true
  --set controlplane.configData.metadata.namespace=iris-memory
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

# Key published by the generated control-plane internal-token Secret.
#
# Fed by a herestring rather than a pipe from printf: these helpers stop at the
# first match, and under `set -o pipefail` an awk that exits early leaves the
# writing end of a pipe with a broken pipe, failing the whole suite at random
# depending on whether the manifest outran the pipe buffer.
internal_token_secret_key() {
  local manifest="$1"
  awk '
      /^  name: redis-agent-memory-controlplane-internal-token$/ { found=1 }
      found && /^data:$/ { data=1; next }
      data && /^  [A-Za-z0-9_.-]+:/ { sub(/:$/, "", $1); print $1; exit }
    ' <<<"$manifest"
}

# Key the Identity Service mounts for the memory product-validation credential.
# Anchored on the volume form (name followed by `secret:`) so the matching entry
# under volumeMounts, which carries no key, is skipped.
product_validation_mounted_key() {
  local manifest="$1"
  awk '
      /- name: product-validation-memory$/ { candidate=1; next }
      candidate { if ($0 ~ /secret:$/) { volume=1 } candidate=0 }
      volume && /- key:/ { print $3; exit }
    ' <<<"$manifest"
}

count_env_value() {
  local manifest="$1" name="$2" value="$3"
  printf '%s\n' "$manifest" \
    | awk -v n="name: $name" -v v="value: \"$value\"" '
        /name:/ && $0 ~ n { want=1; next }
        want && /value:/ {
          if ($0 ~ v) { c++ }
          want=0
        }
        END { print c+0 }
      '
}

echo "=== Case 1: default (Identity Service enabled) -> IdS resources render ==="
# The data plane authenticates agent keys by introspecting against IdS, so a
# default release that omitted IdS would ship no agent-key authority at all.
OUT=$(render)
grep -q 'app.kubernetes.io/component: identity-service' <<<"$OUT" \
  || fail "Identity Service resources did not render with default values"
grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "no resource named ${IDS_NAME} rendered with default values"
grep -qE "name: ${IDS_CONFIG}([[:space:]]|$)" <<<"$OUT" \
  || fail "Identity Service ConfigMap ${IDS_CONFIG} did not render with default values"
echo "OK: Identity Service is on by default and renders its chart-owned config"

echo "=== Case 1a: explicit identityService.enabled=false -> no IdS resources render ==="
OUT=$(render --set identityService.enabled=false)
if grep -q 'app.kubernetes.io/component: identity-service' <<<"$OUT"; then
  fail "Identity Service resources rendered with identityService.enabled=false"
fi
if grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT"; then
  fail "a resource named ${IDS_NAME} rendered with identityService.enabled=false"
fi
echo "OK: Identity Service can still be turned off outright"

echo "=== Case 2: packaged with RAM -> IdS Deployment, Service, config, and credentials render ==="
OUT=$(render "${IDS_RAM_ARGS[@]}")
[ "$(count_kind "$OUT" Deployment)" = "4" ] \
  || fail "expected 4 Deployments (server+worker+controlplane+identity-service), got $(count_kind "$OUT" Deployment)"
grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "Identity Service Deployment/Service named ${IDS_NAME} did not render"
grep -qE "name: ${IDS_CONFIG}([[:space:]]|$)" <<<"$OUT" \
  || fail "Identity Service ConfigMap ${IDS_CONFIG} did not render"
grep -qE "name: ${CP_CONFIG}([[:space:]]|$)" <<<"$OUT" \
  || fail "control-plane ConfigMap ${CP_CONFIG} did not render"
grep -q "name: ${IDS_CONTROL_SECRET}" <<<"$OUT" \
  || fail "Identity Service control-token Secret did not render"
grep -q "name: ${IDS_RUNTIME_SECRET}" <<<"$OUT" \
  || fail "Identity Service runtime credential Secret did not render"
grep -q "secretName: ${CP_INTERNAL_SECRET}" <<<"$OUT" \
  || fail "packaged memory product did not mount the RAM CP internal validation token"
grep -q 'unscoped_grants_product: memory' <<<"$OUT" \
  || fail "IdS config did not claim pre-product grants for memory; every already-minted RAM key would be denied under introspection"
grep -q 'containerPort: 9200' <<<"$OUT" \
  || fail "Identity Service container port 9200 did not render"
grep -q 'value: "9200"' <<<"$OUT" \
  || fail "IDS_SERVER_PORT env value 9200 did not render"
grep -q 'path: /v1/health/live' <<<"$OUT" \
  || fail "Identity Service liveness probe /v1/health/live did not render"
grep -q 'path: /v1/health/ready' <<<"$OUT" \
  || fail "Identity Service readiness probe /v1/health/ready did not render"
grep -q 'product_validation:' <<<"$OUT" \
  || fail "rendered Identity Service config is missing product_validation"
grep -q 'base_url: http://redis-agent-memory-controlplane:9100' <<<"$OUT" \
  || fail "packaged memory product did not default validation URL to the RAM CP Service"
grep -q 'token_file: /etc/identity-service/product-validation/memory/token' <<<"$OUT" \
  || fail "rendered Identity Service config is missing the memory product-validation token_file"
grep -q 'token_file: /etc/identity-service/runtime/memory-dp/token' <<<"$OUT" \
  || fail "rendered Identity Service config is missing the stable memory runtime token_file"
grep -q 'internal_token:' <<<"$OUT" \
  || fail "rendered control-plane config is missing auth.internal_token"
grep -q 'token_file: /etc/controlplane-onprem/internal/token' <<<"$OUT" \
  || fail "rendered control-plane config is missing the internal-token file path"
grep -q 'soft_ttl_seconds: 180' <<<"$OUT" \
  || fail "rendered Identity Service config is missing runtime soft TTL"
grep -q 'hard_ttl_seconds: 300' <<<"$OUT" \
  || fail "rendered Identity Service config is missing runtime hard TTL"
echo "OK: packaged RAM path renders IdS and generic product-validation wiring"

echo "=== Case 2b: packaged memory validation follows controlplane.internalToken.secretKey ==="
# The chart points IdS at the control plane's own internal-token Secret, so the
# mounted key must be whatever that Secret publishes. Honouring the product
# credential's secretKey here would mount a key the Secret does not contain, and
# the container could not read its token_file.
OUT=$(render "${IDS_RAM_ARGS[@]}" --set controlplane.internalToken.secretKey=internal-token)
published_key=$(internal_token_secret_key "$OUT")
mounted_key=$(product_validation_mounted_key "$OUT")
[ "$published_key" = "internal-token" ] \
  || fail "renamed control-plane internal-token key did not reach the Secret, got '${published_key}'"
[ -n "$mounted_key" ] \
  || fail "could not find the IdS memory product-validation volume key"
[ "$mounted_key" = "$published_key" ] \
  || fail "IdS mounts key '${mounted_key}' but the Secret publishes '${published_key}'"
echo "OK: packaged memory validation mounts the control-plane internal-token key"

echo "=== Case 3: chart-rendered RAM DP config -> API keys use IdS introspection ==="
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set memory.default_extraction_strategy=instruct)
grep -q 'method: agent_key' <<<"$OUT" \
  || fail "rendered RAM DP config is missing auth.method=agent_key"
# There is no agent-key mode to render: the data-plane config schema has no such
# field, because IdS owns the key records and introspection is the only way to
# authenticate one. Rendering it would put a key in the config that nothing reads.
if grep -q 'mode: introspection' <<<"$OUT"; then
  fail "rendered RAM DP config still carries an auth.agent_keys.mode key"
fi
grep -q 'base_url: http://redis-agent-memory-identity-service:9200' <<<"$OUT" \
  || fail "rendered RAM DP config is missing the Identity Service runtime base URL"
grep -q 'allow_insecure_transport: true' <<<"$OUT" \
  || fail "rendered RAM DP config is missing explicit in-cluster HTTP opt-in"
grep -q 'product: memory' <<<"$OUT" \
  || fail "rendered RAM DP config is missing the memory product scope"
grep -q 'token_file: /etc/identity-service/runtime/memory-dp/token' <<<"$OUT" \
  || fail "rendered RAM DP config is missing the runtime service credential token_file"
grep -q 'mountPath: /etc/identity-service/runtime/memory-dp' <<<"$OUT" \
  || fail "RAM DP did not mount the Identity Service memory runtime credential"
grep -q "secretName: ${IDS_RUNTIME_SECRET}" <<<"$OUT" \
  || fail "RAM DP did not mount the generated memory runtime credential Secret"
echo "OK: packaged RAM DP can call IdS Runtime for API-key introspection"

echo "=== Case 3a: operators can tune the DP introspection cache and miss rate limit ==="
# The chart fills in base_url, product and credential but must not swallow the
# rest of the introspection block; these knobs are how an operator bounds
# amplification, and the README documents this path.
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set memory.default_extraction_strategy=instruct \
  --set memory.auth.agent_keys.introspection.cache.max_misses_per_window=256 \
  --set memory.auth.agent_keys.introspection.cache.miss_rate_limit_window=5s \
  --set memory.auth.agent_keys.introspection.cache.negative_ttl=45s)
grep -q 'max_misses_per_window: 256' <<<"$OUT" \
  || fail "operator-supplied max_misses_per_window did not survive chart rendering"
grep -q 'miss_rate_limit_window: 5s' <<<"$OUT" \
  || fail "operator-supplied miss_rate_limit_window did not survive chart rendering"
grep -q 'negative_ttl: 45s' <<<"$OUT" \
  || fail "operator-supplied negative_ttl did not survive chart rendering"
grep -q 'base_url: http://redis-agent-memory-identity-service:9200' <<<"$OUT" \
  || fail "chart-owned introspection base_url was lost when cache settings were supplied"
grep -q 'token_file: /etc/identity-service/runtime/memory-dp/token' <<<"$OUT" \
  || fail "chart-owned runtime credential was lost when cache settings were supplied"
echo "OK: introspection cache tuning passes through without dropping chart-owned fields"

echo "=== Case 3b: chart-rendered RAM DP config can use a named runtime credential ==="
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set memory.default_extraction_strategy=instruct \
  --set identityService.runtime.memoryCredentialName=ram-dp \
  --set identityService.runtime.serviceCredentials[0].name=ram-dp \
  --set identityService.runtime.serviceCredentials[0].subject=ram-dp \
  --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
  --set identityService.runtime.serviceCredentials[0].secretKey=token \
  --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
  --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=memory)
grep -q 'token_file: /etc/identity-service/runtime/ram-dp/token' <<<"$OUT" \
  || fail "rendered RAM DP config did not use the configured runtime credential token_file"
grep -q 'mountPath: /etc/identity-service/runtime/ram-dp' <<<"$OUT" \
  || fail "RAM DP did not mount the configured Identity Service runtime credential"
grep -q 'secretName: redis-agent-memory-identity-service-runtime-ram-dp' <<<"$OUT" \
  || fail "RAM DP did not mount the configured generated runtime credential Secret"
echo "OK: packaged RAM DP can use a configured runtime credential name"

echo "=== Case 3c: chart-rendered RAM DP config fails if the RAM runtime credential is missing ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set memory.default_extraction_strategy=instruct \
     --set identityService.runtime.serviceCredentials[0].name=ram-dp \
     --set identityService.runtime.serviceCredentials[0].subject=ram-dp \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
     --set identityService.runtime.serviceCredentials[0].secretKey=token \
     --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
     --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=memory >/dev/null 2>&1; then
  fail "helm rendered chart-owned RAM DP introspection without the configured memory runtime credential"
fi
echo "OK: missing RAM runtime credential is rejected"

echo "=== Case 3d: chart-rendered RAM DP config requires api-key-introspect on the RAM runtime credential ==="
if OUT=$(render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set memory.default_extraction_strategy=instruct \
     --set identityService.runtime.serviceCredentials[0].name=memory-dp \
     --set identityService.runtime.serviceCredentials[0].subject=memory-dp \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
     --set identityService.runtime.serviceCredentials[0].secretKey=token \
     --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=auth-me \
     --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=memory 2>&1); then
  fail "helm rendered chart-owned RAM DP introspection without api-key-introspect on the selected runtime credential"
fi
grep -q 'allowedOperations must include api-key-introspect' <<<"$OUT" \
  || fail "expected api-key-introspect validation failure, got: $OUT"
echo "OK: RAM runtime credential must include api-key-introspect"

echo "=== Case 3e: chart-rendered RAM DP config requires memory product scope on the RAM runtime credential ==="
if OUT=$(render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set memory.default_extraction_strategy=instruct \
     --set identityService.runtime.serviceCredentials[0].name=memory-dp \
     --set identityService.runtime.serviceCredentials[0].subject=memory-dp \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
     --set identityService.runtime.serviceCredentials[0].secretKey=token \
     --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
     --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=langcache 2>&1); then
  fail "helm rendered chart-owned RAM DP introspection without memory product scope on the selected runtime credential"
fi
grep -q 'allowedProducts must include memory' <<<"$OUT" \
  || fail "expected memory product-scope validation failure, got: $OUT"
echo "OK: RAM runtime credential must include memory product scope"

echo "=== Case 3f: a wildcard product on the RAM runtime credential is rejected ==="
# Product scoping carries no wildcard: "*" matches nothing, so a credential
# claiming it would authenticate and then be denied every request. The chart
# refuses it rather than rendering a credential that cannot work.
if OUT=$(render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set memory.default_extraction_strategy=instruct \
     --set identityService.runtime.serviceCredentials[0].name=memory-dp \
     --set identityService.runtime.serviceCredentials[0].subject=memory-dp \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
     --set identityService.runtime.serviceCredentials[0].secretKey=token \
     --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
     --set 'identityService.runtime.serviceCredentials[0].allowedProducts[0]=*' 2>&1); then
  fail "helm rendered chart-owned RAM DP introspection with a wildcard product scope"
fi
# "*" is now refused by the values schema, which knows the closed product set,
# before the template guard runs. Either rejection is acceptable; what must not
# happen is a rendered credential that authenticates and is then denied.
# Match "must be one of" rather than a full sentence: Helm's JSON-schema
# enum error wording differs by Helm version (e.g. "value must be one of
# 'a', 'b'" vs "must be one of the following: \"a\", \"b\""); this substring
# is common to both and to any future rewording that keeps the same meaning.
grep -qE "allowedProducts must include memory|must be one of" <<<"$OUT" \
  || fail "expected a wildcard product rejection, got: $OUT"
echo "OK: wildcard product scope is rejected for the RAM runtime credential"

echo "=== Case 3g: a real but non-memory product scope is rejected by the chart guard ==="
# Distinct from 3f: langcache passes the schema enum, so this exercises the
# template's own "must include memory" check rather than the schema.
if OUT=$(render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set memory.default_extraction_strategy=instruct \
     --set identityService.runtime.serviceCredentials[0].name=memory-dp \
     --set identityService.runtime.serviceCredentials[0].subject=memory-dp \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
     --set identityService.runtime.serviceCredentials[0].secretKey=token \
     --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
     --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=langcache 2>&1); then
  fail "helm rendered chart-owned RAM DP introspection scoped to another product"
fi
grep -q 'allowedProducts must include memory' <<<"$OUT" \
  || fail "expected the memory product-scope guard, got: $OUT"
echo "OK: the RAM runtime credential must be scoped to memory"

echo "=== Case 4: security.profile=fips -> declared profile plus effective GODEBUG ==="
# GODEBUG is what actually puts the Go runtime in FIPS mode, so every application
# container must carry it. IDS_SECURITY_PROFILE is the declared posture that the
# Identity Service verifies GODEBUG against at startup.
OUT=$(render "${IDS_RAM_ARGS[@]}" --set security.profile=fips)
[ "$(count_env_value "$OUT" IDS_SECURITY_PROFILE fips)" = "1" ] \
  || fail "expected exactly one fips IDS_SECURITY_PROFILE entry for Identity Service, got $(count_env_value "$OUT" IDS_SECURITY_PROFILE fips)"
[ "$(count_env_value "$OUT" GODEBUG fips140=on)" = "4" ] \
  || fail "expected four fips140=on GODEBUG entries (server+worker+controlplane+IdS), got $(count_env_value "$OUT" GODEBUG fips140=on)"

OUT=$(render "${IDS_RAM_ARGS[@]}")
[ "$(count_env_value "$OUT" GODEBUG fips140=off)" = "4" ] \
  || fail "expected four fips140=off GODEBUG entries without security.profile, got $(count_env_value "$OUT" GODEBUG fips140=off)"
echo "OK: chart renders effective GODEBUG for every container alongside the IdS declared profile"

echo "=== Case 5: enabled but missing identityService.image.tag -> helm must refuse ==="
if render \
     --set identityService.image.tag= \
     --set identityService.config.render=false \
     --set identityService.config.existingSecret=ids-config >/dev/null 2>&1; then
  fail "helm rendered identityService.enabled=true without identityService.image.tag"
fi
echo "OK: missing identityService.image.tag rejected at render time"

echo "=== Case 6: rendered config without metadata Secret -> helm must refuse ==="
if render --set identityService.metadata.existingSecret= >/dev/null 2>&1; then
  fail "helm rendered chart-owned IdS config without metadata Secret overlay"
fi
echo "OK: chart-rendered IdS config requires metadata Secret overlay"

echo "=== Case 7: memory product resolves against the bundled RAM CP ==="
# The control plane is always bundled (MOD-17629 removed controlplane.enabled),
# so the memory product no longer needs baseURL/credential to be set by hand.
if ! render "${IDS_RAM_ARGS[@]}" >/dev/null 2>&1; then
  fail "helm refused the packaged memory product against the bundled RAM CP"
fi
echo "OK: packaged memory product resolves against the bundled RAM CP"

echo "=== Case 8: IdS control token reuses RAM CP admin token -> helm must refuse ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.controlToken.existingSecret=redis-agent-memory-controlplane-admin-token \
     --set identityService.controlToken.autoGenerate=false >/dev/null 2>&1; then
  fail "helm rendered IdS control token reusing RAM CP admin token"
fi
echo "OK: IdS control token cannot reuse RAM CP admin token"

echo "=== Case 9: IdS runtime credential reuses IdS control token -> helm must refuse ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.runtime.serviceCredentials[0].existingSecret=redis-agent-memory-identity-service-control-token \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=false >/dev/null 2>&1; then
  fail "helm rendered IdS runtime credential reusing the IdS control token"
fi
echo "OK: IdS runtime credentials cannot reuse the IdS control token"

echo "=== Case 10: IdS runtime credential reuses product-validation credential -> helm must refuse ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.runtime.serviceCredentials[0].existingSecret=redis-agent-memory-controlplane-internal-token \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=false >/dev/null 2>&1; then
  fail "helm rendered IdS runtime credential reusing a product-validation credential"
fi
echo "OK: IdS runtime credentials cannot reuse product-validation credentials"

echo "=== Case 11: external product validation bypasses the RAM CP wiring ==="
OUT=$(render \
  --set identityService.runtime.serviceCredentials[0].name=langcache-dp \
  --set identityService.runtime.serviceCredentials[0].subject=langcache-dp \
  --set identityService.runtime.serviceCredentials[0].autoGenerate=true \
  --set identityService.runtime.serviceCredentials[0].secretKey=token \
  --set identityService.runtime.serviceCredentials[0].allowedOperations[0]=api-key-introspect \
  --set identityService.runtime.serviceCredentials[0].allowedProducts[0]=langcache \
  --set identityService.productValidation.products.memory.enabled=false \
  --set identityService.productValidation.products.langcache.enabled=true \
  --set identityService.productValidation.products.langcache.baseURL=http://langcache-controlplane:9100 \
  --set identityService.productValidation.products.langcache.credential.existingSecret=langcache-controlplane-internal-token)
grep -qE "name: ${IDS_NAME}([[:space:]]|$)" <<<"$OUT" \
  || fail "Identity Service did not render for an external product-only configuration"
grep -q 'langcache:' <<<"$OUT" \
  || fail "rendered Identity Service config is missing langcache product validation"
grep -q 'base_url: http://langcache-controlplane:9100' <<<"$OUT" \
  || fail "rendered Identity Service config is missing langcache validation URL"
# The control plane is always bundled, so its presence proves nothing here. What
# matters is that an external product's validation does not reach for RAM CP
# wiring: no memory product entry, and no RAM internal-token mount.
if grep -q 'base_url: http://redis-agent-memory-controlplane' <<<"$OUT"; then
  fail "disabled memory product still rendered validation wiring"
fi
# Not asserted here: the absence of the RAM CP internal-token Secret. The control
# plane is always bundled and publishes that Secret for its own use, so its
# presence says nothing about how IdS is wired.
grep -q 'langcache-controlplane-internal-token' <<<"$OUT" \
  || fail "langcache validation is not wired to its own credential Secret"
# unscopedGrantsProduct still defaults to memory here, but memory is not a
# configured validator — IdS rejects an owner it has no product for, so emitting
# it would render a config the service refuses to start with.
if grep -q 'unscoped_grants_product' <<<"$OUT"; then
  fail "IdS config claimed pre-product grants for a product this release does not configure; the service would fail startup validation"
fi
echo "OK: non-RAM products join through explicit URL/Secret without RAM CP wiring"

echo "=== Case 12: duplicate runtime credential Secret/key refs -> helm must refuse ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.runtime.serviceCredentials[0].existingSecret=shared-runtime-token \
     --set identityService.runtime.serviceCredentials[0].autoGenerate=false \
     --set identityService.runtime.serviceCredentials[1].name=langcache-dp \
     --set identityService.runtime.serviceCredentials[1].subject=langcache-dp \
     --set identityService.runtime.serviceCredentials[1].existingSecret=shared-runtime-token \
     --set identityService.runtime.serviceCredentials[1].autoGenerate=false \
     --set identityService.runtime.serviceCredentials[1].secretKey=token \
     --set identityService.runtime.serviceCredentials[1].allowedOperations[0]=api-key-introspect \
     --set identityService.runtime.serviceCredentials[1].allowedProducts[0]=langcache >/dev/null 2>&1; then
  fail "helm rendered two runtime credentials using the same Secret/key"
fi
echo "OK: IdS runtime credentials cannot alias the same Secret/key"

echo "=== Case 13: credential-bearing product validation URL -> helm must refuse ==="
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.productValidation.products.memory.baseURL='http://user:pass@redis-agent-memory-controlplane:9100' >/dev/null 2>&1; then
  fail "helm rendered a product validation baseURL with user info"
fi
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.productValidation.products.memory.baseURL='http://redis-agent-memory-controlplane:9100?token=secret' >/dev/null 2>&1; then
  fail "helm rendered a product validation baseURL with query parameters"
fi
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.productValidation.products.memory.baseURL='http://redis-agent-memory-controlplane:9100#secret' >/dev/null 2>&1; then
  fail "helm rendered a product validation baseURL with a fragment"
fi
echo "OK: product validation base URLs cannot carry credential-bearing components"

echo "=== Case 13a: non-http product validation URL -> helm must refuse ==="
# The Identity Service rejects a non-http(s) base_url during config validation,
# so without this guard a bad scheme passes helm install and only surfaces as a
# crash-looping pod.
for bad_url in "ftp://langcache-controlplane:9100" "langcache-controlplane:9100" "//langcache-controlplane:9100"; do
  if render "${IDS_RAM_ARGS[@]}" \
       --set identityService.productValidation.products.langcache.enabled=true \
       --set "identityService.productValidation.products.langcache.baseURL=${bad_url}" \
       --set identityService.productValidation.products.langcache.credential.existingSecret=langcache-token >/dev/null 2>&1; then
    fail "helm accepted a product validation baseURL the service rejects: ${bad_url}"
  fi
done
echo "OK: product validation base URLs must be absolute http(s)"

echo "=== Case 13b: misspelled unscopedGrantsProduct -> helm must refuse ==="
# A typo used to be dropped silently, which denies every pre-product key at
# runtime instead of failing the render. The values schema now holds this field
# to the closed product set, so the misspelling fails before rendering. A real
# product that this deployment does not configure is still omitted on purpose
# (Case 11 covers that path).
if render "${IDS_RAM_ARGS[@]}" \
     --set identityService.runtime.unscopedGrantsProduct=memoryy >/dev/null 2>&1; then
  fail "helm accepted a misspelled unscopedGrantsProduct"
fi
echo "OK: unscopedGrantsProduct is held to the known product set"

echo "=== Case 14: all product validators disabled -> helm must refuse ==="
if render \
     --set identityService.config.render=false \
     --set identityService.config.existingSecret=ids-config \
     --set identityService.productValidation.products.memory.enabled=false >/dev/null 2>&1; then
  fail "helm rendered Identity Service with no enabled product validators"
fi
echo "OK: IdS requires at least one enabled product validator"

echo "=== Case 15: security.profile=fips -> helm must refuse to default introspection to plaintext ==="
# The in-cluster default is http:// paired with allow_insecure_transport, which
# under FIPS would carry agent-key material in the clear. The chart must refuse
# rather than render a config the data plane rejects at startup with a flag the
# operator never wrote.
if render "${IDS_RAM_ARGS[@]}" \
     --set config.existingSecret= \
     --set config.render=true \
     --set security.profile=fips >/dev/null 2>&1; then
  fail "helm defaulted the Identity Service introspection endpoint to plaintext under security.profile=fips"
fi
echo "OK: FIPS profile refuses a defaulted plaintext introspection endpoint"

echo "=== Case 15a: security.profile=fips + explicit https base_url -> renders ==="
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set security.profile=fips \
  --set memory.auth.agent_keys.introspection.base_url=https://identity.internal:9443)
grep -q 'base_url: https://identity.internal:9443' <<<"$OUT" \
  || fail "operator-supplied https introspection base_url was not rendered under FIPS"
if grep -q 'allow_insecure_transport: true' <<<"$OUT"; then
  fail "FIPS render still opted into insecure transport for introspection"
fi
echo "OK: FIPS profile renders with an operator-supplied TLS introspection endpoint"

echo "=== Case 16: IdS disabled with no auth posture chosen -> helm must refuse ==="
# Disabling IdS does not disable agent-key auth: the data plane defaults an
# unspecified method to agent_key and then dies demanding an introspection
# endpoint nobody rendered. Regression guard for a Bugbot finding on this PR.
if render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set identityService.enabled=false >/dev/null 2>&1; then
  fail "helm rendered an IdS-disabled release with no auth posture, which cannot start"
fi
echo "OK: disabling IdS without choosing an auth posture is refused"

echo "=== Case 16a: IdS disabled + auth.method=none -> renders ==="
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set identityService.enabled=false \
  --set memory.auth.method=none)
grep -q 'method: none' <<<"$OUT" \
  || fail "explicit auth.method=none was not rendered with IdS disabled"
echo "OK: IdS disabled behind an infrastructure boundary renders"

echo "=== Case 16b: IdS disabled + externally managed IdS introspection -> renders ==="
OUT=$(render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set identityService.enabled=false \
  --set memory.auth.agent_keys.enabled=true \
  --set memory.auth.agent_keys.introspection.base_url=https://identity.external:9443)
grep -q 'base_url: https://identity.external:9443' <<<"$OUT" \
  || fail "agent keys pointed at an unmanaged Identity Service were not rendered"
echo "OK: IdS disabled with an externally managed Identity Service renders"

echo "=== Case 16c: IdS disabled + explicit auth.method=agent_key with no introspection base_url -> helm must refuse ==="
# Explicitly choosing agent_key satisfies the "a posture was chosen" check
# (Case 16) but is not renderable without an introspection base_url once IdS
# is disabled. Regression guard for a gap found in a deep-review of #1214.
if render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set identityService.enabled=false \
  --set memory.auth.method=agent_key >/dev/null 2>&1; then
  fail "helm rendered agent_key auth with IdS disabled and no introspection base_url, which cannot start"
fi
echo "OK: explicit agent_key auth without an introspection base_url is refused"

echo "=== Case 16d: IdS disabled + agent_keys.enabled=true with no method or introspection base_url -> helm must refuse ==="
# Sibling of Case 16c: agent_keys.enabled=true resolves to agent-key auth just
# like an explicit method=agent_key, so it must be refused the same way.
if render "${IDS_RAM_ARGS[@]}" \
  --set config.existingSecret= \
  --set config.render=true \
  --set identityService.enabled=false \
  --set memory.auth.agent_keys.enabled=true >/dev/null 2>&1; then
  fail "helm rendered agent_keys.enabled=true with IdS disabled and no introspection base_url, which cannot start"
fi
echo "OK: agent_keys.enabled=true without an introspection base_url is refused"

echo ""
echo "All Identity Service chart template checks passed."
