#!/usr/bin/env bash
# template-identity-service.sh
#
# Offline chart test (no cluster required) for how redis-agent-memory connects
# to an Identity Service release it does not deploy (MOD-19272): the data
# plane's endpoint and credential, the control plane's internal token, the
# parent guards, the withdrawn bundled keys and the global.* fallbacks.
# Identity Service behaviour is covered by
# identity-service/helm/tests/template-identity-service.sh.
#
# Usage:
#   helm dependency build memory/helm
#   ./memory/helm/tests/template-identity-service.sh
#
# Expects helm >= 3.x, bash, awk, grep, jq.

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="ram-test"
TOKEN_PATH="/etc/identity-service/runtime/memory-dp/token"

COMMON_ARGS=(
  --set image.tag=0.0.0-test
  --set license.existingSecret=license-test
  --set controlplane.image.tag=cp-0.0.0-test
  --set-string tenantId=default
  # Chart-rendered data-plane and control-plane config, where the chart writes
  # the introspection and internal-token wiring.
  --set config.render=true
  --set memory.default_extraction_strategy=instruct
  --set controlplane.config.render=true
  --set controlplane.configData.metadata.namespace=iris-memory
)

# The connection contract: the Identity Service release's URL and the data
# plane's automation-provisioned credential.
CONNECTION=(
  --set dataplane.identityServiceBaseURL=https://ids.example
  --set identityService.credential.existingSecret=memory-dp-credential
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render() {
  helm template "$RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "$@"
}

has() {
  grep -qF -- "$2" <<<"$1" || fail "${3:-expected}: missing '$2'"
}

lacks() {
  if grep -qF -- "$2" <<<"$1"; then fail "${3:-unexpected}: found '$2'"; fi
}

# Asserts rendering fails with message $1.
rejects() {
  local want="$1" out
  shift
  if out=$(render "$@" 2>&1); then fail "rendered, expected failure: $want"; fi
  grep -qF -- "$want" <<<"$out" || fail "expected error '$want', got: $out"
}

# One manifest document by kind and metadata.name.
doc() {
  awk -v RS='\n---\n' -v kind="kind: $2" -v name="  name: $3" '
    index("\n" $0 "\n", "\n" kind "\n") && index("\n" $0 "\n", "\n" name "\n") { print; exit }
  ' <<<"$1"
}

echo "=== No Identity Service dependency or objects ==="
LOCK="$(cat "$CHART_DIR/Chart.lock")"
has "$LOCK" "name: redis-iris-onprem-lib"
lacks "$LOCK" "iris-identity-service" "Chart.lock"
lacks "$(cat "$CHART_DIR/Chart.yaml")" "iris-identity-service" "Chart.yaml"
if ls "$CHART_DIR"/charts/iris-identity-service-*.tgz >/dev/null 2>&1; then
  fail "an iris-identity-service chart is vendored under charts/"
fi
OUT=$(render "${CONNECTION[@]}" --set tests.enabled=true)
lacks "$OUT" "app.kubernetes.io/name: iris-identity-service" "objects labelled iris-identity-service"
echo "OK"

echo "=== Data plane connection ==="
DP_DEPLOYMENT="$(doc "$OUT" Deployment redis-agent-memory)"
has "$DP_DEPLOYMENT" "secretName: memory-dp-credential" "DP mounts the referenced Secret"
has "$DP_DEPLOYMENT" "mountPath: /etc/identity-service/runtime/memory-dp"
lacks "$DP_DEPLOYMENT" "checksum/dp-credential" "no checksum without existingSecretChecksum"
DP_CONFIG="$(doc "$OUT" ConfigMap redis-agent-memory-config)"
has "$DP_CONFIG" "method: agent_key"
has "$DP_CONFIG" "base_url: https://ids.example"
has "$DP_CONFIG" "allow_insecure_transport: false"
has "$DP_CONFIG" "product: memory"
has "$DP_CONFIG" "token_file: $TOKEN_PATH"
OUT=$(render "${CONNECTION[@]}" --set identityService.credential.secretKey=dp-token \
  --set identityService.credential.existingSecretChecksum=abc123)
DP_DEPLOYMENT="$(doc "$OUT" Deployment redis-agent-memory)"
has "$DP_DEPLOYMENT" "checksum/dp-credential: \"abc123\""
has "$DP_DEPLOYMENT" "key: dp-token" "DP mounts the configured secretKey"
OUT=$(render "${CONNECTION[@]}" \
  --set memory.auth.agent_keys.introspection.cache.max_misses_per_window=256 \
  --set memory.auth.agent_keys.introspection.cache.negative_ttl=45s)
has "$OUT" "max_misses_per_window: 256" "introspection cache tuning passes through"
has "$OUT" "negative_ttl: 45s"
echo "OK"

echo "=== Control-plane internal token ==="
OUT=$(render "${CONNECTION[@]}")
has "$(doc "$OUT" ConfigMap redis-agent-memory-controlplane-config)" "token_file: /etc/controlplane-onprem/internal/token"
OUT=$(render "${CONNECTION[@]}" --set memory.profile=dev --set memory.auth.method=none)
has "$(doc "$OUT" ConfigMap redis-agent-memory-controlplane-config)" "token_file: /etc/controlplane-onprem/internal/token" \
  "internal token wired without agent-key auth"
OUT=$(render "${CONNECTION[@]}" --set controlplane.internalToken.existingSecret=memory-cp-internal-token)
has "$(doc "$OUT" Deployment redis-agent-memory-controlplane)" "secretName: memory-cp-internal-token"
[ -z "$(doc "$OUT" Secret redis-agent-memory-controlplane-internal-token)" ] \
  || fail "generated an internal-token Secret despite existingSecret"
echo "OK"

echo "=== Required connection under agent-key auth ==="
rejects "requires dataplane.identityServiceBaseURL" --set identityService.credential.existingSecret=memory-dp-credential
rejects "requires identityService.credential.existingSecret" --set dataplane.identityServiceBaseURL=https://ids.example
rejects "requires dataplane.identityServiceBaseURL" --set memory.auth.method=agent_key
OUT=$(render --set memory.profile=dev --set memory.auth.method=none) || fail "memory.auth.method=none without a connection did not render"
render --set shared.profile=dev --set shared.auth.method=none >/dev/null || fail "shared.auth.method=none without a connection did not render"
lacks "$OUT" "identity-service-runtime-memory-dp" "no credential mount without a credential"
rejects "memory.auth.method=none is allowed only with memory.profile=dev" --set memory.auth.method=none
rejects "memory.auth.method=none is allowed only with memory.profile=dev" --set shared.auth.method=none
# The binary normalizes the method but compares the profile exactly.
rejects "memory.auth.method=none is allowed only with memory.profile=dev" --set "memory.auth.method= None "
render --set memory.profile=dev --set "memory.auth.method= None " >/dev/null \
  || fail "an un-normalized none method with profile dev did not render"
rejects "memory.auth.method=none is allowed only with memory.profile=dev" --set memory.profile=DEV --set memory.auth.method=none
render --set config.render=false --set config.existingSecret=config-test >/dev/null \
  || fail "a BYO data-plane config without a connection did not render"
# An unset method defaults to agent_key only when no other flavour is on,
# matching the data plane's applyAuthDefaults.
# shared.* is merged under memory.*, so a flavour declared there counts too.
for flavour in memory.auth.oidc.enabled memory.auth.sm_cloud.enabled memory.auth.worker_identity.enabled shared.auth.oidc.enabled; do
  OUT=$(render --set "$flavour=true") || fail "$flavour with an unset method required a connection"
  lacks "$(doc "$OUT" ConfigMap redis-agent-memory-config)" "agent_key" "$flavour rendered agent-key auth"
done
rejects "requires dataplane.identityServiceBaseURL" \
  --set memory.auth.oidc.enabled=true --set memory.auth.agent_keys.enabled=true
# A subject with the identity_service authority (every legacy service_subjects
# entry) looks its grants up through the introspection client, so it needs the
# connection even when another flavour leaves the method unset.
SUBJECTS=(--set memory.auth.oidc.enabled=true --set memory.auth.service_subjects.enabled=true
  --set 'memory.auth.service_subjects.subjects[0]=system:serviceaccount:pb:worker')
JWT_SUBJECT='[{"issuer":"https://k8s","subjects":[{"subject":"w","authority":"identity_service"}]}]'
rejects "requires dataplane.identityServiceBaseURL" "${SUBJECTS[@]}"
rejects "requires identityService.credential.existingSecret" "${SUBJECTS[@]}" \
  --set dataplane.identityServiceBaseURL=https://ids.example
rejects "requires dataplane.identityServiceBaseURL" \
  --set memory.auth.oidc.enabled=true --set-json "memory.auth.jwt_subjects=$JWT_SUBJECT"
render --set memory.auth.oidc.enabled=true \
  --set-json "memory.auth.jwt_subjects=${JWT_SUBJECT/identity_service/static}" >/dev/null \
  || fail "static-authority jwt_subjects required a connection"
CFG="$(doc "$(render "${CONNECTION[@]}" "${SUBJECTS[@]}")" ConfigMap redis-agent-memory-config)"
has "$CFG" "base_url: https://ids.example" "service subjects get the introspection endpoint"
has "$CFG" "token_file: /etc/identity-service/runtime/memory-dp/token" "service subjects get the credential"
lacks "$CFG" "method: agent_key" "service subjects alone forced agent-key auth"
# The binary builds the grant-lookup client only with agent_keys.enabled.
has "$(grep -A1 'agent_keys:' <<<"$CFG")" "enabled: true" "service subjects get the agent-key client"
rejects "requires auth.agent_keys.enabled" "${CONNECTION[@]}" "${SUBJECTS[@]}" \
  --set memory.auth.agent_keys.enabled=false
echo "OK"

echo "=== Transport security ==="
rejects 'dataplane.identityServiceBaseURL "http://ids:9200" must be https://' \
  "${CONNECTION[@]}" --set dataplane.identityServiceBaseURL=http://ids:9200
OUT=$(render "${CONNECTION[@]}" --set dataplane.identityServiceBaseURL=http://ids:9200 \
  --set identityService.allowInsecureTransport=true)
has "$OUT" "base_url: http://ids:9200"
has "$OUT" "allow_insecure_transport: true"
rejects "identityService.allowInsecureTransport=true is refused under the fips security profile" \
  "${CONNECTION[@]}" --set dataplane.identityServiceBaseURL=http://ids:9200 \
  --set identityService.allowInsecureTransport=true --set global.security.profile=fips
rejects "identityService.allowInsecureTransport=true is refused under the fips security profile" \
  "${CONNECTION[@]}" --set identityService.allowInsecureTransport=true --set security.profile=fips
rejects "must be https://" "${CONNECTION[@]}" --set dataplane.identityServiceBaseURL=http://ids:9200 --set security.profile=fips
render "${CONNECTION[@]}" --set security.profile=fips >/dev/null || fail "fips with an https:// URL did not render"
echo "OK"

echo "=== Chart-owned introspection keys ==="
# shared merges under memory in the rendered config, so both sources are guarded,
# also with agent-key auth off, where the keys would still reach the ConfigMap.
for source in memory shared; do
  for key in base_url=http://x credential.token_file=/x allow_insecure_transport=true; do
    rejects "$source.auth.agent_keys.introspection.${key%%[.=]*} is chart-owned" \
      "${CONNECTION[@]}" --set "$source.auth.agent_keys.introspection.$key"
  done
  rejects "$source.auth.agent_keys.introspection.allow_insecure_transport is chart-owned" \
    "${CONNECTION[@]}" --set memory.profile=dev --set memory.auth.method=none --set "$source.auth.agent_keys.introspection.allow_insecure_transport=true"
done
echo "OK"

echo "=== Withdrawn bundled keys ==="
for key in identityService.enabled=false externalIdentityService.allowInsecureTransport=true \
  identityService.metadata.existingSecret=m identityService.image.tag=x identityService.nameOverride=x \
  identityService.runtime.apiKeyTenant.singleTenantID=default; do
  if out=$(render "${CONNECTION[@]}" --set "$key" 2>&1); then fail "schema accepted withdrawn $key"; fi
  grep -qi "schema" <<<"$out" || fail "$key: expected a schema error, got: $out"
done
echo "OK"

echo "=== No cross-chart checks ==="
# tenantId only stamps Memory's own oidc blocks; nothing compares it with the
# Identity Service release.
OUT=$(render "${CONNECTION[@]}" --set-string tenantId=other \
  --set memory.auth.oidc.enabled=true --set controlplane.configData.auth.oidc.enabled=true \
  --set memory.auth.oidc.issuer=https://idp.example --set controlplane.configData.auth.oidc.issuer=https://idp.example)
[ "$(grep -c 'static_tenant_id: other' <<<"$OUT")" = "2" ] \
  || fail "tenantId did not stamp both the DP and CP oidc static tenant"
echo "OK"

echo "=== global.* fallbacks ==="
OUT=$(render "${CONNECTION[@]}" --set-json 'global.imagePullSecrets=[{"name":"g"}]' \
  --set global.tls.caCertSecret=ca --set global.security.profile=fips)
for name in redis-agent-memory redis-agent-memory-worker redis-agent-memory-controlplane; do
  DEPLOYMENT="$(doc "$OUT" Deployment "$name")"
  has "$DEPLOYMENT" "- name: g" "global.imagePullSecrets on $name"
  has "$DEPLOYMENT" "secretName: ca" "global.tls.caCertSecret on $name"
  has "$DEPLOYMENT" "mountPath: /etc/ssl/custom" "CA mount on $name"
  has "$DEPLOYMENT" "fips140=on" "global.security.profile on $name"
done
OUT=$(render "${CONNECTION[@]}" --set-json 'global.imagePullSecrets=[{"name":"g"}]' --set-json 'imagePullSecrets=[{"name":"local"}]' \
  --set global.tls.caCertSecret=ca --set tls.caCertSecret=local-ca)
DEPLOYMENT="$(doc "$OUT" Deployment redis-agent-memory)"
has "$DEPLOYMENT" "- name: local" "local imagePullSecrets"
lacks "$DEPLOYMENT" "- name: g" "local imagePullSecrets wins"
has "$DEPLOYMENT" "secretName: local-ca" "local tls.caCertSecret"
lacks "$DEPLOYMENT" "secretName: ca" "local tls.caCertSecret wins"
# A null local tls block takes global.tls.caCertSecret and still projects the default ca.crt key.
OUT=$(render "${CONNECTION[@]}" --set tls=null --set global.tls.caCertSecret=suite-ca --set supportPackage.enabled=true)
for name in redis-agent-memory redis-agent-memory-worker redis-agent-memory-controlplane; do
  DEPLOYMENT="$(doc "$OUT" Deployment "$name")"
  has "$DEPLOYMENT" "secretName: suite-ca" "global CA with null tls on $name"
  has "$DEPLOYMENT" "- key: ca.crt" "default CA key with null tls on $name"
done
has "$OUT" '"tlsCaBundleFrom": {"kind": "Secret", "name": "suite-ca", "key": "ca.crt"}' "support package CA key with null tls"
echo "OK"

echo "=== Support package ==="
OUT=$(render "${CONNECTION[@]}" --set supportPackage.enabled=true)
has "$OUT" "https://ids.example/v1/health/live"
has "$OUT" "https://ids.example/v1/health/ready"
has "$OUT" "Iris Identity Service runtime credential memory-dp"
lacks "$OUT" "logs/identity-service" "support package collects IdS logs"
lacks "$OUT" "Iris Identity Service Deployment" "support package checks the IdS Deployment"
for absent in identity-service-config identity-service-metadata control-token "app.kubernetes.io/name=iris-identity-service"; do
  lacks "$OUT" "$absent" "support package collects an Identity Service object"
done
SUPPORT="$(doc "$OUT" ConfigMap redis-agent-memory-support-bundle)"
has "$SUPPORT" "name: ram/identity-service-connection.json" "connection diagnostics"
has "$SUPPORT" '"identityServiceBaseURL": "https://ids.example"'
has "$SUPPORT" '"allowInsecureTransport": false'
has "$SUPPORT" '"dataPlaneCredentialFrom": {"kind": "Secret", "name": "memory-dp-credential", "key": "token"}'
has "$SUPPORT" '"tlsCaBundleFrom": {"kind": "Secret", "name": "", "key": "ca.crt"}'
has "$SUPPORT" "checkName: RAM Identity Service introspection errors" "introspection error analyzer"
has "$SUPPORT" 'fileName: "logs/server/*/*.log"'
has "$SUPPORT" 'regex: "agent key introspection unavailable"'
lacks "$SUPPORT" "SSL_CERT_DIR" "health checks trust a CA without tls.caCertSecret"
OUT=$(render "${CONNECTION[@]}" --set tls.caCertSecret=ids-ca)
SUPPORT="$(doc "$OUT" ConfigMap redis-agent-memory-support-bundle)"
has "$SUPPORT" '"tlsCaBundleFrom": {"kind": "Secret", "name": "ids-ca", "key": "ca.crt"}'
IDS_CHECK="$(awk '/name: "iris-identity-service-live"/,/--timeout/' <<<"$SUPPORT")"
has "$IDS_CHECK" "secretName: ids-ca" "IdS health check mounts tls.caCertSecret"
has "$IDS_CHECK" "mountPath: /etc/ssl/custom"
has "$IDS_CHECK" "name: SSL_CERT_DIR"
SERVER_CHECK="$(awk '/name: "ram-server-liveness"/,/--timeout/' <<<"$SUPPORT")"
lacks "$SERVER_CHECK" "SSL_CERT_DIR" "in-cluster http:// checks need no CA"
OUT=$(render --set memory.profile=dev --set memory.auth.method=none --set supportPackage.enabled=true)
SUPPORT="$(doc "$OUT" ConfigMap redis-agent-memory-support-bundle)"
lacks "$SUPPORT" "identity-service" "Identity Service collectors without a connection"
lacks "$SUPPORT" "introspection" "introspection analyzer without a connection"
echo "OK"

echo "=== NOTES ==="
# helm template does not render NOTES.txt, so render it through tpl from a
# copy of the chart, as one JSON string decoded back to text.
NOTES_CHART="$(mktemp -d)"
trap 'rm -rf "$NOTES_CHART"' EXIT
cp -r "$CHART_DIR/." "$NOTES_CHART"
cp "$CHART_DIR/templates/NOTES.txt" "$NOTES_CHART/notes-under-test.txt"
echo 'notes: {{ tpl (.Files.Get "notes-under-test.txt") . | toJson }}' >"$NOTES_CHART/templates/notes-under-test.yaml"
OUT=$(helm template "$RELEASE" "$NOTES_CHART" "${COMMON_ARGS[@]}" "${CONNECTION[@]}" \
  --set controlplane.internalToken.existingSecret=memory-cp-internal-token \
  --show-only templates/notes-under-test.yaml | sed -n 's/^notes: //p' | jq -r .)
has "$OUT" "Data plane URL  : https://ids.example"
has "$OUT" "DP credential   : Secret memory-dp-credential (key: token)"
has "$OUT" "Validator       : set productValidation.products.memory on the Identity Service release to"
has "$OUT" "    baseURL       : http://redis-agent-memory-controlplane.default.svc.cluster.local:9100" "validator URL and port"
has "$OUT" "    credential    : Secret memory-cp-internal-token (key: token), the internal token" "validator internal-token Secret"
lacks "$OUT" "fips: the Identity Service refuses http://" "fips hint outside fips"
OUT=$(helm template "$RELEASE" "$NOTES_CHART" "${COMMON_ARGS[@]}" "${CONNECTION[@]}" \
  --set security.profile=fips \
  --show-only templates/notes-under-test.yaml | sed -n 's/^notes: //p' | jq -r .)
has "$OUT" "fips: the Identity Service refuses http://" "fips validator URL hint"
lacks "$OUT" "RAM-layer authentication is DISABLED" "no auth warning with agent-key auth"
for method in none " None "; do
  OUT=$(helm template "$RELEASE" "$NOTES_CHART" "${COMMON_ARGS[@]}" \
    --set memory.profile=dev --set "memory.auth.method=$method" \
    --show-only templates/notes-under-test.yaml | sed -n 's/^notes: //p' | jq -r .)
  has "$OUT" "WARNING: RAM-layer authentication is DISABLED (memory.auth.method=none)." "auth warning for method '$method'"
  has "$OUT" "Do not expose the data plane beyond a trusted" "auth warning for method '$method'"
done
echo "OK"

echo "=== Long release name ==="
LONG_RELEASE="$(printf 'r%.0s' {1..53})"
OUT=$(helm template "$LONG_RELEASE" "$CHART_DIR" "${COMMON_ARGS[@]}" "${CONNECTION[@]}")
# Secret names are DNS subdomains (253 characters); everything else here must
# fit a 63-character DNS label.
while read -r kind name; do
  limit=63
  [ "$kind" = "Secret" ] && limit=253
  [ "${#name}" -le "$limit" ] || fail "$kind name longer than $limit characters: $name"
done < <(awk '/^kind:/ { k=$2 } /^metadata:$/ { m=1; next } m && /^  name:/ { print k, $2; m=0 }' <<<"$OUT")
has "$(doc "$OUT" Deployment redis-agent-memory)" "secretName: memory-dp-credential" "long release DP mounts the credential"
echo "OK"

echo "All Identity Service connection checks passed."
