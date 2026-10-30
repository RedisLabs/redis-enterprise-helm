#!/usr/bin/env bash
set -euo pipefail

# Rendered assertions for the redis-iris suite helpers (redis-onprem.suite.*): precedence with
# global.iris set, unset, and only the local value set; conflicts naming <prefix><path>; and the
# role-binding translations of the TDD authorization table. Renders the current library source.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$REPO_ROOT"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp -R common/helm/lib/onprem/tests/fixtures/suite/. "$fixture/"
mkdir -p "$fixture/charts/redis-iris-onprem-lib"
cp common/helm/lib/onprem/Chart.yaml "$fixture/charts/redis-iris-onprem-lib/"
cp -R common/helm/lib/onprem/templates "$fixture/charts/redis-iris-onprem-lib/"

render() { helm template t "$fixture" --namespace ns "$@"; }

# expect <rendered> <data key> <exact value> <description>; values render through `quote`
expect() {
  local want got
  want="  $2: \"$(sed 's/["\\]/\\&/g' <<<"$3")\""
  grep -qxF -- "$want" <<<"$1" || {
    got=$(grep -F -- "  $2: " <<<"$1" || true)
    fail "$4: got [$got], want [$want]"
  }
}

# expect_fail <message fragment> <description> <helm flags...>
expect_fail() {
  local needle=$1 description=$2 out
  shift 2
  if out=$(render "$@" 2>&1); then
    fail "$description: render succeeded"
  elif ! grep -qF -- "$needle" <<<"$out"; then
    fail "$description: error lacks '$needle': $out"
  fi
}

UMBRELLA=(--set global.iris.renderMode=helm)

echo "== Standalone, nothing set: chart defaults =="
out=$(render)
expect "$out" enabled "" "standalone is not the suite"
expect "$out" tenantId "standalone-tenant" "standalone tenant default"
expect "$out" clusterDomain "cluster.local" "standalone cluster domain default"
expect "$out" fqdn "svc-a.ns.svc.cluster.local" "standalone FQDN"
expect "$out" license '{"existingSecret":"","secretKey":"license"}' "standalone license defaults"
expect "$out" oidc '{"accessTokenIssuer":"","allowInsecureTransport":false,"audience":"api://standalone","issuer":"","jwksURI":"","roleClaims":["roles"]}' "standalone OIDC defaults"
expect "$out" imagePullSecrets '[]' "no pull secrets"
expect "$out" credential.dataplane '{}' "standalone credential is empty"
expect "$out" roleMappings.agent_memory '{}' "standalone has no bindings"

echo "== Standalone, local values set: local wins; explicit [] is kept =="
out=$(render --set tenantId=t1 --set clusterDomain=corp.local --set license.secretKey=k \
  --set oidc.audience=aud --set oidc.issuer=https://idp --set-json 'oidc.roleClaims=[]' \
  --set tls.caCertSecret=local-ca --set global.tls.caCertSecret=global-ca)
expect "$out" tenantId "t1" "local tenant"
expect "$out" fqdn "svc-a.ns.svc.corp.local" "local cluster domain"
expect "$out" license '{"existingSecret":"","secretKey":"k"}' "local license key"
expect "$out" oidc '{"accessTokenIssuer":"https://idp","allowInsecureTransport":false,"audience":"aud","issuer":"https://idp","jwksURI":"","roleClaims":[]}' "local OIDC, explicit [] kept"
expect "$out" caCertSecret "local-ca" "local CA wins over global.tls"

echo "== Standalone global.* fallbacks =="
out=$(render --set global.tls.caCertSecret=global-ca --set global.security.profile=fips --set-json 'global.imagePullSecrets=[{"name":"reg"}]')
expect "$out" caCertSecret "global-ca" "global CA fallback"
expect "$out" securityProfile "fips" "global profile fallback"
expect "$out" imagePullSecrets '[{"name":"reg"}]' "global pull secrets fallback"

echo "== Umbrella, globals unset: contract defaults =="
out=$(render "${UMBRELLA[@]}")
expect "$out" enabled "true" "umbrella detected"
expect "$out" tenantId "default" "umbrella tenant default"
expect "$out" fqdn "svc-a.ns.svc.cluster.local" "umbrella FQDN default"
expect "$out" license '{"existingSecret":"iris-license","secretKey":"license.key"}' "umbrella license defaults"
expect "$out" oidc '{"accessTokenIssuer":"","allowInsecureTransport":false,"audience":"api://redis-iris","issuer":"","jwksURI":"","roleClaims":["groups"]}' "umbrella OIDC defaults"
expect "$out" workloadIdentity '{"issuer":"https://kubernetes.default.svc.cluster.local","jwksURI":"https://kubernetes.default.svc.cluster.local/openid/v1/jwks"}' "workload identity defaults"
expect "$out" credential.dataplane '{"existingSecret":"iris-memory-dataplane-credential","secretKey":"memory-dp"}' "generated data-plane credential"
expect "$out" credential.controlplane '{"existingSecret":"iris-playbook-internal-token","secretKey":"playbook"}' "generated control-plane credential"
expect "$out" identityService '{"allowInsecureTransport":true,"baseURL":"http://iris-identity-service.ns.svc.cluster.local:9200"}' "suite Identity Service"

echo "== Umbrella, globals set: global wins; an equal local value is accepted =="
out=$(render "${UMBRELLA[@]}" --set global.iris.tenantId=acme --set tenantId=acme \
  --set global.iris.clusterDomain=corp.local --set global.iris.license.secretKey=lic \
  --set global.iris.auth.oidc.issuer=https://idp --set global.iris.auth.oidc.accessTokenIssuer=http://adfs \
  --set global.iris.auth.oidc.jwksURI=https://idp/jwks --set global.iris.auth.oidc.audience=aud \
  --set-json 'global.iris.auth.oidc.roleClaims=["teams"]' \
  --set global.iris.secrets.dataplaneServiceCredentials.existingSecret=dp-agg)
expect "$out" tenantId "acme" "global tenant"
expect "$out" fqdn "svc-a.ns.svc.corp.local" "global cluster domain"
expect "$out" license '{"existingSecret":"iris-license","secretKey":"lic"}' "global license key"
expect "$out" oidc '{"accessTokenIssuer":"http://adfs","allowInsecureTransport":true,"audience":"aud","issuer":"https://idp","jwksURI":"https://idp/jwks","roleClaims":["teams"]}' "global OIDC, http access-token issuer is insecure"
expect "$out" workloadIdentity '{"issuer":"https://kubernetes.default.svc.corp.local","jwksURI":"https://kubernetes.default.svc.corp.local/openid/v1/jwks"}' "workload identity follows clusterDomain"
expect "$out" credential.dataplane '{"existingSecret":"dp-agg","secretKey":"memory-dp"}' "aggregate data-plane credential"

out=$(render "${UMBRELLA[@]}" --set global.iris.workloadIdentity.issuer=https://oidc.eks/id/1)
expect "$out" workloadIdentity '{"issuer":"https://oidc.eks/id/1","jwksURI":"https://oidc.eks/id/1/openid/v1/jwks"}' "custom workload identity issuer"

echo "== Umbrella conflicts name the product field =="
expect_fail 'fixture.tenantId ("other") conflicts with global.iris.tenantId ("acme")' "tenant conflict" \
  "${UMBRELLA[@]}" --set global.iris.tenantId=acme --set tenantId=other
expect_fail 'fixture.tenantId ("other") conflicts with global.iris.tenantId ("default")' "tenant conflicts with the contract default" \
  "${UMBRELLA[@]}" --set tenantId=other
expect_fail 'fixture.clusterDomain ("a.local") conflicts with global.iris.clusterDomain' "cluster domain conflict" \
  "${UMBRELLA[@]}" --set clusterDomain=a.local
expect_fail 'fixture.license.secretKey ("k") conflicts with global.iris.license.secretKey ("license.key")' "license key conflict" \
  "${UMBRELLA[@]}" --set license.secretKey=k
expect_fail 'fixture.auth.oidc.audience ("aud") conflicts with global.iris.auth.oidc.audience' "audience conflict uses the chart path" \
  "${UMBRELLA[@]}" --set oidc.audience=aud
expect_fail 'fixture.roleClaims (["roles"]) conflicts with global.iris.auth.oidc.roleClaims (["groups"])' "role claims conflict" \
  "${UMBRELLA[@]}" --set-json 'oidc.roleClaims=["roles"]'
expect_fail 'fixture.issuer ("https://other") conflicts with global.iris.auth.oidc.issuer' "issuer conflict" \
  "${UMBRELLA[@]}" --set global.iris.auth.oidc.issuer=https://idp --set oidc.issuer=https://other
expect_fail 'fixture.credential.existingSecret ("mine") conflicts with the suite' "credential conflict" \
  "${UMBRELLA[@]}" --set credential.existingSecret=mine
expect_fail 'global.security.profile: fips is not supported by redis-iris' "fips fails in the product chart" \
  "${UMBRELLA[@]}" --set global.security.profile=fips

echo "== Derived (owned) values: unset or equal local accepted, differing local fails =="
expect "$(render)" owned '{"value":["a"]}' "unset local takes the derived value"
expect "$(render --set-json 'owned=["a"]')" owned '{"value":["a"]}' "equal local accepted"
expect_fail 'fixture.owned ([]) conflicts with the value redis-iris derives from global.iris (["a"])' "explicit [] is a value, so it conflicts" \
  --set-json 'owned=[]'

echo "== Role-binding translations (TDD authorization table) =="
BINDINGS='[{"group":"admins","role":"suite_admin"},{"group":"mops","role":"operator","product":"agent_memory"},{"group":"keys","role":"viewer","product":"identity"},{"group":"pb","role":"viewer","product":"playbook"},{"group":"cg","role":"viewer","product":"context_gateway"}]'
out=$(render "${UMBRELLA[@]}" --set global.iris.products.memory.enabled=true --set global.iris.products.playbook.enabled=false \
  --set global.iris.products.contextGateway.enabled=true --set-json "global.iris.auth.roleBindings=$BINDINGS")
expect "$out" memoryEnabled "true" "canonical id maps to products.memory"
expect "$out" roleMappings.agent_memory '{"admins":"suite_admin","mops":"operator"}' "Memory: own bindings plus suite scope"
expect "$out" roleMappings.playbook '{"admins":"suite_admin","pb":"viewer"}' "Playbook mapping ignores enablement"
expect "$out" ui.roleMappings '{"agent_memory":{"admins":"suite_admin","mops":"operator"},"context_gateway":{"admins":"suite_admin","cg":"viewer"},"identity":{"admins":"suite_admin","keys":"viewer"}}' "UI: enabled products and identity; disabled Playbook dropped"
expect "$out" ids.roleBindings '[{"claim_value":"admins","role":"suite_admin","scope":"global"},{"claim_value":"mops","product":"memory","role":"operator","scope":"product"},{"claim_value":"cg","product":"context-gateway","role":"viewer","scope":"product"}]' "IdS: mapped ids, identity and disabled Playbook dropped"

out=$(render "${UMBRELLA[@]}" --set global.iris.products.memory.enabled=true --set global.iris.products.playbook.enabled=true \
  --set-json "global.iris.auth.roleBindings=$BINDINGS")
expect "$out" ui.roleMappings '{"agent_memory":{"admins":"suite_admin","mops":"operator"},"identity":{"admins":"suite_admin","keys":"viewer"},"playbook":{"admins":"suite_admin","pb":"viewer"}}' "UI: re-enabled Playbook restored"
expect "$out" ids.roleBindings '[{"claim_value":"admins","role":"suite_admin","scope":"global"},{"claim_value":"mops","product":"memory","role":"operator","scope":"product"},{"claim_value":"pb","product":"playbook","role":"viewer","scope":"product"}]' "IdS: re-enabled Playbook restored"

expect_fail 'group "admins" is bound to both "suite_admin" and "viewer" for agent_memory' "duplicate group per product" \
  "${UMBRELLA[@]}" --set-json 'global.iris.auth.roleBindings=[{"group":"admins","role":"suite_admin"},{"group":"admins","role":"viewer","product":"agent_memory"}]'

if (( failures > 0 )); then
  echo "$failures suite helper assertion(s) failed" >&2
  exit 1
fi
echo "All suite helper assertions passed."
